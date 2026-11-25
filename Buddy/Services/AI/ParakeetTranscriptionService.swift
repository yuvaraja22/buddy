import CoreML
import FluidAudio
import Foundation
import Observation
import UIKit

public enum ParakeetServiceError: LocalizedError, Sendable {
    case modelNotDownloaded
    case emptyAudio
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "Download a Parakeet model in Settings → Voice & Local AI first, or switch to Apple Speech."
        case .emptyAudio:
            return "No speech detected. Hold or tap a bit longer while speaking your set."
        case .transcriptionFailed(let detail):
            return "Parakeet transcription failed: \(detail)"
        }
    }
}

private final class ParakeetMemoryObserverToken: @unchecked Sendable {
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

/// Ultra-lightweight on-device NVIDIA Parakeet TDT (CoreML + Apple Neural Engine) speech service.
///
/// Built for SideStore free Apple IDs (zero paid entitlements, no `increased-memory-limit`):
/// - Runs Parakeet TDT v2/v3 or Compact 110M in ~100–130 MB RAM (vs ~2+ GB for Whisper Large v3),
///   avoiding iOS Jetsam kills on 4 GB, 6 GB, and 8 GB iPhones.
/// - Warm-loads in ~180 ms via 100% offline `AsrModels.loadLocal(from:version:configuration:)` with
///   zero network calls or slow separate "Optimize" step.
/// - Serializes residency handoffs with `LocalLLMService` via `ModelMemoryCoordinator`, pins
///   `parallelChunkConcurrency = 1` for long 3-minute workout recaps, filters dead silence before
///   waking CoreML, and releases cleanly under iOS memory pressure or app backgrounding.
@Observable
@MainActor
public final class ParakeetTranscriptionService {
    public var isLoaded: Bool = false
    public var isLoading: Bool = false
    public var isTranscribing: Bool = false
    public var loadedModelName: String?
    public var lastMemoryNotice: String?

    /// Shared residency coordinator ensuring Parakeet CoreML and Qwen GGUF never overlap in RAM.
    @ObservationIgnored public var memoryCoordinator: ModelMemoryCoordinator?
    /// Invoked inside `memoryCoordinator` to cancel & await complete teardown of `LocalLLMService`.
    @ObservationIgnored public var onUnloadOpposingModel: (@MainActor () async -> Void)?

    private let modelManager: ModelManager
    @ObservationIgnored private var asrManager: AsrManager?
    @ObservationIgnored private var loadedVersion: AsrModelVersion?
    @ObservationIgnored private var loadedFolderPath: String?
    @ObservationIgnored private var loadedPresetRawValue: String?
    @ObservationIgnored private var activeLoadTask: Task<Void, Error>?
    @ObservationIgnored private var cancelActiveCoreMLSubtask: (() -> Void)?
    @ObservationIgnored private var isRunningCoreMLWork: Bool = false
    @ObservationIgnored private var coreMLIdleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var memoryWarningDuringActivity: Bool = false
    @ObservationIgnored private var pendingUnload: Bool = false
    @ObservationIgnored private var memoryWarningObserver: ParakeetMemoryObserverToken?

    public init(modelManager: ModelManager) {
        self.modelManager = modelManager
        self.memoryWarningObserver = ParakeetMemoryObserverToken { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTranscribing || self.isLoading || self.isRunningCoreMLWork {
                    self.memoryWarningDuringActivity = true
                } else if self.asrManager != nil {
                    await self.releaseLoadedParakeet()
                    self.lastMemoryNotice = "Released Parakeet memory under iOS pressure; reloads in ~0.2s on next mic tap."
                }
            }
        }
    }

    /// Loads the active downloaded Parakeet TDT CoreML model completely offline (`loadLocal`).
    public func ensureLoaded() async throws {
        guard let folder = modelManager.activeParakeetFolderURL else {
            throw ParakeetServiceError.modelNotDownloaded
        }

        let desiredPreset = modelManager.selectedParakeetPreset
        let desiredVariant = desiredPreset.rawValue
        let desiredPath = folder.path
        let desiredVersion = desiredPreset.asrModelVersion

        if asrManager != nil,
           isLoaded,
           loadedFolderPath == desiredPath,
           loadedPresetRawValue == desiredVariant {
            return
        }

        if let existingTask = activeLoadTask {
            try await withTaskCancellationHandler {
                try await existingTask.value
            } onCancel: {
                existingTask.cancel()
            }
            if asrManager != nil,
               isLoaded,
               loadedFolderPath == desiredPath,
               loadedPresetRawValue == desiredVariant {
                return
            }
        }

        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }

            try await self.runCoordinatedSpeechTransition {
                try Task.checkCancellation()

                if self.asrManager != nil {
                    await self.releaseLoadedParakeet()
                }

                self.memoryWarningDuringActivity = false
                self.pendingUnload = false
                self.lastMemoryNotice = nil
                self.isLoading = true
                defer { self.isLoading = false }

                let loadedManager: AsrManager = try await self.executeCoreMLSubtask {
                    let mlConfig = Self.makeMLConfiguration()
                    let models = try AsrModels.loadLocal(
                        from: folder,
                        version: desiredVersion,
                        configuration: mlConfig
                    )
                    let asrConfig = ASRConfig(parallelChunkConcurrency: 1)
                    return AsrManager(config: asrConfig, models: models)
                }

                if Task.isCancelled || self.pendingUnload || self.memoryWarningDuringActivity {
                    let wasMemoryWarning = self.memoryWarningDuringActivity
                    self.memoryWarningDuringActivity = false
                    self.pendingUnload = false
                    await loadedManager.cleanup()
                    self.memoryCoordinator?.markUnloaded(.localSpeech)
                    if wasMemoryWarning {
                        throw ParakeetServiceError.transcriptionFailed(
                            "Released Parakeet due to low iPhone memory. Try again or switch to Parakeet Compact 110M in Settings."
                        )
                    }
                    throw CancellationError()
                }

                self.asrManager = loadedManager
                self.loadedVersion = desiredVersion
                self.loadedFolderPath = desiredPath
                self.loadedPresetRawValue = desiredVariant
                self.loadedModelName = desiredPreset.displayName
                self.isLoaded = true
            }
        }

        activeLoadTask = task
        defer {
            if activeLoadTask == task {
                activeLoadTask = nil
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Transcribes 16 kHz mono Float32 samples completely offline on Apple Neural Engine.
    public func transcribe(samples: [Float]) async throws -> String {
        guard samples.count >= 1_600 else {
            throw ParakeetServiceError.emptyAudio
        }

        // Skip silent or accidental muted taps BEFORE evicting Qwen or waking CoreML.
        guard Self.hasAudibleSpeech(in: samples) else {
            throw ParakeetServiceError.emptyAudio
        }

        try await ensureLoaded()

        guard let manager = asrManager, let version = loadedVersion else {
            throw ParakeetServiceError.modelNotDownloaded
        }

        isTranscribing = true
        defer {
            isTranscribing = false
            if memoryWarningDuringActivity || pendingUnload {
                let wasMemoryWarning = memoryWarningDuringActivity
                memoryWarningDuringActivity = false
                pendingUnload = false
                Task { @MainActor [weak self] in
                    await self?.releaseLoadedParakeet()
                    if wasMemoryWarning {
                        self?.lastMemoryNotice = "Released Parakeet memory under iOS pressure; reloads in ~0.2s on next mic tap."
                    }
                }
            }
        }

        let paddedSamples = Self.prepareAudioSamplesForParakeet(samples)
        let decoderLayers = version.decoderLayers

        do {
            let rawText: String = try await executeCoreMLSubtask {
                var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
                let result = try await manager.transcribe(paddedSamples, decoderState: &decoderState)
                return result.text
            }
            return Self.cleanTranscript(rawText)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ParakeetServiceError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Cancels any in-flight CoreML load or transcription subtask cleanly.
    public func cancelInFlightWork() {
        activeLoadTask?.cancel()
        cancelActiveCoreMLSubtask?()
    }

    /// Cancels in-flight work, awaits active CoreML subtasks to exit, and frees all Parakeet
    /// CoreML models so `LocalLLMService` gets maximum SideStore RAM headroom.
    public func unloadAndWait() async {
        pendingUnload = true
        activeLoadTask?.cancel()
        cancelActiveCoreMLSubtask?()

        if isRunningCoreMLWork {
            await withCheckedContinuation { continuation in
                coreMLIdleWaiters.append(continuation)
            }
        }

        await releaseLoadedParakeet()
        pendingUnload = false
        lastMemoryNotice = nil
    }

    public func unload() async {
        await unloadAndWait()
    }

    /// Unloads Parakeet cleanly when entering background so iOS Jetsam never terminates Buddy
    /// while switching music or apps between gym sets.
    public func unloadIfIdle() async {
        if isTranscribing || isLoading || isRunningCoreMLWork {
            pendingUnload = true
            return
        }
        await releaseLoadedParakeet()
    }

    // MARK: - Internal Coordination Helpers

    private func runCoordinatedSpeechTransition<T>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        if let coordinator = memoryCoordinator {
            return try await coordinator.runExclusiveLoad(
                for: .localSpeech,
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

    private func releaseLoadedParakeet() async {
        if let manager = asrManager {
            await manager.cleanup()
        }
        asrManager = nil
        loadedVersion = nil
        loadedFolderPath = nil
        loadedPresetRawValue = nil
        loadedModelName = nil
        isLoaded = false
        memoryCoordinator?.markUnloaded(.localSpeech)
    }

    // MARK: - Compute, Silence & Audio Helpers

    private nonisolated static func makeMLConfiguration() -> MLModelConfiguration {
        let config = MLModelConfiguration()
        config.allowLowPrecisionAccumulationOnGPU = true
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        // Parakeet TDT's preprocessor automatically runs on CPU while encoder/decoder/joint run
        // on Apple Neural Engine (~100-130 MB RAM, zero GPU dispatch, background-safe on iOS).
        config.computeUnits = .cpuAndNeuralEngine
        #endif
        return config
    }

    /// Fast pre-CoreML silence filter so muted or accidental dead-air taps never evict Qwen or
    /// wake the Neural Engine unnecessarily.
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

    /// Pads very short clips (0.15s–0.5s) with clean trailing silence so Parakeet always receives
    /// at least 0.5s (`8_000` samples at 16 kHz, safely above FluidAudio's 0.3s minimum).
    public nonisolated static func prepareAudioSamplesForParakeet(
        _ samples: [Float],
        minimumSamples: Int = 8_000
    ) -> [Float] {
        guard samples.count < minimumSamples else { return samples }
        return samples + Array(repeating: Float(0), count: minimumSamples - samples.count)
    }

    /// Sanitizes any stray special tokens (`<unk>`, `<|...|>`, `[BLANK_AUDIO]`) and collapses whitespace.
    public nonisolated static func cleanTranscript(_ raw: String) -> String {
        var text = raw

        let artifactPatterns = [
            #"<unk>"#,
            #"<\|[^|]*\|>"#,
            #"\[[^\]]*\]"#
        ]

        for pattern in artifactPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
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
