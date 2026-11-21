import AVFoundation
import Foundation
import Observation

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

    private let audioRecorder: AudioRecorderService
    private let whisperService: WhisperTranscriptionService
    private let llmService: LocalLLMService
    private let modelManager: ModelManager

    @ObservationIgnored private var operationToken: UInt64 = 0
    @ObservationIgnored private var isFinishingRecording: Bool = false
    @ObservationIgnored private var isRequestingPermission: Bool = false
    @ObservationIgnored private var startRecordingTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private weak var activeStoreForAutoStop: WorkoutStore?

    public init(
        audioRecorder: AudioRecorderService,
        whisperService: WhisperTranscriptionService,
        llmService: LocalLLMService,
        modelManager: ModelManager
    ) {
        self.audioRecorder = audioRecorder
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

        guard modelManager.isWhisperDownloaded else {
            phase = .error("Download the Whisper voice model in Settings to use voice logging, or type your set instead.")
            return
        }

        // Request microphone permission BEFORE entering `.recording` so iOS's system alert
        // never creates a fake recording state or triggers a "too short" error upon dismissal.
        let permission = AVAudioApplication.shared.recordPermission
        if permission == .undetermined {
            isRequestingPermission = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = await self.audioRecorder.requestPermission()
                self.isRequestingPermission = false
                if !granted {
                    self.phase = .error("Microphone permission is needed for offline voice logging. Enable it in iOS Settings.")
                }
            }
            return
        }

        guard permission == .granted else {
            phase = .error("Microphone permission is needed for offline voice logging. Enable it in iOS Settings.")
            return
        }

        operationToken &+= 1
        let token = operationToken
        isFinishingRecording = false
        liveTranscript = ""
        phase = .recording(isHoldMode: isHoldMode)

        startRecordingTask?.cancel()
        startRecordingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.audioRecorder.startRecording()
                if self.operationToken != token || Task.isCancelled {
                    self.audioRecorder.cancelRecording()
                }
            } catch {
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

            let samples = self.audioRecorder.stopRecording()
            guard samples.count >= 2_400 else {
                self.phase = .error("Recording was too short. Hold or tap a bit longer while speaking your set.")
                return
            }

            self.phase = .transcribing
            do {
                let transcript = try await self.whisperService.transcribe(samples: samples)
                guard self.operationToken == token, !Task.isCancelled else { return }

                let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanedTranscript.isEmpty else {
                    self.phase = .error("No speech detected. Try speaking slightly closer to the microphone.")
                    return
                }

                self.liveTranscript = cleanedTranscript
                self.phase = .parsing

                let context = store.promptContext()
                let intent = await self.llmService.parseVoiceTranscript(cleanedTranscript, context: context)
                guard self.operationToken == token, !Task.isCancelled else { return }

                self.applyIntent(intent, transcript: cleanedTranscript, into: store)
            } catch is CancellationError {
                if self.operationToken == token {
                    self.phase = .idle
                }
            } catch {
                if self.operationToken == token {
                    self.phase = .error(error.localizedDescription)
                }
            }
        }
    }

    public func cancelRecording() {
        operationToken &+= 1
        isFinishingRecording = false
        startRecordingTask?.cancel()
        startRecordingTask = nil
        processingTask?.cancel()
        processingTask = nil
        llmService.stopGeneration()
        audioRecorder.cancelRecording()
        liveTranscript = ""
        phase = .idle
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

        processingTask?.cancel()
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }

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

    private func applyIntent(_ intent: WorkoutCommandIntent, transcript: String, into store: WorkoutStore) {
        if intent.action == .unknown {
            phase = .error("Couldn't match a workout set from \"\(transcript)\". Try \"Leg extension 3 sets 15 reps\".")
            return
        }

        let result = store.apply(intent)
        if result == nil {
            switch intent.action {
            case .updateLastSet:
                phase = .error("No active set found to update.")
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
