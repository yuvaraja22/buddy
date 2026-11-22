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
            return "Whisper model is not downloaded yet. Open Settings to download it."
        case .emptyAudio:
            return "No audio was captured. Please try speaking again."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
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

@Observable
@MainActor
public final class WhisperTranscriptionService {
    public var isLoaded: Bool = false
    public var isLoading: Bool = false
    public var loadedVariantName: String?

    private let modelManager: ModelManager
    @ObservationIgnored private var whisperKit: WhisperKit?
    @ObservationIgnored private var loadedFolderPath: String?
    @ObservationIgnored private var loadedVariantRawValue: String?
    @ObservationIgnored private var isTranscribing: Bool = false
    @ObservationIgnored private var memoryWarningDuringActivity: Bool = false
    @ObservationIgnored private var inFlightLoadTask: Task<Void, Error>?
    @ObservationIgnored private var memoryWarningObserver: WhisperMemoryObserverToken?

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.memoryWarningObserver = WhisperMemoryObserverToken { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTranscribing || self.isLoading {
                    self.memoryWarningDuringActivity = true
                } else {
                    await self.unload()
                }
            }
        }
    }

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

        if let existingTask = inFlightLoadTask {
            try await existingTask.value
            if whisperKit != nil,
               isLoaded,
               loadedFolderPath == desiredPath,
               loadedVariantRawValue == desiredVariant {
                return
            }
        }

        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }
            if self.whisperKit != nil {
                await self.unload()
            }

            self.memoryWarningDuringActivity = false
            self.isLoading = true
            defer { self.isLoading = false }

            let computeOptions = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )

            let config = WhisperKitConfig(
                modelFolder: desiredPath,
                tokenizerFolder: self.modelManager.whisperBaseDirectory,
                computeOptions: computeOptions,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )

            let pipe = try await WhisperKit(config)
            if self.memoryWarningDuringActivity || Task.isCancelled {
                await pipe.unloadModels()
                self.memoryWarningDuringActivity = false
                if Task.isCancelled { throw CancellationError() }
                throw WhisperServiceError.transcriptionFailed("Released speech model due to low iPhone memory. Please try again.")
            }

            self.whisperKit = pipe
            self.loadedFolderPath = desiredPath
            self.loadedVariantRawValue = desiredVariant
            self.loadedVariantName = desiredPreset.displayName
            self.isLoaded = true
        }

        inFlightLoadTask = task
        defer { inFlightLoadTask = nil }
        try await task.value
    }

    public func transcribe(samples: [Float]) async throws -> String {
        guard samples.count >= 1_600 else {
            throw WhisperServiceError.emptyAudio
        }

        try await ensureLoaded()

        guard let pipe = whisperKit else {
            throw WhisperServiceError.modelNotDownloaded
        }

        isTranscribing = true
        defer {
            isTranscribing = false
            if memoryWarningDuringActivity {
                memoryWarningDuringActivity = false
                Task { @MainActor [weak self] in
                    await self?.unload()
                }
            }
        }

        let paddedSamples = Self.prepareAudioSamplesForWhisper(samples)

        // Bias Whisper's decoder toward common gym exercises, set/rep phrasing, and weight units.
        // Leading space matches Whisper BPE prompt tokenization conventions; TextDecoder automatically
        // trims length and filters special tokens when `usePrefillPrompt` is true.
        let promptTokens: [Int]? = pipe.tokenizer.flatMap { tokenizer in
            let encoded = tokenizer.encode(text: " " + Self.gymBiasPrompt)
            return encoded.isEmpty ? nil : encoded
        }

        // Setting windowClipTime = 0.0 prevents WhisperKit's default 1.0s end-padding
        // from skipping single-window decoding on short gym commands (< 1.0s).
        // Explicit noSpeechThreshold = 0.6 suppresses hallucinations on breath/clank silence clips.
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: modelManager.selectedWhisperPreset.languageCode,
            temperature: 0.0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            windowClipTime: 0.0,
            promptTokens: promptTokens,
            noSpeechThreshold: 0.6
        )

        do {
            let results: [TranscriptionResult] = try await pipe.transcribe(
                audioArray: paddedSamples,
                decodeOptions: options
            )
            let combined = results.map(\.text).joined(separator: " ")
            return Self.cleanTranscript(combined)
        } catch {
            throw WhisperServiceError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Concise workout vocabulary prompt used to bias WhisperKit decoding toward exercise names
    /// and units. Intentionally excludes destructive commands (delete/finish workout) so prompt
    /// continuation hallucinations on noisy clips can never mutate or end an active session.
    public nonisolated static let gymBiasPrompt: String =
        "Gym workout log: leg extension, leg press, squat, Bulgarian split squat, leg curl, Romanian deadlift, hip thrust, calf raise, bench press, incline dumbbell press, cable fly, lat pulldown, barbell row, pull up, shoulder press, lateral raise, bicep curl, tricep pushdown, plank. 3 sets 15 reps, 60 kg, 135 lbs, warmup, drop set."

    /// Ensures ultra-short clips (0.15s–1.25s) have clean trailing silence so WhisperKit's
    /// mel spectrogram + single-window decoder never drops short spoken commands like "Undo".
    public nonisolated static func prepareAudioSamplesForWhisper(_ samples: [Float], minimumSamples: Int = 20_000) -> [Float] {
        guard samples.count < minimumSamples else { return samples }
        return samples + Array(repeating: Float(0), count: minimumSamples - samples.count)
    }

    public func unload() async {
        if let pipe = whisperKit {
            await pipe.unloadModels()
        }
        whisperKit = nil
        loadedFolderPath = nil
        loadedVariantRawValue = nil
        loadedVariantName = nil
        isLoaded = false
    }

    // MARK: - Transcript Sanitization

    private static func cleanTranscript(_ raw: String) -> String {
        var text = raw

        // Strip special Whisper tokens like <|startoftranscript|>, bracketed artifacts like [BLANK_AUDIO] / [MUSIC],
        // and non-numeric parenthetical sound tags like (music) or (sighs).
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

        // Collapse multiple spaces/newlines into single spaces.
        if let whitespaceRegex = try? NSRegularExpression(pattern: #"\s+"#, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = whitespaceRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
