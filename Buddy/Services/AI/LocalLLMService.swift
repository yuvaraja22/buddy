import Foundation
import LLM
import Observation
import UIKit

public enum LocalLLMError: LocalizedError, Sendable {
    case modelNotDownloaded
    case loadFailed(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "No local LLM model is downloaded. Download Qwen 2.5 in Settings to enable on-device AI."
        case .loadFailed(let detail):
            return "Could not load local AI model: \(detail)"
        case .generationFailed(let detail):
            return "Local AI generation failed: \(detail)"
        }
    }
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

private final class LockedStringAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String = ""

    func append(_ chunk: String) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var value: String {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }
}

private final class MemoryWarningObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(handler: @escaping @Sendable () -> Void) {
        self.token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

@Observable
@MainActor
public final class LocalLLMService {
    public var isLoaded: Bool = false
    public var isLoading: Bool = false
    public var isParsingVoice: Bool = false
    public var isStreamingCoach: Bool = false
    public var isGenerating: Bool {
        isParsingVoice || isStreamingCoach
    }
    public var loadedModelName: String?
    public var lastMemoryNotice: String?

    /// Shared residency coordinator ensuring Qwen GGUF and Parakeet CoreML never overlap in RAM.
    @ObservationIgnored public var memoryCoordinator: ModelMemoryCoordinator?
    /// Invoked inside `memoryCoordinator` to cancel & await complete teardown of `ParakeetTranscriptionService`.
    @ObservationIgnored public var onUnloadOpposingModel: (@MainActor () async -> Void)?

    private let modelManager: ModelManager
    @ObservationIgnored private var llm: LLM?
    @ObservationIgnored private var loadedFilePath: String?
    @ObservationIgnored private var cachedTemplateHint: String?
    @ObservationIgnored private var memoryObserverToken: MemoryWarningObserverToken?

    // FIFO serialization gate preventing concurrent access to the underlying llama_context.
    @ObservationIgnored private var isExecutingExclusiveTask: Bool = false
    @ObservationIgnored private var accessWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var pendingMemoryUnload: Bool = false

    // Tracks actual GGUF mapping or active llama.cpp inference (NEVER true while waiting on
    // `memoryCoordinator`), enabling deadlock-free `unloadAndWait()`.
    @ObservationIgnored private var isMappingOrRunningModel: Bool = false
    @ObservationIgnored private var modelIdleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.memoryObserverToken = MemoryWarningObserverToken { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }
    }

    public func ensureLoaded() async throws {
        try Task.checkCancellation()

        guard let fileURL = modelManager.activeLLMFileURL else {
            throw LocalLLMError.modelNotDownloaded
        }

        let desiredPath = fileURL.path
        if llm != nil, isLoaded, loadedFilePath == desiredPath {
            return
        }

        try await runCoordinatedLLMTransition {
            try Task.checkCancellation()

            if self.llm != nil, self.isLoaded, self.loadedFilePath == desiredPath {
                return
            }

            if self.llm != nil {
                self.releaseLoadedModel()
            }

            self.pendingMemoryUnload = false
            self.isLoading = true
            self.isMappingOrRunningModel = true
            defer {
                self.isLoading = false
                self.finishModelActivityIfIdle()
            }

            let loadedBox: UncheckedSendableBox<LLM?> = await Task.detached(priority: .userInitiated) {
                let instance = LLM(
                    from: fileURL,
                    topK: 40,
                    topP: 0.9,
                    temp: 0.1,
                    repeatPenalty: 1.15,
                    historyLimit: 6,
                    maxTokenCount: 2048
                )
                return UncheckedSendableBox(value: instance)
            }.value

            if self.pendingMemoryUnload {
                self.pendingMemoryUnload = false
                loadedBox.value?.stop()
                self.memoryCoordinator?.markUnloaded(.llm)
                self.lastMemoryNotice = "Released model memory cleanly; reloads automatically on next use."
                throw LocalLLMError.loadFailed("Low memory while loading model. Please try again.")
            }

            if Task.isCancelled {
                loadedBox.value?.stop()
                self.memoryCoordinator?.markUnloaded(.llm)
                throw CancellationError()
            }

            guard let instance = loadedBox.value else {
                self.memoryCoordinator?.markUnloaded(.llm)
                throw LocalLLMError.loadFailed("Failed to initialize \(fileURL.lastPathComponent).")
            }

            instance.postprocess = { _ in }
            let hint = await instance.core.getChatTemplateHint()

            if self.pendingMemoryUnload || Task.isCancelled {
                instance.stop()
                self.memoryCoordinator?.markUnloaded(.llm)
                if self.pendingMemoryUnload {
                    self.pendingMemoryUnload = false
                    self.lastMemoryNotice = "Released model memory cleanly; reloads automatically on next use."
                }
                throw CancellationError()
            }

            self.llm = instance
            self.loadedFilePath = desiredPath
            self.cachedTemplateHint = hint
            self.loadedModelName = self.resolvedDisplayName(for: fileURL)
            self.isLoaded = true
            self.lastMemoryNotice = nil
        }
    }

    public func unload() {
        if isLoading || isGenerating || isMappingOrRunningModel {
            pendingMemoryUnload = true
            llm?.stop()
            return
        }
        releaseLoadedModel()
        lastMemoryNotice = nil
    }

    /// Stops any active GGUF generation/mapping, awaits until the C++ context exits, and releases
    /// `llm = nil` so `LLMCore.deinit` frees `llama_model` BEFORE Parakeet starts loading CoreML.
    public func unloadAndWait() async {
        pendingMemoryUnload = true
        llm?.stop()

        if isMappingOrRunningModel {
            await withCheckedContinuation { continuation in
                modelIdleWaiters.append(continuation)
            }
        }

        releaseLoadedModel()
        pendingMemoryUnload = false
        lastMemoryNotice = nil
    }

    private func runCoordinatedLLMTransition<T>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        if let coordinator = memoryCoordinator {
            return try await coordinator.runExclusiveLoad(
                for: .llm,
                unloadOther: { [weak self] in
                    await self?.onUnloadOpposingModel?()
                },
                operation: operation
            )
        } else {
            await onUnloadOpposingModel?()
            return try await operation()
        }
    }

    private func finishModelActivityIfIdle() {
        isMappingOrRunningModel = false
        let waiters = modelIdleWaiters
        modelIdleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func releaseLoadedModel() {
        llm?.stop()
        llm = nil
        loadedFilePath = nil
        cachedTemplateHint = nil
        loadedModelName = nil
        isLoaded = false
        memoryCoordinator?.markUnloaded(.llm)
    }

    /// Returns `true` when `RuleBasedWorkoutParser` extracted a complete, unambiguous command
    /// (so Buddy can log immediately in <1 ms without evicting Parakeet from RAM to load Qwen).
    public nonisolated static func isConfidentRuleParse(_ intent: WorkoutCommandIntent) -> Bool {
        switch intent.action {
        case .updateLastSet, .deleteLastSet, .deleteLastExercise, .endSession:
            return true
        case .logSets:
            guard !intent.items.isEmpty else { return false }
            return intent.items.allSatisfy { item in
                let hasExercise = !item.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasQuantity = (item.reps ?? 0) > 0 || (item.durationSeconds ?? 0) > 0
                return hasExercise && hasQuantity
            }
        case .unknown:
            return false
        }
    }

    public func parseVoiceTranscript(
        _ transcript: String,
        context: ActiveSessionPromptContext,
        preferInstantParserWhenConfident: Bool = false
    ) async -> WorkoutCommandIntent {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WorkoutCommandIntent(
                action: .unknown,
                rawTranscript: transcript,
                parserSource: .ruleBased
            )
        }

        let ruleFallback = RuleBasedWorkoutParser.parse(trimmed, context: context)

        if preferInstantParserWhenConfident && Self.isConfidentRuleParse(ruleFallback) {
            return ruleFallback
        }

        guard modelManager.isLLMDownloaded else {
            return ruleFallback
        }

        await acquireExclusiveAccess()
        defer {
            if pendingMemoryUnload {
                pendingMemoryUnload = false
                releaseLoadedModel()
            }
            releaseExclusiveAccess()
        }

        guard !Task.isCancelled else {
            return WorkoutCommandIntent(action: .unknown, rawTranscript: trimmed, parserSource: .localLLM)
        }

        isParsingVoice = true
        defer { isParsingVoice = false }

        do {
            try await ensureLoaded()
            try Task.checkCancellation()
            guard let bot = llm else {
                return ruleFallback
            }

            isMappingOrRunningModel = true
            defer { finishModelActivityIfIdle() }

            let systemPrompt = Self.buildParserSystemPrompt(context: context)
            bot.reset()
            bot.temp = 0.1
            bot.systemPrompt = systemPrompt
            bot.template = makeTemplate(systemPrompt: systemPrompt)

            let userPrompt = "Gym voice transcript: \"\(trimmed)\""
            let structured = try await withTaskCancellationHandler {
                try await bot.respond(
                    to: userPrompt,
                    as: LLMParsedVoiceCommand.self,
                    thinking: .suppressed
                )
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.stopVoiceParsing()
                }
            }

            try Task.checkCancellation()
            let intent = structured.value.toDomainIntent(rawTranscript: trimmed)

            return Self.reconcileParsedIntents(llmIntent: intent, ruleFallback: ruleFallback)
        } catch is CancellationError {
            return WorkoutCommandIntent(action: .unknown, rawTranscript: trimmed, parserSource: .localLLM)
        } catch {
            return ruleFallback
        }
    }

    /// Reconciles local LLM output with the deterministic rule-based parser so quantized models
    /// never silently drop exercises during long multi-exercise post-gym voice recaps or mistake
    /// a past-tense recap ("I finished my workout, I did bench press...") for an empty endSession.
    public nonisolated static func reconcileParsedIntents(
        llmIntent: WorkoutCommandIntent,
        ruleFallback: WorkoutCommandIntent
    ) -> WorkoutCommandIntent {
        if llmIntent.action == .unknown || (llmIntent.action == .logSets && llmIntent.items.isEmpty) {
            return ruleFallback.action != .unknown ? ruleFallback : llmIntent
        }

        if llmIntent.action == .endSession && ruleFallback.action == .logSets && !ruleFallback.items.isEmpty {
            return ruleFallback
        }

        if ruleFallback.action == .logSets && llmIntent.action == .logSets {
            // If the deterministic parser cleanly captured strictly more distinct exercises
            // (e.g. a 5-exercise gym recap where a 0.5B/1.5B LLM only emitted 2), keep the fuller list.
            if ruleFallback.distinctExerciseCount > llmIntent.distinctExerciseCount && ruleFallback.distinctExerciseCount >= 2 {
                return ruleFallback
            }
            if ruleFallback.distinctExerciseCount == llmIntent.distinctExerciseCount
                && ruleFallback.items.count > llmIntent.items.count
                && ruleFallback.items.count >= 3 {
                return ruleFallback
            }
        }

        return llmIntent
    }

    public func streamCoachReply(
        userMessage: String,
        workoutContext: String,
        history: [(role: CoachRole, content: String)],
        onDelta: @MainActor @escaping (String) -> Void
    ) async throws -> String {
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return "" }

        await acquireExclusiveAccess()
        defer {
            if pendingMemoryUnload {
                pendingMemoryUnload = false
                releaseLoadedModel()
            }
            releaseExclusiveAccess()
        }

        try Task.checkCancellation()

        isStreamingCoach = true
        defer { isStreamingCoach = false }

        try await ensureLoaded()
        try Task.checkCancellation()
        guard let bot = llm else {
            throw LocalLLMError.modelNotDownloaded
        }

        isMappingOrRunningModel = true
        defer { finishModelActivityIfIdle() }

        let coachSystemPrompt = Self.buildCoachSystemPrompt(
            workoutContext: workoutContext,
            history: history
        )

        bot.reset()
        bot.temp = 0.65
        bot.systemPrompt = coachSystemPrompt
        bot.template = makeTemplate(systemPrompt: coachSystemPrompt)

        let accumulator = LockedStringAccumulator()
        await withTaskCancellationHandler {
            await bot.respond(to: trimmedMessage, thinking: .suppressed) { stream in
                var fullText = ""
                for await delta in stream {
                    guard !delta.isEmpty else { continue }
                    fullText += delta
                    accumulator.append(delta)
                    await MainActor.run {
                        onDelta(delta)
                    }
                }
                return fullText
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stopCoachGeneration()
            }
        }

        if Task.isCancelled {
            throw CancellationError()
        }

        let finalReply = accumulator.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return finalReply
    }

    public func stopVoiceParsing() {
        guard isParsingVoice else { return }
        llm?.stop()
    }

    public func stopCoachGeneration() {
        guard isStreamingCoach else { return }
        llm?.stop()
    }

    public func stopGeneration() {
        llm?.stop()
    }

    // MARK: - Memory & Serialization Helpers

    private func handleMemoryWarning() {
        if isLoading || isGenerating {
            pendingMemoryUnload = true
            llm?.stop()
        } else {
            releaseLoadedModel()
        }
        lastMemoryNotice = "Released model memory cleanly; reloads automatically on next use."
    }

    private func acquireExclusiveAccess() async {
        if !isExecutingExclusiveTask {
            isExecutingExclusiveTask = true
            return
        }
        await withCheckedContinuation { continuation in
            accessWaiters.append(continuation)
        }
    }

    private func releaseExclusiveAccess() {
        if !accessWaiters.isEmpty {
            let next = accessWaiters.removeFirst()
            next.resume()
        } else {
            isExecutingExclusiveTask = false
        }
    }

    private func resolvedDisplayName(for fileURL: URL) -> String {
        if modelManager.selectedLLMPreset == .custom {
            return modelManager.customLLMFileName ?? fileURL.lastPathComponent
        }
        return modelManager.selectedLLMPreset.displayName
    }

    /// Chooses a clean chat template compatible with the loaded GGUF's embedded Jinja hint
    /// so both structured JSON decoding (`respond(to:as:)`) and streaming chat format prompts accurately.
    private func makeTemplate(systemPrompt: String) -> Template {
        let hint = cachedTemplateHint ?? ""

        if hint.contains("<|start_header_id|>") {
            return Template(
                prefix: "<|begin_of_text|>",
                system: ("<|start_header_id|>system<|end_header_id|>\n\n", "<|eot_id|>"),
                user: ("<|start_header_id|>user<|end_header_id|>\n\n", "<|eot_id|>"),
                bot: ("<|start_header_id|>assistant<|end_header_id|>\n\n", "<|eot_id|>"),
                stopSequence: "<|eot_id|>",
                systemPrompt: systemPrompt
            )
        }

        if hint.contains("<start_of_turn>") {
            return Template(
                system: ("<start_of_turn>user\n", "\n\n"),
                user: ("", "<end_of_turn>\n"),
                bot: ("<start_of_turn>model\n", "<end_of_turn>\n"),
                stopSequence: "<end_of_turn>",
                systemPrompt: systemPrompt
            )
        }

        if hint.contains("[INST]") {
            return Template.llama(systemPrompt)
        }

        // Clean ChatML (native format for Qwen 2.5 1.5B / 0.5B and most modern GGUFs).
        return Template(
            system: ("<|im_start|>system\n", "<|im_end|>\n"),
            user: ("<|im_start|>user\n", "<|im_end|>\n"),
            bot: ("<|im_start|>assistant\n", "<|im_end|>\n"),
            stopSequence: "<|im_end|>",
            systemPrompt: systemPrompt
        )
    }

    // MARK: - Prompt Construction

    private static func buildParserSystemPrompt(context: ActiveSessionPromptContext) -> String {
        let recent = context.recentExercisesInSession.isEmpty
            ? "none"
            : context.recentExercisesInSession.prefix(6).joined(separator: ", ")
        let lastExercise = context.lastExerciseName ?? "none"
        let catalogHint = ExerciseCatalog.promptHint(limit: 30)

        return """
        You are Buddy's offline gym workout command parser. Convert spoken gym transcripts into structured workout actions.

        Active session context:
        - Preferred default unit: \(context.preferredUnit.rawValue)
        - Session active: \(context.isSessionActive ? "yes" : "no")
        - Last exercise logged: \(lastExercise)
        - Recent session exercises: \(recent)

        Common canonical exercises: \(catalogHint)

        Rules:
        1. Choose action:
           - "logSets": logging one OR an entire gym session of multiple exercises/sets in one go. Past-tense recaps (e.g. "I finished my workout, today I did bench press... then cable fly...") MUST use "logSets" (NOT "endSession"). If user says "another set", "one more", or "same weight", use Last exercise logged ("\(lastExercise)").
           - "updateLastSet": correcting the most recent set ("make that 85 kg", "actually 12 reps", "mark as warmup").
           - "deleteLastSet": removing/undoing the last logged set.
           - "deleteLastExercise": removing the last logged exercise.
           - "endSession": ONLY when user asks to finish/end the workout without listing exercises/sets.
           - "unknown": not a workout command.
        2. For full-session recaps, emit ONE item per exercise (or per distinct weight/rep set group on the same exercise) in the exact order spoken; never skip or merge different exercises.
        3. "sets" must be an integer >= 1 (default 1). "3 sets of 10" -> sets: 3, reps: 10.
        4. "unit" must be "kg" or "lbs" ONLY when explicitly spoken; omit it otherwise.
        5. For timed holds or cardio (e.g. "2 minute plank"), set "durationSeconds" (e.g. 120).
        6. Use "tag": "warmup", "dropset", "failure", or "normal" when mentioned.
        7. Omit optional fields (reps, weight, unit, durationSeconds, tag, note) when not mentioned; do not output null.
        8. Write a concise 3-8 word "summary" of the logged action.
        """
    }

    private static func buildCoachSystemPrompt(
        workoutContext: String,
        history: [(role: CoachRole, content: String)]
    ) -> String {
        let cappedContext = String(workoutContext.prefix(1400))
        let recentTurns = history.suffix(4)

        var historyBlock = ""
        if !recentTurns.isEmpty {
            let formattedTurns = recentTurns.map { turn in
                let speaker = turn.role == .user ? "User" : "Coach"
                let snippet = turn.content
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "- \(speaker): \(String(snippet.prefix(240)))"
            }.joined(separator: "\n")

            historyBlock = """

            Recent conversation:
            \(formattedTurns)
            """
        }

        return """
        You are Buddy, an encouraging, concise, evidence-based personal strength & conditioning coach running 100% offline on the user's iPhone.

        Guidelines:
        - Ground advice in the user's actual logged workout data below; never invent numbers that are not listed.
        - Keep replies clear, practical, and easy to scan between sets (short paragraphs or crisp bullets).
        - Suggest sensible progressive overload, recovery, exercise swaps, or form cues tailored to the user's goal.

        Workout data snapshot:
        \(cappedContext.isEmpty ? "No logged workouts yet." : cappedContext)\(historyBlock)
        """
    }
}
