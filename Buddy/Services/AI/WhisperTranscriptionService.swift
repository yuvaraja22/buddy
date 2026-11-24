import CoreML
import Foundation
import Observation
import UIKit
import WhisperKit

public enum WhisperServiceError: LocalizedError, Sendable {
    case modelNotDownloaded
    case emptyAudio
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "Download a Whisper model in Settings → Voice & Local AI first, or switch to Apple Speech."
        case .emptyAudio:
            return "No speech detected. Hold or tap a bit longer while speaking your set."
        case .transcriptionFailed(let detail):
            return "Whisper transcription failed: \(detail)"
        }
    }
}

private struct WhisperKitSendableBox: @unchecked Sendable {
    let value: WhisperKit
}

private final class WhisperMemoryObserverToken: @unchecked Sendable {
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

/// Crash-proof on-device OpenAI Whisper (CoreML + Apple Neural Engine) speech service.
///
/// Designed specifically for SideStore free Apple IDs (which lack Apple's paid
/// `increased-memory-limit` entitlement):
/// - Serializes all residency transitions through `ModelMemoryCoordinator` and awaits full
///   `LocalLLMService` deallocation before loading CoreML weights.
/// - Runs CoreML compilation, loading, and transcription off `@MainActor`.
/// - Runs one-time sequential ANE prewarming (`prewarm: true, load: false`) separately from live
///   loading and tracks completion per iOS build so CoreML never double-compiles.
/// - Uses `.cpuOnly` for MelSpectrogram to avoid Metal GPU memory spikes alongside ANE.
/// - Pins `concurrentWorkerCount = 1`, restores timestamp tokens (`withoutTimestamps: false`)
///   for safe multi-window 30s+ recap seeking, enables `suppressBlank: true`, caps gym prompt
///   tokens from the tail so active exercises are never front-truncated by WhisperKit, and skips
///   pure silence clips before waking CoreML.
@Observable
@MainActor
public final class WhisperTranscriptionService {
    /// Maximum BPE token count for `promptTokens` (well under WhisperKit's 111-token `.suffix` cap
    /// so active session exercises at the front of the prompt are never truncated and each 30s
    /// window retains ~160+ output tokens for dense recaps).
    public nonisolated static let maxPromptTokenCount: Int = 55

    /// 30 seconds at 16 kHz; clips longer than one Whisper window enable `.vad` chunking.
    private nonisolated static let singleWindowSampleLimit: Int = 480_000

    public var isLoaded: Bool = false
    public var isLoading: Bool = false
    public var isPrewarming: Bool = false
    public var isTranscribing: Bool = false
    public var loadedVariantName: String?
    public var lastMemoryNotice: String?

    /// Shared residency coordinator ensuring WhisperKit and LocalLLMService never overlap in RAM.
    @ObservationIgnored public var memoryCoordinator: ModelMemoryCoordinator?
    /// Invoked inside `memoryCoordinator` to cancel & await complete teardown of `LocalLLMService`.
    @ObservationIgnored public var onUnloadOpposingModel: (@MainActor () async -> Void)?

    private let modelManager: ModelManager
    @ObservationIgnored private var whisperKit: WhisperKit?
    @ObservationIgnored private var loadedFolderPath: String?
    @ObservationIgnored private var loadedVariantRawValue: String?
    @ObservationIgnored private var activeLifecycleTask: Task<Void, Error>?
    @ObservationIgnored private var cancelActiveCoreMLSubtask: (() -> Void)?
    @ObservationIgnored private var isRunningCoreMLWork: Bool = false
    @ObservationIgnored private var coreMLIdleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var memoryWarningDuringActivity: Bool = false
    @ObservationIgnored private var pendingUnload: Bool = false
    @ObservationIgnored private var memoryWarningObserver: WhisperMemoryObserverToken?

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.memoryWarningObserver = WhisperMemoryObserverToken { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTranscribing || self.isLoading || self.isPrewarming || self.isRunningCoreMLWork {
                    self.memoryWarningDuringActivity = true
                } else if self.whisperKit != nil {
                    await self.releaseLoadedWhisper()
                    self.lastMemoryNotice = "Released Whisper memory under iOS pressure; reloads automatically on next mic tap."
                }
            }
        }
    }

    /// Runs WhisperKit's one-time sequential Neural Engine specialization (`prewarm: true, load: false`)
    /// immediately after download so the user's first gym mic tap loads straight from iOS's ANE cache.
    public func prewarmDownloadedModel(_ preset: WhisperPreset) async throws {
        guard let folder = modelManager.resolvedWhisperFolderURL(for: preset) else {
            throw WhisperServiceError.modelNotDownloaded
        }
        guard !modelManager.isPrewarmed(preset) else { return }

        // Wait for any prior load/prewarm task to settle first.
        if let prior = activeLifecycleTask {
            prior.cancel()
            _ = try? await prior.value
        }

        let folderPath = folder.path
        let tokenizerFolder = modelManager.whisperBaseDirectory
        let computeOptions = Self.makeComputeOptions()

        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }
            try await self.runCoordinatedWhisperTransition {
                try Task.checkCancellation()
                if self.whisperKit != nil {
                    await self.releaseLoadedWhisper()
                }

                self.memoryWarningDuringActivity = false
                self.pendingUnload = false
                self.isPrewarming = true
                defer { self.isPrewarming = false }

                try await self.executeCoreMLSubtask {
                    let config = WhisperKitConfig(
                        modelFolder: folderPath,
                        tokenizerFolder: tokenizerFolder,
                        computeOptions: computeOptions,
                        verbose: false,
                        prewarm: true,
                        load: false,
                        download: false
                    )
                    let prewarmPipe = try await WhisperKit(config)
                    await prewarmPipe.unloadModels()
                }

                if Task.isCancelled || self.pendingUnload {
                    self.pendingUnload = false
                    self.memoryCoordinator?.markUnloaded(.whisper)
                    throw CancellationError()
                }

                if self.memoryWarningDuringActivity {
                    self.memoryWarningDuringActivity = false
                    self.memoryCoordinator?.markUnloaded(.whisper)
                    self.lastMemoryNotice = "Paused Neural Engine optimization due to low memory; Whisper will optimize on next use."
                    return
                }

                self.modelManager.markPrewarmed(preset)
                self.memoryCoordinator?.markUnloaded(.whisper)
                // Give CoreML's ANE compiler daemon a brief pause to release scratch memory.
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        activeLifecycleTask = task
        defer {
            if activeLifecycleTask == task {
                activeLifecycleTask = nil
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Ensures the active Whisper CoreML preset is compiled and loaded into memory cleanly.
    public func ensureLoaded() async throws {
        guard let folder = modelManager.activeWhisperFolderURL else {
            throw WhisperServiceError.modelNotDownloaded
        }

        let desiredPreset = modelManager.selectedWhisperPreset
        let desiredVariant = desiredPreset.rawValue
        let desiredPath = folder.path

        if whisperKit != nil,
           isLoaded,
           loadedFolderPath == desiredPath,
           loadedVariantRawValue == desiredVariant {
            return
        }

        if let existingTask = activeLifecycleTask {
            try await withTaskCancellationHandler {
                try await existingTask.value
            } onCancel: {
                existingTask.cancel()
            }
            if whisperKit != nil,
               isLoaded,
               loadedFolderPath == desiredPath,
               loadedVariantRawValue == desiredVariant {
                return
            }
        }

        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }

            try await self.runCoordinatedWhisperTransition {
                try Task.checkCancellation()

                if self.whisperKit != nil {
                    await self.releaseLoadedWhisper()
                }

                self.memoryWarningDuringActivity = false
                self.pendingUnload = false
                self.lastMemoryNotice = nil

                let tokenizerFolder = self.modelManager.whisperBaseDirectory
                let computeOptions = Self.makeComputeOptions()

                // Step 1: If this iOS build hasn't specialized the ANE graph yet, prewarm submodels
                // ONE AT A TIME (`prewarm: true, load: false`) so compiler memory never stacks.
                if !self.modelManager.isPrewarmed(desiredPreset) {
                    self.isPrewarming = true
                    defer { self.isPrewarming = false }

                    try await self.executeCoreMLSubtask {
                        let prewarmConfig = WhisperKitConfig(
                            modelFolder: desiredPath,
                            tokenizerFolder: tokenizerFolder,
                            computeOptions: computeOptions,
                            verbose: false,
                            prewarm: true,
                            load: false,
                            download: false
                        )
                        let prewarmPipe = try await WhisperKit(prewarmConfig)
                        await prewarmPipe.unloadModels()
                    }

                    if Task.isCancelled || self.pendingUnload {
                        self.pendingUnload = false
                        self.memoryCoordinator?.markUnloaded(.whisper)
                        throw CancellationError()
                    }

                    if self.memoryWarningDuringActivity {
                        self.memoryWarningDuringActivity = false
                        self.memoryCoordinator?.markUnloaded(.whisper)
                        throw WhisperServiceError.transcriptionFailed(
                            "iPhone memory was tight during one-time optimization. Tap mic again to finish loading."
                        )
                    }

                    self.modelManager.markPrewarmed(desiredPreset)
                    try? await Task.sleep(for: .milliseconds(250))
                }

                // Step 2: Load the pre-compiled CoreML submodels off-MainActor with zero prewarm overhead.
                self.isLoading = true
                defer { self.isLoading = false }

                let loadedBox: WhisperKitSendableBox = try await self.executeCoreMLSubtask {
                    let loadConfig = WhisperKitConfig(
                        modelFolder: desiredPath,
                        tokenizerFolder: tokenizerFolder,
                        computeOptions: computeOptions,
                        verbose: false,
                        prewarm: false,
                        load: true,
                        download: false
                    )
                    let pipe = try await WhisperKit(loadConfig)
                    return WhisperKitSendableBox(value: pipe)
                }

                if Task.isCancelled || self.pendingUnload || self.memoryWarningDuringActivity {
                    let wasMemoryWarning = self.memoryWarningDuringActivity
                    self.memoryWarningDuringActivity = false
                    self.pendingUnload = false
                    await loadedBox.value.unloadModels()
                    self.memoryCoordinator?.markUnloaded(.whisper)
                    if wasMemoryWarning {
                        throw WhisperServiceError.transcriptionFailed(
                            "Released Whisper due to low iPhone memory. Switch to Whisper Large Compact or Whisper Small in Settings."
                        )
                    }
                    throw CancellationError()
                }

                self.whisperKit = loadedBox.value
                self.loadedFolderPath = desiredPath
                self.loadedVariantRawValue = desiredVariant
                self.loadedVariantName = desiredPreset.displayName
                self.isLoaded = true
            }
        }

        activeLifecycleTask = task
        defer {
            if activeLifecycleTask == task {
                activeLifecycleTask = nil
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func transcribe(
        samples: [Float],
        recentExercises: [String] = []
    ) async throws -> String {
        guard samples.count >= 1_600 else {
            throw WhisperServiceError.emptyAudio
        }

        // Reject pure silence / muted accidental taps BEFORE evicting Qwen or waking CoreML.
        guard Self.hasAudibleSpeech(in: samples) else {
            throw WhisperServiceError.emptyAudio
        }

        try await ensureLoaded()

        guard let pipe = whisperKit else {
            throw WhisperServiceError.modelNotDownloaded
        }

        isTranscribing = true
        defer {
            isTranscribing = false
            if memoryWarningDuringActivity || pendingUnload {
                let wasMemoryWarning = memoryWarningDuringActivity
                memoryWarningDuringActivity = false
                pendingUnload = false
                Task { @MainActor [weak self] in
                    await self?.releaseLoadedWhisper()
                    if wasMemoryWarning {
                        self?.lastMemoryNotice = "Released Whisper memory after logging; reloads automatically next time."
                    }
                }
            }
        }

        let paddedSamples = Self.prepareAudioSamplesForWhisper(samples)
        let biasPrompt = Self.buildGymBiasPrompt(recentExercises: recentExercises)
        let languageCode = modelManager.selectedWhisperPreset.languageCode

        // Encode with leading space per Whisper BPE conventions and cap from the TAIL (`prefix`)
        // so WhisperKit's internal `.suffix(111)` never truncates active session exercises.
        let promptTokens: [Int]? = pipe.tokenizer.flatMap { tokenizer in
            let encoded = tokenizer.encode(text: " " + biasPrompt)
            let capped = Array(encoded.prefix(Self.maxPromptTokenCount))
            return capped.isEmpty ? nil : capped
        }

        // Restore timestamp tokens (`withoutTimestamps: false`) so multi-window 30s+ workout recaps
        // can rewind seek boundaries instead of dropping words when a window fills up.
        // Enable `suppressBlank: true` to curb hallucinations on quiet gym pauses, and use `.vad`
        // chunking on >30s recaps while keeping `concurrentWorkerCount: 1` for strict RAM control.
        let useVADChunking = paddedSamples.count > Self.singleWindowSampleLimit
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode,
            temperature: 0.0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            windowClipTime: 0.0,
            promptTokens: promptTokens,
            suppressBlank: true,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1,
            chunkingStrategy: useVADChunking ? .vad : nil
        )

        let pipeBox = WhisperKitSendableBox(value: pipe)
        do {
            let combined: String = try await executeCoreMLSubtask {
                let results: [TranscriptionResult] = try await pipeBox.value.transcribe(
                    audioArray: paddedSamples,
                    decodeOptions: options
                )
                return results.map(\.text).joined(separator: " ")
            }
            return Self.cleanTranscript(combined)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WhisperServiceError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Cancels any in-flight CoreML load/prewarm/transcription work cleanly (e.g. user tapped Cancel).
    public func cancelInFlightWork() {
        activeLifecycleTask?.cancel()
        cancelActiveCoreMLSubtask?()
    }

    /// Cancels any in-flight load/prewarm/transcription, awaits active CoreML subtasks to exit,
    /// and frees all Whisper CoreML models so `LocalLLMService` sees 0 MB of Whisper RAM.
    public func unloadAndWait() async {
        pendingUnload = true
        activeLifecycleTask?.cancel()
        cancelActiveCoreMLSubtask?()

        if isRunningCoreMLWork {
            await withCheckedContinuation { continuation in
                coreMLIdleWaiters.append(continuation)
            }
        }

        await releaseLoadedWhisper()
        pendingUnload = false
        lastMemoryNotice = nil
    }

    public func unload() async {
        await unloadAndWait()
    }

    /// Unloads Whisper cleanly when entering the background so iOS Jetsam never terminates Buddy
    /// while switching music or apps between gym sets.
    public func unloadIfIdle() async {
        if isTranscribing || isLoading || isPrewarming || isRunningCoreMLWork {
            pendingUnload = true
            return
        }
        await releaseLoadedWhisper()
    }

    // MARK: - Internal Coordination Helpers

    private func runCoordinatedWhisperTransition<T>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        if let coordinator = memoryCoordinator {
            return try await coordinator.runExclusiveLoad(
                for: .whisper,
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

    private func executeCoreMLSubtask<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let subtask = Task.detached(priority: .userInitiated) {
            try await work()
        }
        isRunningCoreMLWork = true
        cancelActiveCoreMLSubtask = { subtask.cancel() }
        defer {
            cancelActiveCoreMLSubtask = nil
            isRunningCoreMLWork = false
            let waiters = coreMLIdleWaiters
            coreMLIdleWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        return try await withTaskCancellationHandler {
            try await subtask.value
        } onCancel: {
            subtask.cancel()
        }
    }

    private func releaseLoadedWhisper() async {
        if let pipe = whisperKit {
            await pipe.unloadModels()
        }
        whisperKit = nil
        loadedFolderPath = nil
        loadedVariantRawValue = nil
        loadedVariantName = nil
        isLoaded = false
        memoryCoordinator?.markUnloaded(.whisper)
    }

    // MARK: - Compute, Silence & Gym Prompt Helpers

    private nonisolated static func makeComputeOptions() -> ModelComputeOptions {
        #if targetEnvironment(simulator)
        return ModelComputeOptions(
            melCompute: .cpuOnly,
            audioEncoderCompute: .cpuOnly,
            textDecoderCompute: .cpuOnly
        )
        #else
        // Running MelSpectrogram on CPU avoids spinning up a Metal GPU heap alongside CoreML ANE,
        // lowering peak iOS RAM while adding <5ms on short gym recordings.
        return ModelComputeOptions(
            melCompute: .cpuOnly,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
        #endif
    }

    /// Fast pre-Whisper silence filter so dead-air / muted taps never evict Qwen or hallucinate
    /// conditioning prompt text in WhisperKit v1.1.1 (where `noSpeechProb` is not yet computed).
    public nonisolated static func hasAudibleSpeech(
        in samples: [Float],
        minPeak: Float = 0.004,
        minRMS: Float = 0.0008
    ) -> Bool {
        guard !samples.isEmpty else { return false }
        var peak: Float = 0
        var sumSquares: Double = 0
        for sample in samples {
            let absVal = abs(sample)
            if absVal > peak { peak = absVal }
            sumSquares += Double(sample) * Double(sample)
        }
        let rms = Float(sqrt(sumSquares / Double(samples.count)))
        return peak >= minPeak || rms >= minRMS
    }

    /// Builds a compact (~35–50 BPE token) workout vocabulary prompt prioritizing the active
    /// session's exercises first, followed by the most commonly misheard gym lifts and units.
    /// Intentionally stays well below WhisperKit's 111-token `.suffix` truncation threshold and
    /// excludes destructive verbs ("delete", "remove", "finish", "end").
    public nonisolated static func buildGymBiasPrompt(recentExercises: [String] = []) -> String {
        var prioritized: [String] = []
        var seen: Set<String> = []
        let maxExercises = 6

        for exercise in recentExercises {
            let trimmed = exercise.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                prioritized.append(trimmed)
            }
            if prioritized.count >= 5 { break }
        }

        let coreLifts = [
            "bench press",
            "incline dumbbell press",
            "lat pulldown",
            "RDL",
            "leg extension",
            "lateral raise"
        ]

        for lift in coreLifts where prioritized.count < maxExercises {
            let key = lift.lowercased()
            if seen.insert(key).inserted {
                prioritized.append(lift)
            }
        }

        return "Gym log: \(prioritized.joined(separator: ", ")). sets, reps, kg, lbs, warmup."
    }

    /// Ensures ultra-short clips (0.15s–1.25s) have clean trailing silence before decoding.
    public nonisolated static func prepareAudioSamplesForWhisper(
        _ samples: [Float],
        minimumSamples: Int = 20_000
    ) -> [Float] {
        guard samples.count < minimumSamples else { return samples }
        return samples + Array(repeating: Float(0), count: minimumSamples - samples.count)
    }

    /// Strips Whisper control tokens (`<|...|>`), bracketed audio tags (`[BLANK_AUDIO]`, `[MUSIC]`),
    /// and non-numeric parenthetical sound descriptions (`(music)`, `(sighs)`).
    public nonisolated static func cleanTranscript(_ raw: String) -> String {
        var text = raw

        let artifactPatterns = [
            #"<\|[^|]*\|>"#,
            #"\[[^\]]*\]"#,
            #"\([A-Za-z\s_-]{1,32}\)"#
        ]

        for pattern in artifactPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
            }
        }

        if let whitespaceRegex = try? NSRegularExpression(pattern: #"\s+"#, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = whitespaceRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
