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
    @ObservationIgnored private var isTranscribing: Bool = false
    @ObservationIgnored private var inFlightLoadTask: Task<Void, Error>?
    @ObservationIgnored private var memoryWarningObserver: WhisperMemoryObserverToken?

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.memoryWarningObserver = WhisperMemoryObserverToken { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isTranscribing, !self.isLoading else { return }
                await self.unload()
            }
        }
    }

    public func ensureLoaded() async throws {
        guard let folder = modelManager.activeWhisperFolderURL else {
            throw WhisperServiceError.modelNotDownloaded
        }

        let desiredVariant = modelManager.selectedWhisperPreset.rawValue
        let desiredPath = folder.path

        if whisperKit != nil,
           isLoaded,
           loadedFolderPath == desiredPath,
           loadedVariantName == desiredVariant {
            return
        }

        if let existingTask = inFlightLoadTask {
            try await existingTask.value
            if whisperKit != nil,
               isLoaded,
               loadedFolderPath == desiredPath,
               loadedVariantName == desiredVariant {
                return
            }
        }

        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }
            if self.whisperKit != nil {
                await self.unload()
            }

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
            self.whisperKit = pipe
            self.loadedFolderPath = desiredPath
            self.loadedVariantName = desiredVariant
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
        defer { isTranscribing = false }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: modelManager.selectedWhisperPreset.languageCode,
            temperature: 0.0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false
        )

        do {
            let results: [TranscriptionResult] = try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            let combined = results.map(\.text).joined(separator: " ")
            return Self.cleanTranscript(combined)
        } catch {
            throw WhisperServiceError.transcriptionFailed(error.localizedDescription)
        }
    }

    public func unload() async {
        if let pipe = whisperKit {
            await pipe.unloadModels()
        }
        whisperKit = nil
        loadedFolderPath = nil
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
