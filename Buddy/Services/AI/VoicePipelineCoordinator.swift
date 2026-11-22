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

    public var audioLevels: [Float] {
        audioRecorder.audioLevels
    }

    public var recordingDuration: TimeInterval {
        audioRecorder.recordingDuration
    }

    public var activeSpeechEngine: SpeechEngine {
        modelManager.selectedSpeechEngine
    }

    public var transcribingStageTitle: String {
        switch activeRecordingEngine {
        case .appleOnDevice:
            return "Finalizing speech…"
        case .whisperKit:
            return "Whisper transcribing…"
        }
    }

    public var parsingStageTitle: String {
        modelManager.isLLMDownloaded ? "Qwen parsing sets…" : "Parsing sets…"
    }

    private let audioRecorder: AudioRecorderService
    private let appleSpeechService: AppleSpeechService
    private let whisperService: WhisperTranscriptionService
    private let llmService: LocalLLMService
    private let modelManager: ModelManager

    @ObservationIgnored private var operationToken: UInt64 = 0
    @ObservationIgnored private var activeRecordingEngine: SpeechEngine = .appleOnDevice
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
            self.audioRecorder.setAudioBufferHandler(nil)
            self.audioRecorder.onEngineRestarted = nil
            self.appleSpeechService.cancelStreaming()
            self.phase = .error(reason)
        }
    }

    /// Registers the active `WorkoutStore` used if recording hits the 60s cap or an AirPods route change.
    public func attachStore(_ store: WorkoutStore) {
        activeStoreForAutoStop = store
    }

    public func beginRecording(isHoldMode: Bool) {
        guard phase == .idle || phase.isError else { return }
        guard !isRequestingPermission else { return }

        let engine = modelManager.selectedSpeechEngine

        if engine == .whisperKit {
            guard modelManager.isWhisperDownloaded else {
                phase = .error("Download a Whisper model in Settings, or switch Speech Engine to Apple On-Device.")
                return
            }
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
                    // For tap-to-record and widget `buddy://record` deep links, continue immediately
                    // once allowed. Hold-to-talk gestures ended when the system alert appeared.
                    if !isHoldMode && UIApplication.shared.applicationState != .background {
                        self.beginRecording(isHoldMode: false)
                    }
                } else {
                    self.phase = .error("Microphone permission is needed for offline voice logging. Enable it in iOS Settings.")
                }
            }
            return
        }

        guard micPermission == .granted else {
            phase = .error("Microphone permission is needed for offline voice logging. Enable it in iOS Settings.")
            return
        }

        if engine == .appleOnDevice {
            let speechStatus = SFSpeechRecognizer.authorizationStatus()
            if speechStatus == .notDetermined {
                isRequestingPermission = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let granted = await self.appleSpeechService.requestAuthorization()
                    self.isRequestingPermission = false
                    if granted {
                        if !isHoldMode && UIApplication.shared.applicationState != .background {
                            self.beginRecording(isHoldMode: false)
                        }
                    } else {
                        self.phase = .error(AppleSpeechError.permissionDenied.localizedDescription)
                    }
                }
                return
            }

            guard speechStatus == .authorized else {
                phase = .error(AppleSpeechError.permissionDenied.localizedDescription)
                return
            }

            let availability = appleSpeechService.checkAvailability(for: modelManager.selectedAppleSpeechLocale)
            guard availability.isReady else {
                phase = .error(availability.statusMessage)
                return
            }
        }

        operationToken &+= 1
        let token = operationToken
        activeRecordingEngine = engine
        isFinishingRecording = false
        pendingAudioSamples = nil
        pendingTranscript = nil
        liveTranscript = ""
        phase = .recording(isHoldMode: isHoldMode)

        startRecordingTask?.cancel()
        startRecordingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if engine == .appleOnDevice {
                    let localeOption = self.modelManager.selectedAppleSpeechLocale
                    let recentExercises = self.activeStoreForAutoStop?.activeSession?.sortedEntries.map(\.canonicalName) ?? []
                    let contextualStrings = AppleSpeechService.buildGymContextualStrings(recentExercises: recentExercises)

                    try self.startAppleSpeechSession(
                        token: token,
                        localeOption: localeOption,
                        contextualStrings: contextualStrings
                    )

                    self.audioRecorder.setAudioBufferHandler { [weak speech = self.appleSpeechService] buffer in
                        speech?.appendBuffer(buffer)
                    }

                    // If AirPods renegotiate sample rate (48 kHz -> 16 kHz HFP) in the first ~250ms,
                    // start a fresh SFSpeechAudioBufferRecognitionRequest matching the updated format.
                    self.audioRecorder.onEngineRestarted = { [weak self] in
                        guard let self, self.operationToken == token else { return }
                        try? self.startAppleSpeechSession(
                            token: token,
                            localeOption: localeOption,
                            contextualStrings: contextualStrings
                        )
                    }
                } else {
                    self.audioRecorder.setAudioBufferHandler(nil)
                    self.audioRecorder.onEngineRestarted = nil
                }

                try await self.audioRecorder.startRecording()

                if self.operationToken != token || Task.isCancelled {
                    self.audioRecorder.setAudioBufferHandler(nil)
                    self.audioRecorder.onEngineRestarted = nil
                    self.audioRecorder.cancelRecording()
                    if engine == .appleOnDevice {
                        self.appleSpeechService.cancelStreaming()
                    }
                }
            } catch {
                self.audioRecorder.setAudioBufferHandler(nil)
                self.audioRecorder.onEngineRestarted = nil
                if engine == .appleOnDevice {
                    self.appleSpeechService.cancelStreaming()
                }
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

            switch engine {
            case .appleOnDevice:
                let capturedDuration = self.audioRecorder.stopRecordingDurationOnly()
                let existingPartial = self.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if capturedDuration < 0.15 && existingPartial.isEmpty {
                    self.appleSpeechService.cancelStreaming()
                    self.phase = .error("Recording was too short. Hold or tap a bit longer while speaking your set.")
                    return
                }
                await self.runAppleSpeechFinishAndParse(token: token, into: store)

            case .whisperKit:
                let samples = self.audioRecorder.stopRecording()
                guard samples.count >= 2_400 else {
                    self.phase = .error("Recording was too short. Hold or tap a bit longer while speaking your set.")
                    return
                }
                await self.runWhisperTranscriptionAndParse(samples: samples, token: token, into: store)
            }
        }
    }

    public func cancelRecording() {
        let wasParsing = (phase == .parsing)
        operationToken &+= 1
        isFinishingRecording = false
        startRecordingTask?.cancel()
        startRecordingTask = nil
        processingTask?.cancel()
        processingTask = nil
        pendingAudioSamples = nil
        pendingTranscript = nil
        if wasParsing {
            llmService.stopVoiceParsing()
        }
        audioRecorder.setAudioBufferHandler(nil)
        audioRecorder.onEngineRestarted = nil
        audioRecorder.cancelRecording()
        appleSpeechService.cancelStreaming()
        endBackgroundProcessingTask()
        liveTranscript = ""
        phase = .idle
    }

    /// Handles iOS scene backgrounding safely without dropping already-captured voice sets:
    /// - Active mic capture (`.recording`, unless finalizing) is cancelled cleanly.
    /// - `.parsing` avoids background Metal GPU work by saving immediately via the deterministic CPU parser
    ///   (or deferring `pendingTranscript` until returning to `.active` if unmatched).
    /// - `.transcribing` continues inside `UIBackgroundTask` and retains `pendingAudioSamples` if iOS interrupts it.
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
            pendingAudioSamples = nil
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

        if let samples = pendingAudioSamples, samples.count >= 2_400 {
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
            let intent = await self.llmService.parseVoiceTranscript(trimmed, context: context)
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
        contextualStrings: [String]
    ) throws {
        try appleSpeechService.startStreaming(
            localeOption: localeOption,
            contextualStrings: contextualStrings
        ) { [weak self] partial in
            guard let self, self.operationToken == token else { return }
            self.liveTranscript = partial
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
            let finalized = try await appleSpeechService.finishStreaming(timeoutSeconds: 1.2)
            guard operationToken == token, !Task.isCancelled else { return }

            let candidate = finalized.isEmpty ? liveTranscript : finalized
            let cleanedTranscript = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTranscript.isEmpty else {
                phase = .error("No speech detected. Try speaking slightly closer to the microphone.")
                return
            }

            await parseAndApplyTranscript(cleanedTranscript, token: token, into: store)
        } catch is CancellationError {
            if operationToken == token {
                phase = .idle
            }
        } catch {
            guard operationToken == token else { return }
            let partialFallback = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partialFallback.isEmpty {
                await parseAndApplyTranscript(partialFallback, token: token, into: store)
            } else {
                phase = .error(error.localizedDescription)
            }
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
            let transcript = try await whisperService.transcribe(samples: samples)
            guard operationToken == token, !Task.isCancelled else { return }

            pendingAudioSamples = nil
            let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTranscript.isEmpty else {
                phase = .error("No speech detected. Try speaking slightly closer to the microphone.")
                return
            }

            await parseAndApplyTranscript(cleanedTranscript, token: token, into: store)
        } catch is CancellationError {
            if operationToken == token {
                phase = .idle
            }
        } catch {
            guard operationToken == token else { return }
            if UIApplication.shared.applicationState == .background {
                // Keep `pendingAudioSamples` so `.active` resumes transcription when unlocked.
                phase = .idle
            } else {
                pendingAudioSamples = nil
                phase = .error(error.localizedDescription)
            }
        }
    }

    private func parseAndApplyTranscript(
        _ cleanedTranscript: String,
        token: UInt64,
        into store: WorkoutStore
    ) async {
        liveTranscript = cleanedTranscript

        // Avoid launching Metal GPU LLM inference while backgrounded; finish via CPU parser
        // so sets and Live Activities update immediately, or defer unmatched text to foreground.
        if UIApplication.shared.applicationState == .background {
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
        let intent = await llmService.parseVoiceTranscript(cleanedTranscript, context: context)
        guard operationToken == token, !Task.isCancelled else { return }

        applyIntent(intent, transcript: cleanedTranscript, into: store)
    }

    private func beginBackgroundProcessingTask(forToken token: UInt64) {
        endBackgroundProcessingTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "BuddyVoiceProcessing") { [weak self] in
            self?.handleBackgroundTaskExpiration(forToken: token)
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
            pendingAudioSamples = nil
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

        // Preserve any pending audio samples so returning to foreground finishes logging.
        let preservedSamples = pendingAudioSamples
        let wasParsing = (phase == .parsing)
        operationToken &+= 1
        isFinishingRecording = false
        processingTask?.cancel()
        processingTask = nil
        appleSpeechService.cancelStreaming()
        if wasParsing {
            llmService.stopVoiceParsing()
        }
        pendingAudioSamples = preservedSamples
        liveTranscript = ""
        phase = .idle
    }

    private func applyIntent(_ intent: WorkoutCommandIntent, transcript: String, into store: WorkoutStore) {
        if intent.action == .unknown {
            phase = .error("Couldn't match a workout set from \"\(transcript)\". Try \"Leg extension 3 sets 15 reps\".")
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
