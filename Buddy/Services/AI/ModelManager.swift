import FluidAudio
import Foundation
import Observation
import os
import UIKit

public enum ModelManagerError: LocalizedError, Sendable {
    case invalidDownloadURL
    case badHTTPStatus(Int)
    case invalidGGUFFile(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidDownloadURL:
            return "The selected model does not have a valid download URL."
        case .badHTTPStatus(let code):
            return "Model download failed with HTTP status \(code). Check your internet connection and try again."
        case .invalidGGUFFile(let reason):
            return reason
        case .cancelled:
            return "Download cancelled."
        }
    }
}

private final class LLMDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let expectedFallbackBytes: Double
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(
        destinationURL: URL,
        expectedFallbackBytes: Double,
        onProgress: @escaping @Sendable (Double) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.destinationURL = destinationURL
        self.expectedFallbackBytes = expectedFallbackBytes
        self.onProgress = onProgress
        self.continuation = continuation
    }

    private func resumeOnce(with result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        switch result {
        case .success(let url):
            pending?.resume(returning: url)
        case .failure(let error):
            pending?.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let denominator: Double
        if totalBytesExpectedToWrite > 0 {
            denominator = Double(totalBytesExpectedToWrite)
        } else if expectedFallbackBytes > 0 {
            denominator = expectedFallbackBytes
        } else {
            return
        }
        let fraction = min(0.99, max(0.0, Double(totalBytesWritten) / denominator))
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            resumeOnce(with: .failure(ModelManagerError.badHTTPStatus(httpResponse.statusCode)))
            return
        }

        do {
            try Self.validateGGUFFile(at: location)

            let fileManager = FileManager.default
            let parentDir = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let stagingURL = parentDir.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            try fileManager.moveItem(at: location, to: stagingURL)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }

            var targetURL = destinationURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? targetURL.setResourceValues(resourceValues)

            onProgress(1.0)
            resumeOnce(with: .success(destinationURL))
        } catch {
            resumeOnce(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            resumeOnce(with: .failure(ModelManagerError.cancelled))
        } else {
            resumeOnce(with: .failure(error))
        }
    }

    static func validateGGUFFile(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize >= 1_048_576 else {
            throw ModelManagerError.invalidGGUFFile("The file is too small to be a valid GGUF model.")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4) ?? Data()
        let expectedMagic = Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
        guard header == expectedMagic else {
            throw ModelManagerError.invalidGGUFFile("The file does not have a valid GGUF header.")
        }
    }
}

public typealias SpeechEngine = ModelManager.SpeechEngine
public typealias ParakeetPreset = ModelManager.ParakeetPreset
public typealias AppleSpeechLocaleOption = ModelManager.AppleSpeechLocaleOption
public typealias AppleSpeechRecognitionMode = ModelManager.AppleSpeechRecognitionMode
public typealias LLMPreset = ModelManager.LLMPreset

@Observable
@MainActor
public final class ModelManager {
    public enum SpeechEngine: String, CaseIterable, Identifiable, Codable, Sendable {
        case parakeet = "parakeet"
        case appleSpeech = "apple"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .parakeet: return "Parakeet (Local)"
            case .appleSpeech: return "Apple Speech"
            }
        }

        public var shortLabel: String {
            switch self {
            case .parakeet: return "Parakeet"
            case .appleSpeech: return "Apple"
            }
        }

        public var subtitle: String {
            switch self {
            case .parakeet:
                return "NVIDIA Parakeet TDT running 100% offline on Apple Neural Engine (~120 MB RAM, instant load, beats Whisper Large v3)."
            case .appleSpeech:
                return "Zero-download built-in iOS speech with live captions and cloud/offline fallback."
            }
        }
    }

    public enum ParakeetPreset: String, CaseIterable, Identifiable, Codable, Sendable {
        case v2 = "parakeet-tdt-0.6b-v2"
        case v3 = "parakeet-tdt-0.6b-v3"
        case compact110m = "parakeet-tdt-ctc-110m"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .v2: return "Parakeet TDT v2 (English)"
            case .v3: return "Parakeet TDT v3 (Multilingual)"
            case .compact110m: return "Parakeet Compact 110M"
            }
        }

        public var shortDisplayName: String {
            switch self {
            case .v2: return "Parakeet v2"
            case .v3: return "Parakeet v3"
            case .compact110m: return "Parakeet 110M"
            }
        }

        public var subtitle: String {
            switch self {
            case .v2:
                return "Highest English accuracy (2.1% WER) · ~110 MB RAM · ~4s setup"
            case .v3:
                return "English + 24 European languages (2.27% WER) · ~120 MB RAM"
            case .compact110m:
                return "Ultra-light 110M model · ~70 MB RAM · smallest download"
            }
        }

        public var approximateSizeMB: Int {
            switch self {
            case .v2: return 476
            case .v3: return 480
            case .compact110m: return 130
            }
        }

        var asrModelVersion: AsrModelVersion {
            switch self {
            case .v2: return .v2
            case .v3: return .v3
            case .compact110m: return .tdtCtc110m
            }
        }

        var expectedCompileComponentCount: Int {
            switch self {
            case .compact110m: return 3
            case .v2, .v3: return 4
            }
        }
    }

    public enum AppleSpeechRecognitionMode: String, CaseIterable, Identifiable, Codable, Sendable {
        case hybridAuto = "hybrid-auto"
        case offlineOnly = "offline-only"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .hybridAuto: return "Enhanced (Auto)"
            case .offlineOnly: return "Offline Only"
            }
        }

        public var shortLabel: String {
            switch self {
            case .hybridAuto: return "Enhanced"
            case .offlineOnly: return "On-Device"
            }
        }

        public var subtitle: String {
            switch self {
            case .hybridAuto:
                return "Uses Apple Cloud Speech in loud gyms with automatic offline fallback."
            case .offlineOnly:
                return "100% on-device Apple Speech. Audio never leaves your iPhone."
            }
        }
    }

    public enum AppleSpeechLocaleOption: String, CaseIterable, Identifiable, Codable, Sendable {
        case auto = "auto"
        case enIN = "en-IN"
        case enUS = "en-US"
        case enGB = "en-GB"
        case enAU = "en-AU"
        case enCA = "en-CA"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .auto: return "Auto (iPhone Region)"
            case .enIN: return "English (India)"
            case .enUS: return "English (US)"
            case .enGB: return "English (UK)"
            case .enAU: return "English (Australia)"
            case .enCA: return "English (Canada)"
            }
        }

        public var explicitLocale: Locale? {
            switch self {
            case .auto: return nil
            case .enIN, .enUS, .enGB, .enAU, .enCA:
                return Locale(identifier: rawValue)
            }
        }

        public var locale: Locale {
            explicitLocale ?? Locale.current
        }
    }

    public enum LLMPreset: String, CaseIterable, Identifiable, Codable, Sendable {
        case qwen25_1_5B = "qwen2.5-1.5b-instruct-q4_k_m"
        case qwen25_0_5B = "qwen2.5-0.5b-instruct-q4_k_m"
        case custom = "custom-gguf"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .qwen25_1_5B: return "Qwen 2.5 1.5B (Q4)"
            case .qwen25_0_5B: return "Qwen 2.5 0.5B (Q4)"
            case .custom: return "Custom GGUF"
            }
        }

        public var subtitle: String {
            switch self {
            case .qwen25_1_5B: return "Best accuracy for voice parsing & Coach"
            case .qwen25_0_5B: return "Ultra-light & fastest on 6 GB RAM"
            case .custom: return "Imported from Files app"
            }
        }

        public var approximateSizeMB: Int {
            switch self {
            case .qwen25_1_5B: return 1050
            case .qwen25_0_5B: return 490
            case .custom: return 0
            }
        }

        public var fileName: String {
            switch self {
            case .qwen25_1_5B: return "qwen2.5-1.5b-instruct-q4_k_m.gguf"
            case .qwen25_0_5B: return "qwen2.5-0.5b-instruct-q4_k_m.gguf"
            case .custom: return ""
            }
        }

        public var downloadURL: URL? {
            switch self {
            case .qwen25_1_5B:
                return URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")
            case .qwen25_0_5B:
                return URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf")
            case .custom:
                return nil
            }
        }
    }

    private enum DefaultsKey {
        static let selectedSpeechEngine = "buddy.models.speechEngine"
        static let selectedParakeetPreset = "buddy.models.selectedParakeetPreset"
        static let selectedAppleSpeechLocale = "buddy.models.appleSpeechLocale"
        static let selectedAppleSpeechMode = "buddy.models.appleSpeechMode"
        static let enableGymNoiseIsolation = "buddy.models.enableGymNoiseIsolation"
        static let preferBuiltInMic = "buddy.models.preferBuiltInMic"
        static let selectedLLMPreset = "buddy.models.selectedLLMPreset"
        static let customLLMFileName = "buddy.models.customLLMFileName"
    }

    public let modelsRootDirectory: URL
    public let parakeetBaseDirectory: URL
    public let llmBaseDirectory: URL

    @ObservationIgnored private var isInitializing: Bool = true

    public var selectedSpeechEngine: SpeechEngine = .appleSpeech {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedSpeechEngine.rawValue, forKey: DefaultsKey.selectedSpeechEngine)
        }
    }

    public var selectedParakeetPreset: ParakeetPreset = .v2 {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedParakeetPreset.rawValue, forKey: DefaultsKey.selectedParakeetPreset)
            refreshDownloadState()
        }
    }

    public var selectedAppleSpeechLocale: AppleSpeechLocaleOption = .auto {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedAppleSpeechLocale.rawValue, forKey: DefaultsKey.selectedAppleSpeechLocale)
        }
    }

    public var selectedAppleSpeechMode: AppleSpeechRecognitionMode = .hybridAuto {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedAppleSpeechMode.rawValue, forKey: DefaultsKey.selectedAppleSpeechMode)
        }
    }

    public var enableGymNoiseIsolation: Bool = true {
        didSet {
            guard !isInitializing else { return }
            defaults.set(enableGymNoiseIsolation, forKey: DefaultsKey.enableGymNoiseIsolation)
        }
    }

    public var preferBuiltInMic: Bool = true {
        didSet {
            guard !isInitializing else { return }
            defaults.set(preferBuiltInMic, forKey: DefaultsKey.preferBuiltInMic)
        }
    }

    public var audioCaptureOptions: AudioCaptureOptions {
        AudioCaptureOptions(
            enableVoiceIsolation: enableGymNoiseIsolation,
            preferBuiltInMic: preferBuiltInMic
        )
    }

    public var selectedLLMPreset: LLMPreset = .qwen25_1_5B {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedLLMPreset.rawValue, forKey: DefaultsKey.selectedLLMPreset)
            refreshDownloadState()
        }
    }

    public var customLLMFileName: String? = nil {
        didSet {
            guard !isInitializing else { return }
            if let customLLMFileName {
                defaults.set(customLLMFileName, forKey: DefaultsKey.customLLMFileName)
            } else {
                defaults.removeObject(forKey: DefaultsKey.customLLMFileName)
            }
            refreshDownloadState()
        }
    }

    public var parakeetDownloadProgress: Double = 0
    public var isDownloadingParakeet: Bool = false
    public var parakeetDownloadStatusText: String = ""
    public var isParakeetDownloaded: Bool = false
    public var activeParakeetFolderURL: URL?

    public var llmDownloadProgress: Double = 0
    public var isDownloadingLLM: Bool = false
    public var parakeetError: String?
    public var llmError: String?

    /// Combined error view for callers that display a single error banner.
    public var downloadError: String? {
        parakeetError ?? llmError
    }

    public var isLLMDownloaded: Bool = false
    public var activeLLMFileURL: URL?
    public var totalStorageUsedDescription: String = "0 MB"

    /// Uses Parakeet TDT whenever it is selected AND its CoreML weights + vocabulary are cached locally;
    /// otherwise falls back cleanly to Apple Speech so recording always works immediately.
    public var effectiveSpeechEngine: SpeechEngine {
        if selectedSpeechEngine == .parakeet && isParakeetDownloaded {
            return .parakeet
        }
        return .appleSpeech
    }

    public let deviceRAMGB: Double

    /// Real-time remaining iOS Jetsam memory budget in megabytes (`os_proc_available_memory()`).
    /// Returns `nil` when unavailable (e.g., on Simulator when reported as 0).
    public var availableMemoryMB: Int? {
        #if os(iOS) && !targetEnvironment(simulator)
        let bytes = os_proc_available_memory()
        guard bytes > 0 else { return nil }
        return Int(bytes / 1_048_576)
        #else
        return nil
        #endif
    }

    /// Selects a RAM-safe default Parakeet preset for first-time setup on SideStore builds.
    /// Parakeet TDT v2 uses only ~110 MB peak RAM (safe on all 4 GB+ iPhones).
    public nonisolated static func recommendedParakeetPreset(
        forPhysicalMemoryBytes bytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ParakeetPreset {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb < 3.5 {
            return .compact110m
        }
        return .v2
    }

    /// Returns `true` when either Parakeet or Apple Speech is ready AND the local LLM is downloaded.
    public func isAllReady(appleSpeechReady: Bool) -> Bool {
        let voiceReady = (effectiveSpeechEngine == .parakeet) || appleSpeechReady
        return voiceReady && isLLMDownloaded
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var activeParakeetDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var activeParakeetDownloadID: UUID?
    @ObservationIgnored private var parakeetCompiledComponents: Set<String> = []
    @ObservationIgnored private var parakeetBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var activeLLMDownloadSession: URLSession?
    @ObservationIgnored private var activeLLMDownloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var activeLLMDownloadID: UUID?

    public init(
        defaults: UserDefaults = .standard,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.defaults = defaults
        self.deviceRAMGB = Double(physicalMemoryBytes) / 1_073_741_824.0

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.modelsRootDirectory = appSupport.appendingPathComponent("BuddyModels", isDirectory: true)
        self.parakeetBaseDirectory = MLModelConfigurationUtils.defaultModelsDirectory(for: nil)
        self.llmBaseDirectory = modelsRootDirectory.appendingPathComponent("LLM", isDirectory: true)

        if let storedEngine = defaults.string(forKey: DefaultsKey.selectedSpeechEngine) {
            if let parsedEngine = SpeechEngine(rawValue: storedEngine) {
                self.selectedSpeechEngine = parsedEngine
            } else {
                // Migrate legacy `"whisperkit"` setting cleanly to `.appleSpeech` until Parakeet is downloaded.
                self.selectedSpeechEngine = .appleSpeech
                defaults.set(SpeechEngine.appleSpeech.rawValue, forKey: DefaultsKey.selectedSpeechEngine)
            }
        }

        if let storedParakeet = defaults.string(forKey: DefaultsKey.selectedParakeetPreset),
           let parsedParakeet = ParakeetPreset(rawValue: storedParakeet) {
            self.selectedParakeetPreset = parsedParakeet
        } else {
            self.selectedParakeetPreset = Self.recommendedParakeetPreset(forPhysicalMemoryBytes: physicalMemoryBytes)
        }

        if let storedLocale = defaults.string(forKey: DefaultsKey.selectedAppleSpeechLocale),
           let parsedLocale = AppleSpeechLocaleOption(rawValue: storedLocale) {
            self.selectedAppleSpeechLocale = parsedLocale
        }

        if let storedMode = defaults.string(forKey: DefaultsKey.selectedAppleSpeechMode),
           let parsedMode = AppleSpeechRecognitionMode(rawValue: storedMode) {
            self.selectedAppleSpeechMode = parsedMode
        }

        if defaults.object(forKey: DefaultsKey.enableGymNoiseIsolation) != nil {
            self.enableGymNoiseIsolation = defaults.bool(forKey: DefaultsKey.enableGymNoiseIsolation)
        }

        if defaults.object(forKey: DefaultsKey.preferBuiltInMic) != nil {
            self.preferBuiltInMic = defaults.bool(forKey: DefaultsKey.preferBuiltInMic)
        }

        if let storedLLM = defaults.string(forKey: DefaultsKey.selectedLLMPreset),
           let parsedLLM = LLMPreset(rawValue: storedLLM) {
            self.selectedLLMPreset = parsedLLM
        }

        self.customLLMFileName = defaults.string(forKey: DefaultsKey.customLLMFileName)
        self.isInitializing = false

        ensureModelDirectories()
        cleanupLegacyWhisperCacheIfPresent()
        refreshDownloadState()
    }

    public func isDownloaded(_ preset: ParakeetPreset) -> Bool {
        resolvedParakeetFolderURL(for: preset) != nil
    }

    public func isDownloaded(_ preset: LLMPreset) -> Bool {
        resolvedLLMFileURL(for: preset) != nil
    }

    /// Downloads the Parakeet TDT CoreML bundle + vocabulary and warms the ~4-second Neural Engine
    /// compilation in one lightweight step (~100–130 MB RAM, SideStore safe).
    public func downloadParakeetModel(
        _ preset: ParakeetPreset? = nil,
        onBeforeDownload: (@MainActor () async -> Void)? = nil
    ) async {
        guard !isDownloadingParakeet else { return }

        let targetPreset = preset ?? selectedParakeetPreset
        if selectedParakeetPreset != targetPreset {
            selectedParakeetPreset = targetPreset
        }

        ensureModelDirectories()
        let downloadID = UUID()
        activeParakeetDownloadID = downloadID
        parakeetCompiledComponents.removeAll()
        isDownloadingParakeet = true
        parakeetDownloadProgress = 0
        parakeetDownloadStatusText = "Preparing \(targetPreset.shortDisplayName)…"
        parakeetError = nil

        beginParakeetBackgroundTask(forDownloadID: downloadID)

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeParakeetDownloadID == downloadID {
                    self.isDownloadingParakeet = false
                    self.activeParakeetDownloadTask = nil
                    self.activeParakeetDownloadID = nil
                    self.parakeetCompiledComponents.removeAll()
                    self.endParakeetBackgroundTask()
                }
            }

            do {
                // Free any resident LLM before downloading/compiling so SideStore keeps maximum RAM headroom.
                await onBeforeDownload?()
                guard self.activeParakeetDownloadID == downloadID, !Task.isCancelled else {
                    throw CancellationError()
                }

                let version = targetPreset.asrModelVersion
                let downloadedDir = try await AsrModels.download(
                    to: nil,
                    force: false,
                    version: version,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.activeParakeetDownloadID == downloadID else { return }
                            self.applyParakeetDownloadProgress(progress, preset: targetPreset)
                        }
                    }
                )

                guard self.activeParakeetDownloadID == downloadID, !Task.isCancelled else {
                    throw CancellationError()
                }

                self.excludeFromBackup(self.parakeetBaseDirectory)
                self.excludeFromBackup(downloadedDir)
                self.parakeetDownloadProgress = 1.0
                self.parakeetDownloadStatusText = ""
                self.selectedSpeechEngine = .parakeet
                self.refreshDownloadState()
            } catch {
                guard self.activeParakeetDownloadID == downloadID else { return }
                if Self.isCancellationError(error) || Task.isCancelled {
                    self.parakeetDownloadProgress = 0
                    self.parakeetDownloadStatusText = ""
                    self.refreshDownloadState()
                } else {
                    self.parakeetError = "Parakeet download failed: \(error.localizedDescription)"
                    self.parakeetDownloadProgress = 0
                    self.parakeetDownloadStatusText = ""
                    self.refreshDownloadState()
                }
            }
        }

        activeParakeetDownloadTask = task
        await task.value
    }

    public func cancelParakeetDownload() {
        let taskToCancel = activeParakeetDownloadTask
        activeParakeetDownloadID = nil
        activeParakeetDownloadTask = nil
        parakeetCompiledComponents.removeAll()
        isDownloadingParakeet = false
        parakeetDownloadProgress = 0
        parakeetDownloadStatusText = ""
        taskToCancel?.cancel()
        endParakeetBackgroundTask()
        refreshDownloadState()
    }

    public func deleteParakeetModel(_ preset: ParakeetPreset? = nil) {
        let targetPreset = preset ?? selectedParakeetPreset
        let cacheDir = AsrModels.defaultCacheDirectory(for: targetPreset.asrModelVersion)
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            try? FileManager.default.removeItem(at: cacheDir)
        }
        parakeetDownloadProgress = 0
        parakeetDownloadStatusText = ""
        parakeetError = nil
        refreshDownloadState()
        if selectedSpeechEngine == .parakeet && !isParakeetDownloaded {
            selectedSpeechEngine = .appleSpeech
        }
    }

    public func downloadLLMModel(_ preset: LLMPreset? = nil) async {
        guard !isDownloadingLLM else { return }

        let targetPreset = preset ?? selectedLLMPreset
        guard targetPreset != .custom,
              let remoteURL = targetPreset.downloadURL,
              !targetPreset.fileName.isEmpty else {
            llmError = ModelManagerError.invalidDownloadURL.localizedDescription
            return
        }

        if selectedLLMPreset != targetPreset {
            selectedLLMPreset = targetPreset
        }

        ensureModelDirectories()
        let downloadID = UUID()
        activeLLMDownloadID = downloadID
        isDownloadingLLM = true
        llmDownloadProgress = 0
        llmError = nil

        let destinationURL = llmBaseDirectory.appendingPathComponent(targetPreset.fileName, isDirectory: false)
        let fallbackBytes = Double(targetPreset.approximateSizeMB) * 1_048_576.0

        defer {
            if activeLLMDownloadID == downloadID {
                isDownloadingLLM = false
                activeLLMDownloadTask = nil
                activeLLMDownloadSession?.finishTasksAndInvalidate()
                activeLLMDownloadSession = nil
                activeLLMDownloadID = nil
            }
        }

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let delegate = LLMDownloadDelegate(
                    destinationURL: destinationURL,
                    expectedFallbackBytes: fallbackBytes,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.activeLLMDownloadID == downloadID else { return }
                            self.llmDownloadProgress = fraction
                        }
                    },
                    continuation: continuation
                )
                let configuration = URLSessionConfiguration.default
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForResource = 60 * 60
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: remoteURL)

                self.activeLLMDownloadSession = session
                self.activeLLMDownloadTask = task
                task.resume()
            }

            guard activeLLMDownloadID == downloadID else { return }
            excludeFromBackup(destinationURL)
            llmDownloadProgress = 1.0
            refreshDownloadState()
        } catch ModelManagerError.cancelled {
            if activeLLMDownloadID == downloadID {
                llmDownloadProgress = 0
                refreshDownloadState()
            }
        } catch is CancellationError {
            if activeLLMDownloadID == downloadID {
                cancelLLMDownload()
            }
        } catch {
            if activeLLMDownloadID == downloadID {
                llmError = "LLM download failed: \(error.localizedDescription)"
                llmDownloadProgress = 0
                refreshDownloadState()
            }
        }
    }

    public func cancelLLMDownload() {
        let taskToCancel = activeLLMDownloadTask
        let sessionToCancel = activeLLMDownloadSession
        activeLLMDownloadID = nil
        activeLLMDownloadTask = nil
        activeLLMDownloadSession = nil
        isDownloadingLLM = false
        llmDownloadProgress = 0
        taskToCancel?.cancel()
        sessionToCancel?.invalidateAndCancel()
    }

    public func downloadRecommendedPack() async {
        llmError = nil
        if !isDownloaded(.qwen25_1_5B) {
            await downloadLLMModel(.qwen25_1_5B)
        } else if selectedLLMPreset != .qwen25_1_5B {
            selectedLLMPreset = .qwen25_1_5B
        }
        refreshDownloadState()
    }

    public func importCustomGGUF(from url: URL) throws {
        ensureModelDirectories()
        llmError = nil

        let didStartScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard url.pathExtension.lowercased() == "gguf" else {
            throw ModelManagerError.invalidGGUFFile("Please select a valid .gguf model file.")
        }

        try LLMDownloadDelegate.validateGGUFFile(at: url)

        let rawFileName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = rawFileName.isEmpty ? "custom-model.gguf" : rawFileName
        let customDir = customLLMDirectory
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: customDir.path) {
            try fileManager.createDirectory(at: customDir, withIntermediateDirectories: true)
            excludeFromBackup(customDir)
        }

        let destinationURL = customDir.appendingPathComponent(safeName, isDirectory: false)
        let stagingURL = customDir.appendingPathComponent(".\(safeName).import-\(UUID().uuidString)")

        if fileManager.fileExists(atPath: stagingURL.path) {
            try? fileManager.removeItem(at: stagingURL)
        }
        try fileManager.copyItem(at: url, to: stagingURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }

        excludeFromBackup(destinationURL)
        customLLMFileName = destinationURL.lastPathComponent
        selectedLLMPreset = .custom
        refreshDownloadState()
    }

    public func deleteLLMModel(_ preset: LLMPreset? = nil) {
        let targetPreset = preset ?? selectedLLMPreset
        if let fileURL = resolvedLLMFileURL(for: targetPreset) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if targetPreset == .custom {
            customLLMFileName = nil
        }
        llmDownloadProgress = 0
        llmError = nil
        refreshDownloadState()
    }

    public func refreshDownloadState() {
        let parakeetFolder = resolvedParakeetFolderURL(for: selectedParakeetPreset)
        activeParakeetFolderURL = parakeetFolder
        isParakeetDownloaded = (parakeetFolder != nil)

        let llmFile = resolvedLLMFileURL(for: selectedLLMPreset)
        activeLLMFileURL = llmFile
        isLLMDownloaded = (llmFile != nil)

        totalStorageUsedDescription = Self.formattedTotalStorageUsed(
            directories: [modelsRootDirectory, parakeetBaseDirectory]
        )
    }

    public func resolvedParakeetFolderURL(for preset: ParakeetPreset) -> URL? {
        let version = preset.asrModelVersion
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        guard AsrModels.modelsExist(at: cacheDir, version: version) else {
            return nil
        }
        return cacheDir
    }

    // MARK: - Private Filesystem & Persistence Helpers

    private var customLLMDirectory: URL {
        llmBaseDirectory.appendingPathComponent("Custom", isDirectory: true)
    }

    private func applyParakeetDownloadProgress(_ progress: DownloadProgress, preset: ParakeetPreset) {
        let totalSpecs = max(1, preset.expectedCompileComponentCount)
        let slice = 0.94 / Double(totalSpecs)

        switch progress.phase {
        case .listing:
            let completedSpecs = min(parakeetCompiledComponents.count, totalSpecs - 1)
            let mapped = 0.02 + Double(completedSpecs) * slice
            parakeetDownloadProgress = max(parakeetDownloadProgress, min(0.98, mapped))
            parakeetDownloadStatusText = "Checking \(preset.shortDisplayName) (\(completedSpecs + 1)/\(totalSpecs))…"

        case .downloading(let completedFiles, let totalFiles):
            let completedSpecs = min(parakeetCompiledComponents.count, totalSpecs - 1)
            let subFraction = min(max(progress.fractionCompleted, 0), 1) * 0.85
            let mapped = 0.02 + (Double(completedSpecs) + subFraction) * slice
            parakeetDownloadProgress = max(parakeetDownloadProgress, min(0.98, mapped))
            if totalFiles > 0 {
                parakeetDownloadStatusText = "Downloading \(preset.shortDisplayName) (\(completedSpecs + 1)/\(totalSpecs) · \(min(completedFiles, totalFiles))/\(totalFiles))…"
            } else {
                parakeetDownloadStatusText = "Downloading \(preset.shortDisplayName) (\(completedSpecs + 1)/\(totalSpecs))…"
            }

        case .compiling(let modelName):
            let cleanName = modelName.replacingOccurrences(of: ".mlmodelc", with: "")
            parakeetCompiledComponents.insert(cleanName)
            let compiledCount = min(parakeetCompiledComponents.count, totalSpecs)
            let mapped = 0.02 + Double(compiledCount) * slice
            parakeetDownloadProgress = max(parakeetDownloadProgress, min(0.98, mapped))
            parakeetDownloadStatusText = "Warming Neural Engine (\(cleanName) · \(compiledCount)/\(totalSpecs))…"
        }
    }

    private func beginParakeetBackgroundTask(forDownloadID downloadID: UUID) {
        endParakeetBackgroundTask()
        parakeetBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "BuddyParakeetDownload") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeParakeetDownloadID == downloadID else { return }
                self.endParakeetBackgroundTask()
            }
        }
    }

    private func endParakeetBackgroundTask() {
        let taskID = parakeetBackgroundTaskID
        guard taskID != .invalid else { return }
        parakeetBackgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func ensureModelDirectories() {
        let fileManager = FileManager.default
        for directory in [modelsRootDirectory, parakeetBaseDirectory, llmBaseDirectory, customLLMDirectory] {
            if !fileManager.fileExists(atPath: directory.path) {
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            excludeFromBackup(directory)
        }
    }

    /// Reclaims disk space (~626 MB) left behind by earlier WhisperKit builds when upgrading to Parakeet.
    private func cleanupLegacyWhisperCacheIfPresent() {
        let legacyWhisperDir = modelsRootDirectory.appendingPathComponent("Whisper", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyWhisperDir.path) {
            try? FileManager.default.removeItem(at: legacyWhisperDir)
        }
        for legacyKey in [
            "buddy.models.selectedWhisperPreset",
            "buddy.models.whisperRelativePaths",
            "buddy.models.prewarmedWhisperPresets",
            "buddy.models.prewarmOSBuild"
        ] {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private func resolvedLLMFileURL(for preset: LLMPreset) -> URL? {
        let candidate: URL
        switch preset {
        case .qwen25_1_5B, .qwen25_0_5B:
            candidate = llmBaseDirectory.appendingPathComponent(preset.fileName, isDirectory: false)
        case .custom:
            guard let customLLMFileName, !customLLMFileName.isEmpty else { return nil }
            let isolated = customLLMDirectory.appendingPathComponent(customLLMFileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: isolated.path) {
                candidate = isolated
            } else {
                candidate = llmBaseDirectory.appendingPathComponent(customLLMFileName, isDirectory: false)
            }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return nil
        }
        return candidate
    }

    private static func formattedTotalStorageUsed(directories: [URL]) -> String {
        let fileManager = FileManager.default
        var seenPaths: Set<String> = []
        var totalBytes: Int64 = 0

        for directory in directories {
            let standardized = directory.standardizedFileURL.path
            guard seenPaths.insert(standardized).inserted,
                  fileManager.fileExists(atPath: standardized),
                  let enumerator = fileManager.enumerator(
                      at: directory,
                      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                      options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize else {
                    continue
                }
                totalBytes += Int64(size)
            }
        }

        if totalBytes == 0 {
            return "0 MB"
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
    }
}
