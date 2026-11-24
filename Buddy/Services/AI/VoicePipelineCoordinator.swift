import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

public typealias PipelinePhase = VoicePipelineCoordinator.PipelinePhase

@Observable
@MainActor
public final class VoicePipelineCoordinator {
    public enum PipelinePhase: Equatable, Sendable {
        case idle
        case recording(isHoldMode: Bool)
        case transcribing
        case parsing
        case error(String)

        fileprivate var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    public var phase: PipelinePhase = .idle
    public var liveTranscript: String = ""
    public var pendingRecap: PendingSessionRecap?
    public var isRecapCaptureMode: Bool = false
    public var recapTargetDate: Date?

    public var audioLevels: [Float] {
        audioRecorder.audioLevels
    }

    public var recordingDuration: TimeInterval {
        audioRecorder.recordingDuration
    }

    public var transcribingStageTitle: String {
        if activeRecordingEngine == .whisperKit {
            if whisperService.isPrewarming {
                return "Optimizing Whisper (one-time)…"
            }
            if whisperService.isLoading {
                return "Loading \(modelManager.selectedWhisperPreset.shortDisplayName)…"
            }
            return "Transcribing with Whisper…"
        }
        return "Finalizing speech…"
    }

    public var parsingStageTitle: String {
        if activeRecordingEngine == .whisperKit {
            return "Parsing sets…"
        }
        return modelManager.isLLMDownloaded ? "Parsing with Qwen…" : "Parsing sets…"
    }

    public var processingModeCaption: String {
        if activeRecordingEngine == .whisperKit {
            return "\(modelManager.selectedWhisperPreset.shortDisplayName) · 100% Offline"
        }
        if appleSpeechService.isUsingCloudEnhancedSpeech {
            return "Apple Cloud-Enhanced Speech"
        }
        return "Processing 100% offline"
    }

    private let audioRecorder: AudioRecorderService
    private let appleSpeechService: AppleSpeechService
    private let whisperService: WhisperTranscriptionService
    private let llmService: LocalLLMService
    private let modelManager: ModelManager

    private var activeRecordingEngine: SpeechEngine = .appleSpeech
    @ObservationIgnored private var operationToken: UInt64 = 0
    @ObservationIgnored private var isFinishingRecording: Bool = false
    @ObservationIgnored private var isRequestingPermission: Bool = false
    @ObservationIgnored private var startRecordingTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var pendingAudioSamples: [Float]?
    @ObservationIgnored private var pendingTranscript: String?
    @ObservationIgnored private weak var activeStoreForAutoStop: WorkoutStore?

    public init(
        audioRecorder: AudioRecorderService,
        appleSpeechService: AppleSpeechService,
        whisperService: WhisperTranscriptionService,
        llmService: LocalLLMService,
        modelManager: ModelManager
    ) {
        self.audioRecorder = audioRecorder
        self.appleSpeechService = appleSpeechService
        self.whisperService = whisperService
        self.llmService = llmService
        self.modelManager = modelManager

        self.audioRecorder.onMaxDurationReached = { [weak self] in
            guard let self, case .recording = self.phase else { return }
            if let store = self.activeStoreForAutoStop {
                self.finishRecordingAndProcess(into: store)
            } else {
                self.cancelRecording()
            }
        }

        self.audioRecorder.onAudioInterrupted = { [weak self] reason in
            guard let self, case .recording = self.phase else { return }
            self.operationToken &+= 1
            self.isFinishingRecording = false
            self.isRecapCaptureMode = false
            self.recapTargetDate = nil
            self.audioRecorder.setAudioBufferHandler(nil)
            self.audioRecorder.onEngineRestarted = nil
            self.appleSpeechService.cancelStreaming()
            self.phase = .error(reason)
        }
    }

    /// Registers the active `WorkoutStore` used if recording hits the 3-minute cap or an AirPods route change.
    public func attachStore(_ store: WorkoutStore) {
        activeStoreForAutoStop = store
    }

    /// Starts a dedicated full-session voice recap capture (targeting `date`) that always opens the
    /// monochrome Review & Confirm sheet once finished so the user can review all parsed exercises.
    public func beginRecapRecording(for date: Date = Date()) {
        guard phase == .idle || phase.isError else { return }
        guard !isRequestingPermission else { return }
        isRecapCaptureMode = true
        recapTargetDate = date
        beginRecording(isHoldMode: false, preserveRecapMode: true)
    }

    public func dismissPendingRecap() {
        pendingRecap = nil
    }

    public func reparseRecapTranscript(
        _ text: String,
        context: ActiveSessionPromptContext
    ) async -> WorkoutCommandIntent {
        await llmService.parseVoiceTranscript(
            text,
            context: context,
            preferInstantParserWhenConfident: whisperService.isLoaded
        )
    }

    public func beginRecording(isHoldMode: Bool) {
        beginRecording(isHoldMode: isHoldMode, preserveRecapMode: false)
    }

    private func beginRecording(isHoldMode: Bool, preserveRecapMode: Bool) {
        guard phase == .idle || phase.isError else { return }
        guard !isRequestingPermission else { return }
        if !preserveRecapMode {
            isRecapCaptureMode = false
            recapTargetDate = nil
        }

        // Request microphone permission BEFORE entering `.recording` so iOS's system alert
        // never creates a fake recording state or triggers a "too short" error upon dismissal.
        let micPermission = AVAudioApplication.shared.recordPermission
        if micPermission == .undetermined {
            isRequestingPermission = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = await self.audioRecorder.requestPermission()
                self.isRequestingPermission = false
                if granted {
                    if !isHoldMode && UIApplication.shared.applicationState != .background {
                        self.beginRecording(isHoldMode: false, preserveRecapMode: preserveRecapMode)
                    }
                } else {
                    self.isRecapCaptureMode = false
                    self.recapTargetDate = nil
                    self.phase = .error("Microphone permission is needed for offline voice logging. Enable it in iOS Settings.")
                }
            }
            return
        }

        guard micPermission == .granted else {
            isRecapCaptureMode = false
            recapTargetDate = nil
            phase = .error("Microphone permission is needed for offline voice logging. Enable it in iOS Settings.")
            return
        }

        let chosenEngine = modelManager.effectiveSpeechEngine

        // Apple Speech requires Speech Recognition permission & locale availability;
        // WhisperKit runs 100% locally via CoreML and only needs Microphone access.
        if chosenEngine == .appleSpeech {
            let speechStatus = SFSpeechRecognizer.authorizationStatus()
            if speechStatus == .notDetermined {
                isRequestingPermission = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let granted = await self.appleSpeechService.requestAuthorization()
                    self.isRequestingPermission = false
                    if granted {
                        if !isHoldMode && UIApplication.shared.applicationState != .background {
                            self.beginRecording(isHoldMode: false, preserveRecapMode: preserveRecapMode)
                        }
                    } else {
                        self.isRecapCaptureMode = false
                        self.recapTargetDate = nil
                        self.phase = .error(AppleSpeechError.permissionDenied.localizedDescription)
                    }
                }
                return
            }

            guard speechStatus == .authorized else {
                isRecapCaptureMode = false
                recapTargetDate = nil
                phase = .error(AppleSpeechError.permissionDenied.localizedDescription)
                return
            }

            let speechMode = modelManager.selectedAppleSpeechMode
            let availability = appleSpeechService.checkAvailability(
                for: modelManager.selectedAppleSpeechLocale,
                mode: speechMode
            )
            guard availability.isReady else {
                isRecapCaptureMode = false
                recapTargetDate = nil
                phase = .error(availability.statusMessage)
                return
            }
        }

        activeRecordingEngine = chosenEngine
        operationToken &+= 1
        let token = operationToken
        isFinishingRecording = false
        pendingAudioSamples = nil
        pendingTranscript = nil
        liveTranscript = ""
        phase = .recording(isHoldMode: isHoldMode)

        startRecordingTask?.cancel()
        startRecordingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let captureOptions = self.modelManager.audioCaptureOptions

                if chosenEngine == .whisperKit {
                    self.audioRecorder.setAudioBufferHandler(nil)
                    self.audioRecorder.onEngineRestarted = nil
                    try await self.audioRecorder.startRecording(
                        options: captureOptions,
                        captureRawSamples: true
                    )
                } else {
                    let localeOption = self.modelManager.selectedAppleSpeechLocale
                    let recognitionMode = self.modelManager.selectedAppleSpeechMode
                    let parserContext = self.activeStoreForAutoStop?.promptContext() ?? ActiveSessionPromptContext()
                    let recentExercises = self.activeStoreForAutoStop?.activeSession?.sortedEntries.map(\.canonicalName) ?? []
                    let contextualStrings = AppleSpeechService.buildGymContextualStrings(recentExercises: recentExercises)

                    self.audioRecorder.setAudioBufferHandler { [weak speech = self.appleSpeechService] buffer in
                        speech?.appendBuffer(buffer)
                    }

                    // AudioRecorderService removes the old bus-0 tap and stops the engine BEFORE
                    // invoking onEngineRestarted, so starting a fresh SFSpeechAudioBufferRecognitionRequest
                    // safely adopts the new hardware format and propagates any recognizer errors.
                    self.audioRecorder.onEngineRestarted = { [weak self] in
                        guard let self, self.operationToken == token else { return }
                        try self.startAppleSpeechSession(
                            token: token,
                            localeOption: localeOption,
                            recognitionMode: recognitionMode,
                            contextualStrings: contextualStrings,
                            parserContext: parserContext
                        )
                    }

                    try await self.audioRecorder.startRecording(
                        options: captureOptions,
                        captureRawSamples: false
                    ) { [weak self] in
                        guard let self, self.operationToken == token else { return }
                        try self.startAppleSpeechSession(
                            token: token,
                            localeOption: localeOption,
                            recognitionMode: recognitionMode,
                            contextualStrings: contextualStrings,
                            parserContext: parserContext
                        )
                    }
                }

                if self.operationToken != token || Task.isCancelled {
                    self.audioRecorder.setAudioBufferHandler(nil)
                    self.audioRecorder.onEngineRestarted = nil
                    self.audioRecorder.cancelRecording()
                    self.appleSpeechService.cancelStreaming()
                }
            } catch {
                self.audioRecorder.setAudioBufferHandler(nil)
                self.audioRecorder.onEngineRestarted = nil
                self.appleSpeechService.cancelStreaming()
                guard self.operationToken == token else { return }
                self.phase = .error(error.localizedDescription)
            }
        }
    }

    public func promoteToHoldMode() {
        if phase == .recording(isHoldMode: false) {
            phase = .recording(isHoldMode: true)
        }
    }

    public func finishRecordingAndProcess(into store: WorkoutStore) {
        guard case .recording = phase, !isFinishingRecording else { return }
        activeStoreForAutoStop = store
        isFinishingRecording = true

        let token = operationToken
        let engine = activeRecordingEngine
        processingTask?.cancel()
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.operationToken == token {
                    self.isFinishingRecording = false
                }
            }

            // Wait briefly if AVAudioEngine setup is still completing after a rapid press/release.
            await self.startRecordingTask?.value
            guard self.operationToken == token, !Task.isCancelled else { return }

            guard self.audioRecorder.isRecording else {
                if case .recording = self.phase {
                    self.phase = .idle
                }
                return
            }

            self.audioRecorder.setAudioBufferHandler(nil)
            self.audioRecorder.onEngineRestarted = nil

            if engine == .whisperKit {
                self.phase = .transcribing
                let captured = await self.audioRecorder.stopRecordingAndDrain16kHzSamples()
                guard self.operationToken == token, !Task.isCancelled else { return }

                if captured.duration < 0.15 || captured.samples.count < 1_600 {
                    self.phase = .error("Recording was too short. Hold or tap a bit longer while speaking your set.")
                    return
                }

                await self.runWhisperTranscriptionAndParse(samples: captured.samples, token: token, into: store)
            } else {
                let capturedDuration = self.audioRecorder.stopRecording()
                let existingPartial = self.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if capturedDuration < 0.15 && existingPartial.isEmpty {
                    self.appleSpeechService.cancelStreaming()
                    self.phase = .error("Recording was too short. Hold or tap a bit longer while speaking your set.")
                    return
                }

                await self.runAppleSpeechFinishAndParse(token: token, into: store)
            }
        }
    }

    public func cancelRecording() {
        let wasParsing = (phase == .parsing)
        operationToken &+= 1
        isFinishingRecording = false
        isRecapCaptureMode = false
        recapTargetDate = nil
        startRecordingTask?.cancel()
        startRecordingTask = nil
        processingTask?.cancel()
        processingTask = nil
        pendingAudioSamples = nil
        pendingTranscript = nil
        if wasParsing {
            llmService.stopVoiceParsing()
        }
        whisperService.cancelInFlightWork()
        audioRecorder.setAudioBufferHandler(nil)
        audioRecorder.onEngineRestarted = nil
        audioRecorder.cancelRecording()
        appleSpeechService.cancelStreaming()
        endBackgroundProcessingTask()
        liveTranscript = ""
        phase = .idle
    }

    /// Handles iOS scene backgrounding safely without dropping already-captured voice sets.
    public func handleEnteredBackground(store: WorkoutStore) {
        activeStoreForAutoStop = store

        switch phase {
        case .recording:
            if !isFinishingRecording {
                cancelRecording()
            } else if backgroundTaskID == .invalid {
                beginBackgroundProcessingTask(forToken: operationToken)
            }
        case .parsing:
            let transcript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                cancelRecording()
                return
            }

            operationToken &+= 1
            isFinishingRecording = false
            processingTask?.cancel()
            processingTask = nil
            llmService.stopVoiceParsing()

            let fallbackIntent = RuleBasedWorkoutParser.parse(transcript, context: store.promptContext())
            if fallbackIntent.action != .unknown {
                applyIntent(fallbackIntent, transcript: transcript, into: store)
            } else {
                pendingTranscript = transcript
                liveTranscript = ""
                phase = .idle
            }
            endBackgroundProcessingTask()
        case .transcribing:
            if backgroundTaskID == .invalid {
                beginBackgroundProcessingTask(forToken: operationToken)
            }
        case .idle, .error:
            break
        }
    }

    /// Resumes any captured audio or transcript that was deferred while backgrounded.
    public func resumePendingWorkIfNeeded(into store: WorkoutStore) {
        activeStoreForAutoStop = store
        guard phase == .idle || phase.isError else { return }

        if let samples = pendingAudioSamples, samples.count >= 1_600 {
            pendingAudioSamples = nil
            activeRecordingEngine = .whisperKit
            operationToken &+= 1
            let token = operationToken
            liveTranscript = ""
            processingTask?.cancel()
            processingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runWhisperTranscriptionAndParse(samples: samples, token: token, into: store)
            }
        } else if let transcript = pendingTranscript, !transcript.isEmpty {
            pendingTranscript = nil
            processTypedInput(transcript, into: store)
        }
    }

    public func processTypedInput(_ text: String, into store: WorkoutStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard phase == .idle || phase.isError else { return }
        activeStoreForAutoStop = store

        activeRecordingEngine = .appleSpeech
        operationToken &+= 1
        let token = operationToken
        liveTranscript = trimmed
        phase = .parsing
        beginBackgroundProcessingTask(forToken: token)

        processingTask?.cancel()
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.operationToken == token {
                    self.endBackgroundProcessingTask()
                }
            }

            let context = store.promptContext()
            let preferInstant = self.whisperService.isLoaded
            let intent = await self.llmService.parseVoiceTranscript(
                trimmed,
                context: context,
                preferInstantParserWhenConfident: preferInstant
            )
            guard self.operationToken == token, !Task.isCancelled else { return }

            self.applyIntent(intent, transcript: trimmed, into: store)
        }
    }

    public func dismissError() {
        if phase.isError {
            phase = .idle
        }
    }

    // MARK: - Private Helpers

    private func startAppleSpeechSession(
        token: UInt64,
        localeOption: AppleSpeechLocaleOption,
        recognitionMode: AppleSpeechRecognitionMode,
        contextualStrings: [String],
        parserContext: ActiveSessionPromptContext
    ) throws {
        try appleSpeechService.startStreaming(
            localeOption: localeOption,
            recognitionMode: recognitionMode,
            contextualStrings: contextualStrings,
            parserContext: parserContext
        ) { [weak self] partial in
            guard let self, self.operationToken == token else { return }
            self.liveTranscript = partial
        }
    }

    private func runWhisperTranscriptionAndParse(
        samples: [Float],
        token: UInt64,
        into store: WorkoutStore
    ) async {
        pendingAudioSamples = samples
        beginBackgroundProcessingTask(forToken: token)
        defer {
            if operationToken == token {
                endBackgroundProcessingTask()
            }
        }

        phase = .transcribing
        do {
            let recentExercises = store.activeSession?.sortedEntries.map(\.exerciseName) ?? []
            let transcript = try await whisperService.transcribe(
                samples: samples,
                recentExercises: recentExercises
            )
            guard operationToken == token, !Task.isCancelled else { return }

            pendingAudioSamples = nil
            let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTranscript.isEmpty else {
                phase = .error("No speech detected. Try speaking slightly closer to the microphone.")
                return
            }

            await parseAndApplyTranscript(
                cleanedTranscript,
                token: token,
                preferInstantParserWhenConfident: true,
                into: store
            )
        } catch is CancellationError {
            if operationToken == token {
                pendingAudioSamples = nil
                phase = .idle
            }
        } catch {
            guard operationToken == token else { return }
            if UIApplication.shared.applicationState != .active {
                // Keep `pendingAudioSamples` so `.active` resumes transcription cleanly when unlocked.
                phase = .idle
            } else {
                pendingAudioSamples = nil
                phase = .error(error.localizedDescription)
            }
        }
    }

    private func runAppleSpeechFinishAndParse(
        token: UInt64,
        into store: WorkoutStore
    ) async {
        beginBackgroundProcessingTask(forToken: token)
        defer {
            if operationToken == token {
                endBackgroundProcessingTask()
            }
        }

        phase = .transcribing
        do {
            let timeout: TimeInterval = appleSpeechService.isUsingCloudEnhancedSpeech ? 1.6 : 1.2
            let finalized = try await appleSpeechService.finishStreaming(timeoutSeconds: timeout)
            guard operationToken == token, !Task.isCancelled else { return }

            let candidate = finalized.isEmpty ? liveTranscript : finalized
            let cleanedTranscript = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTranscript.isEmpty else {
                phase = .error("No speech detected. Try speaking slightly closer to the microphone.")
                return
            }

            await parseAndApplyTranscript(
                cleanedTranscript,
                token: token,
                preferInstantParserWhenConfident: false,
                into: store
            )
        } catch is CancellationError {
            if operationToken == token {
                phase = .idle
            }
        } catch {
            guard operationToken == token else { return }
            let partialFallback = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partialFallback.isEmpty {
                await parseAndApplyTranscript(
                    partialFallback,
                    token: token,
                    preferInstantParserWhenConfident: false,
                    into: store
                )
            } else if UIApplication.shared.applicationState != .active {
                phase = .idle
            } else {
                phase = .error(error.localizedDescription)
            }
        }
    }

    private func parseAndApplyTranscript(
        _ cleanedTranscript: String,
        token: UInt64,
        preferInstantParserWhenConfident: Bool,
        into store: WorkoutStore
    ) async {
        liveTranscript = cleanedTranscript

        if UIApplication.shared.applicationState != .active {
            let cpuIntent = RuleBasedWorkoutParser.parse(cleanedTranscript, context: store.promptContext())
            if cpuIntent.action != .unknown {
                applyIntent(cpuIntent, transcript: cleanedTranscript, into: store)
            } else {
                pendingTranscript = cleanedTranscript
                liveTranscript = ""
                phase = .idle
            }
            return
        }

        phase = .parsing
        let context = store.promptContext()
        let intent = await llmService.parseVoiceTranscript(
            cleanedTranscript,
            context: context,
            preferInstantParserWhenConfident: preferInstantParserWhenConfident
        )
        guard operationToken == token, !Task.isCancelled else { return }

        applyIntent(intent, transcript: cleanedTranscript, into: store)
    }

    private func beginBackgroundProcessingTask(forToken token: UInt64) {
        endBackgroundProcessingTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "BuddyVoiceProcessing") { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBackgroundTaskExpiration(forToken: token)
            }
        }
    }

    private func endBackgroundProcessingTask() {
        let taskID = backgroundTaskID
        guard taskID != .invalid else { return }
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
    }

    private func handleBackgroundTaskExpiration(forToken token: UInt64) {
        defer { endBackgroundProcessingTask() }
        guard operationToken == token else { return }

        if (phase == .parsing || phase == .transcribing),
           !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let store = activeStoreForAutoStop {
            let transcript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            operationToken &+= 1
            isFinishingRecording = false
            processingTask?.cancel()
            processingTask = nil
            whisperService.cancelInFlightWork()
            appleSpeechService.cancelStreaming()
            llmService.stopVoiceParsing()

            let cpuIntent = RuleBasedWorkoutParser.parse(transcript, context: store.promptContext())
            if cpuIntent.action != .unknown {
                applyIntent(cpuIntent, transcript: transcript, into: store)
            } else {
                pendingTranscript = transcript
                liveTranscript = ""
                phase = .idle
            }
            return
        }

        let wasParsing = (phase == .parsing)
        operationToken &+= 1
        isFinishingRecording = false
        processingTask?.cancel()
        processingTask = nil
        whisperService.cancelInFlightWork()
        appleSpeechService.cancelStreaming()
        if wasParsing {
            llmService.stopVoiceParsing()
        }
        liveTranscript = ""
        phase = .idle
    }

    private func applyIntent(_ intent: WorkoutCommandIntent, transcript: String, into store: WorkoutStore) {
        let wasRecapMode = isRecapCaptureMode
        let targetDate = recapTargetDate ?? Date()
        isRecapCaptureMode = false
        recapTargetDate = nil

        if intent.action == .unknown {
            phase = .error("Couldn't match a workout set from \"\(transcript)\". Try \"Bench press 60 kg 3 sets 10 reps\".")
            return
        }

        // Open the Review & Confirm sheet whenever the user explicitly started a full-session Recap
        // (including past-day Calendar voice logs) OR dictated 2+ distinct exercises in a single go.
        if intent.action == .logSets && !intent.items.isEmpty && (wasRecapMode || intent.distinctExerciseCount >= 2) {
            let isToday = Calendar.current.isDateInToday(targetDate)
            pendingRecap = PendingSessionRecap(
                items: intent.items,
                rawTranscript: transcript,
                parserSource: intent.parserSource,
                targetDate: targetDate,
                suggestedTitle: intent.suggestedSessionTitle,
                defaultFinishImmediately: wasRecapMode || !isToday || store.activeSession == nil
            )
            phase = .idle
            return
        }

        let result = store.apply(intent)
        if result == nil {
            switch intent.action {
            case .updateLastSet:
                if (store.activeSession?.totalSets ?? 0) > 0 {
                    phase = .error("No changes detected for the last set.")
                } else {
                    phase = .error("No active set found to update.")
                }
            case .deleteLastSet:
                phase = .error("No active set found to delete.")
            case .deleteLastExercise:
                phase = .error("No active exercise found to delete.")
            case .endSession:
                phase = .error("No active workout session to finish.")
            case .logSets, .unknown:
                phase = .error("Couldn't log sets from \"\(transcript)\".")
            }
            return
        }

        phase = .idle
    }
}
