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
/// - Always unloads `LocalLLMService` (Qwen) via `onBeforeLoadModel` before loading CoreML weights.
/// - Runs CoreML model compilation/loading off `@MainActor` to prevent main-thread watchdog kills.
/// - Runs one-time sequential ANE prewarming (`prewarm: true, load: false`) separately from live
///   loading so CoreML never holds compiled submodels and compiler scratch RAM simultaneously.
/// - Uses `.cpuOnly` for MelSpectrogram to avoid Metal GPU memory spikes alongside ANE.
/// - Pins `concurrentWorkerCount = 1` so long workout recaps never multiply CoreML decoder buffers.
@Observable
@MainActor
public final class WhisperTranscriptionService {
    public var isLoaded: Bool = false
    public var isLoading: Bool = false
    public var isPrewarming: Bool = false
    public var isTranscribing: Bool = false
    public var loadedVariantName: String?
    public var lastMemoryNotice: String?

    /// Invoked right before loading Whisper CoreML models so Buddy can release Qwen LLM RAM first.
    @ObservationIgnored public var onBeforeLoadModel: (@MainActor () async -> Void)?

    private let modelManager: ModelManager
    @ObservationIgnored private var whisperKit: WhisperKit?
    @ObservationIgnored private var loadedFolderPath: String?
    @ObservationIgnored private var loadedVariantRawValue: String?
    @ObservationIgnored private var inFlightLoadTask: Task<Void, Error>?
    @ObservationIgnored private var memoryWarningDuringActivity: Bool = false
    @ObservationIgnored private var pendingBackgroundUnload: Bool = false
    @ObservationIgnored private var memoryWarningObserver: WhisperMemoryObserverToken?

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.memoryWarningObserver = WhisperMemoryObserverToken { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTranscribing || self.isLoading || self.isPrewarming {
                    self.memoryWarningDuringActivity = true
                } else if self.whisperKit != nil {
                    await self.unload()
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

        if whisperKit != nil {
            await unload()
        }
        await onBeforeLoadModel?()

        memoryWarningDuringActivity = false
        isPrewarming = true
        defer { isPrewarming = false }

        let folderPath = folder.path
        let tokenizerFolder = modelManager.whisperBaseDirectory
        let computeOptions = Self.makeComputeOptions()

        try await Task.detached(priority: .userInitiated) {
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
        }.value

        if memoryWarningDuringActivity {
            memoryWarningDuringActivity = false
            lastMemoryNotice = "Paused Neural Engine prewarm due to low memory; Whisper will optimize on next use."
            return
        }

        modelManager.markPrewarmed(preset)
        // Give CoreML's ANE compiler daemon a brief pause to release scratch memory.
        try? await Task.sleep(for: .milliseconds(250))
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

            // Guarantee Qwen LLM is completely released before loading Whisper Large CoreML weights.
            await self.onBeforeLoadModel?()

            self.memoryWarningDuringActivity = false
            self.pendingBackgroundUnload = false
            self.lastMemoryNotice = nil

            let tokenizerFolder = self.modelManager.whisperBaseDirectory
            let computeOptions = Self.makeComputeOptions()

            // Step 1: If this iOS build hasn't specialized the ANE graph yet, prewarm submodels
            // ONE AT A TIME (`prewarm: true, load: false`) so compiler memory never stacks.
            if !self.modelManager.isPrewarmed(desiredPreset) {
                self.isPrewarming = true
                defer { self.isPrewarming = false }

                try await Task.detached(priority: .userInitiated) {
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
                }.value

                if self.memoryWarningDuringActivity || Task.isCancelled {
                    self.memoryWarningDuringActivity = false
                    if Task.isCancelled { throw CancellationError() }
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

            let loadedBox: WhisperKitSendableBox = try await Task.detached(priority: .userInitiated) {
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
            }.value

            if self.memoryWarningDuringActivity || Task.isCancelled {
                await loadedBox.value.unloadModels()
                self.memoryWarningDuringActivity = false
                if Task.isCancelled { throw CancellationError() }
                throw WhisperServiceError.transcriptionFailed(
                    "Released Whisper due to low iPhone memory. Close background apps or switch to Whisper Large Compact / Small in Settings."
                )
            }

            self.whisperKit = loadedBox.value
            self.loadedFolderPath = desiredPath
            self.loadedVariantRawValue = desiredVariant
            self.loadedVariantName = desiredPreset.displayName
            self.isLoaded = true
        }

        inFlightLoadTask = task
        defer { inFlightLoadTask = nil }
        try await task.value
    }

    public func transcribe(
        samples: [Float],
        recentExercises: [String] = []
    ) async throws -> String {
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
            if memoryWarningDuringActivity || pendingBackgroundUnload {
                let wasMemoryWarning = memoryWarningDuringActivity
                memoryWarningDuringActivity = false
                pendingBackgroundUnload = false
                Task { @MainActor [weak self] in
                    await self?.unload()
                    if wasMemoryWarning {
                        self?.lastMemoryNotice = "Released Whisper memory after logging; reloads automatically next time."
                    }
                }
            }
        }

        let paddedSamples = Self.prepareAudioSamplesForWhisper(samples)
        let biasPrompt = Self.buildGymBiasPrompt(recentExercises: recentExercises)
        let languageCode = modelManager.selectedWhisperPreset.languageCode

        // Encode the gym vocabulary conditioning prompt with a leading space per Whisper BPE conventions.
        let promptTokens: [Int]? = pipe.tokenizer.flatMap { tokenizer in
            let encoded = tokenizer.encode(text: " " + biasPrompt)
            return encoded.isEmpty ? nil : encoded
        }

        // Single-worker sequential decoding (`concurrentWorkerCount: 1`) prevents CoreML memory
        // multiplication on long 1–3 minute workout recaps.
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode,
            temperature: 0.0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            windowClipTime: 0.0,
            promptTokens: promptTokens,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1
        )

        let pipeBox = WhisperKitSendableBox(value: pipe)
        do {
            let combined: String = try await Task.detached(priority: .userInitiated) {
                let results: [TranscriptionResult] = try await pipeBox.value.transcribe(
                    audioArray: paddedSamples,
                    decodeOptions: options
                )
                return results.map(\.text).joined(separator: " ")
            }.value
            return Self.cleanTranscript(combined)
        } catch is CancellationError {
            throw CancellationError()
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
        loadedVariantRawValue = nil
        loadedVariantName = nil
        isLoaded = false
    }

    /// Unloads Whisper cleanly when entering the background so iOS Jetsam never terminates Buddy
    /// while switching music or apps between gym sets.
    public func unloadIfIdle() async {
        if isTranscribing || isLoading || isPrewarming {
            pendingBackgroundUnload = true
            return
        }
        await unload()
    }

    // MARK: - Compute & Gym Prompt Helpers

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

    /// Builds a concise workout vocabulary prompt prioritizing the active session's exercises
    /// followed by high-frequency gym lifts and weight/rep units. Intentionally excludes destructive
    /// verbs ("delete", "remove", "finish", "end") so prompt continuation hallucinations on noisy
    /// clips can never mutate or end an active workout session.
    public nonisolated static func buildGymBiasPrompt(recentExercises: [String] = []) -> String {
        var prioritized: [String] = []
        var seen: Set<String> = []

        for exercise in recentExercises {
            let trimmed = exercise.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                prioritized.append(trimmed)
            }
            if prioritized.count >= 6 { break }
        }

        let coreLifts = [
            "bench press",
            "incline dumbbell press",
            "cable fly",
            "lat pulldown",
            "barbell row",
            "seated cable row",
            "pull up",
            "squat",
            "hack squat",
            "leg press",
            "leg extension",
            "leg curl",
            "Romanian deadlift",
            "RDL",
            "Bulgarian split squat",
            "hip thrust",
            "calf raise",
            "shoulder press",
            "lateral raise",
            "face pull",
            "bicep curl",
            "hammer curl",
            "tricep pushdown",
            "plank"
        ]

        for lift in coreLifts {
            let key = lift.lowercased()
            if seen.insert(key).inserted {
                prioritized.append(lift)
            }
        }

        return "Gym workout log: \(prioritized.joined(separator: ", ")). 3 sets 12 reps, 60 kg, 135 lbs, warmup, drop set."
    }

    /// Ensures ultra-short clips (0.15s–1.25s) have clean trailing silence so WhisperKit's
    /// mel spectrogram + single-window decoder never drops short spoken commands like "Undo".
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
