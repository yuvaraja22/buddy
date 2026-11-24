import Foundation
import Observation
import UIKit
import WhisperKit

public enum ModelManagerError: LocalizedError, Sendable {
    case invalidDownloadURL
    case badHTTPStatus(Int)
    case invalidGGUFFile(String)
    case whisperTokenizerMissing(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidDownloadURL:
            return "The selected model does not have a valid download URL."
        case .badHTTPStatus(let code):
            return "Model download failed with HTTP status \(code). Check your internet connection and try again."
        case .invalidGGUFFile(let reason):
            return reason
        case .whisperTokenizerMissing(let reason):
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
public typealias WhisperPreset = ModelManager.WhisperPreset
public typealias AppleSpeechLocaleOption = ModelManager.AppleSpeechLocaleOption
public typealias AppleSpeechRecognitionMode = ModelManager.AppleSpeechRecognitionMode
public typealias LLMPreset = ModelManager.LLMPreset

@Observable
@MainActor
public final class ModelManager {
    public enum SpeechEngine: String, CaseIterable, Identifiable, Codable, Sendable {
        case whisperKit = "whisperkit"
        case appleSpeech = "apple"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .whisperKit: return "WhisperKit (Local)"
            case .appleSpeech: return "Apple Speech"
            }
        }

        public var shortLabel: String {
            switch self {
            case .whisperKit: return "Whisper"
            case .appleSpeech: return "Apple"
            }
        }

        public var subtitle: String {
            switch self {
            case .whisperKit:
                return "OpenAI Whisper running 100% offline on Apple Neural Engine with gym vocabulary prompting."
            case .appleSpeech:
                return "Zero-download built-in iOS speech with live captions and cloud/offline fallback."
            }
        }
    }

    public enum WhisperPreset: String, CaseIterable, Identifiable, Codable, Sendable {
        case largeV3Turbo = "openai_whisper-large-v3-v20240930_626MB"
        case largeV3TurboCompact = "openai_whisper-large-v3-v20240930_547MB"
        case smallEn = "openai_whisper-small.en_217MB"

        public var id: String { rawValue }

        public var variantGlob: String {
            switch self {
            case .largeV3Turbo: return "large-v3-v20240930_626MB"
            case .largeV3TurboCompact: return "large-v3-v20240930_547MB"
            case .smallEn: return "small.en_217MB"
            }
        }

        public var displayName: String {
            switch self {
            case .largeV3Turbo: return "Whisper Large v3 Turbo"
            case .largeV3TurboCompact: return "Whisper Large v3 Compact"
            case .smallEn: return "Whisper Small (English)"
            }
        }

        public var shortDisplayName: String {
            switch self {
            case .largeV3Turbo: return "Whisper Large v3"
            case .largeV3TurboCompact: return "Whisper Large 547MB"
            case .smallEn: return "Whisper Small"
            }
        }

        public var subtitle: String {
            switch self {
            case .largeV3Turbo:
                return "Best accuracy for loud gyms & global accents (8 GB+ iPhone recommended)"
            case .largeV3TurboCompact:
                return "Same Large v3 Turbo accuracy with ~80 MB lighter RAM (great for 6 GB iPhones)"
            case .smallEn:
                return "Fastest load & ultra-low RAM (recommended on 4 GB / older iPhones)"
            }
        }

        public var approximateSizeMB: Int {
            switch self {
            case .largeV3Turbo: return 626
            case .largeV3TurboCompact: return 547
            case .smallEn: return 217
            }
        }

        public var isLargeModel: Bool {
            switch self {
            case .largeV3Turbo, .largeV3TurboCompact: return true
            case .smallEn: return false
            }
        }

        public var languageCode: String? {
            "en"
        }

        var whisperModelVariant: ModelVariant {
            switch self {
            case .largeV3Turbo, .largeV3TurboCompact: return .largev3
            case .smallEn: return .smallEn
            }
        }

        public var tokenizerRepoName: String {
            switch self {
            case .largeV3Turbo, .largeV3TurboCompact: return "openai/whisper-large-v3"
            case .smallEn: return "openai/whisper-small.en"
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
        static let selectedWhisperPreset = "buddy.models.selectedWhisperPreset"
        static let whisperRelativePaths = "buddy.models.whisperRelativePaths"
        static let prewarmedWhisperVariants = "buddy.models.prewarmedWhisperVariants"
        static let selectedAppleSpeechLocale = "buddy.models.appleSpeechLocale"
        static let selectedAppleSpeechMode = "buddy.models.appleSpeechMode"
        static let enableGymNoiseIsolation = "buddy.models.enableGymNoiseIsolation"
        static let preferBuiltInMic = "buddy.models.preferBuiltInMic"
        static let selectedLLMPreset = "buddy.models.selectedLLMPreset"
        static let customLLMFileName = "buddy.models.customLLMFileName"
    }

    public let modelsRootDirectory: URL
    public let whisperBaseDirectory: URL
    public let llmBaseDirectory: URL

    @ObservationIgnored private var isInitializing: Bool = true

    public var selectedSpeechEngine: SpeechEngine = .appleSpeech {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedSpeechEngine.rawValue, forKey: DefaultsKey.selectedSpeechEngine)
        }
    }

    public var selectedWhisperPreset: WhisperPreset = .largeV3Turbo {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedWhisperPreset.rawValue, forKey: DefaultsKey.selectedWhisperPreset)
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

    public var whisperDownloadProgress: Double = 0
    public var isDownloadingWhisper: Bool = false
    public var isOptimizingWhisper: Bool = false
    public var whisperDownloadStatusText: String = ""
    public var isWhisperDownloaded: Bool = false
    public var activeWhisperFolderURL: URL?

    public var llmDownloadProgress: Double = 0
    public var isDownloadingLLM: Bool = false
    public var whisperError: String?
    public var llmError: String?

    /// Combined error view for callers that display a single error banner.
    public var downloadError: String? {
        whisperError ?? llmError
    }

    public var isLLMDownloaded: Bool = false
    public var activeLLMFileURL: URL?
    public var totalStorageUsedDescription: String = "0 MB"

    /// Uses WhisperKit whenever it is selected AND its weights/tokenizer are present locally;
    /// otherwise falls back cleanly to Apple Speech so recording always works immediately.
    public var effectiveSpeechEngine: SpeechEngine {
        if selectedSpeechEngine == .whisperKit && isWhisperDownloaded {
            return .whisperKit
        }
        return .appleSpeech
    }

    public let deviceRAMGB: Double

    /// `true` on 4 GB RAM iPhones (e.g. iPhone 11/12/SE2/SE3) where SideStore's Jetsam ceiling
    /// makes `Whisper Small (217 MB)` much safer than 547–626 MB Large v3 variants.
    public var isLowRAMDeviceForLargeWhisper: Bool {
        deviceRAMGB < 5.5
    }

    /// Selects a RAM-safe default Whisper preset for first-time setup on SideStore builds.
    public nonisolated static func recommendedWhisperPreset(
        forPhysicalMemoryBytes bytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> WhisperPreset {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb < 5.5 {
            return .smallEn
        }
        if gb < 7.5 {
            return .largeV3TurboCompact
        }
        return .largeV3Turbo
    }

    /// Returns `true` when either WhisperKit or Apple Speech is ready AND the local LLM is downloaded.
    public func isAllReady(appleSpeechReady: Bool) -> Bool {
        let voiceReady = (effectiveSpeechEngine == .whisperKit) || appleSpeechReady
        return voiceReady && isLLMDownloaded
    }

    private let defaults: UserDefaults
    private let currentOSBuildMarker: String
    @ObservationIgnored private var activeWhisperDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var activeWhisperDownloadID: UUID?
    @ObservationIgnored private var whisperBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var activeLLMDownloadSession: URLSession?
    @ObservationIgnored private var activeLLMDownloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var activeLLMDownloadID: UUID?

    public init(
        defaults: UserDefaults = .standard,
        osBuildMarker: String = ProcessInfo.processInfo.operatingSystemVersionString,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.defaults = defaults
        self.currentOSBuildMarker = osBuildMarker
        self.deviceRAMGB = Double(physicalMemoryBytes) / 1_073_741_824.0

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.modelsRootDirectory = appSupport.appendingPathComponent("BuddyModels", isDirectory: true)
        self.whisperBaseDirectory = modelsRootDirectory.appendingPathComponent("Whisper", isDirectory: true)
        self.llmBaseDirectory = modelsRootDirectory.appendingPathComponent("LLM", isDirectory: true)

        if let storedEngine = defaults.string(forKey: DefaultsKey.selectedSpeechEngine),
           let parsedEngine = SpeechEngine(rawValue: storedEngine) {
            self.selectedSpeechEngine = parsedEngine
        }

        if let storedWhisper = defaults.string(forKey: DefaultsKey.selectedWhisperPreset),
           let parsedWhisper = WhisperPreset(rawValue: storedWhisper) {
            self.selectedWhisperPreset = parsedWhisper
        } else {
            self.selectedWhisperPreset = Self.recommendedWhisperPreset(forPhysicalMemoryBytes: physicalMemoryBytes)
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
        refreshDownloadState()
    }

    public func isDownloaded(_ preset: WhisperPreset) -> Bool {
        resolvedWhisperFolderURL(for: preset) != nil
    }

    public func isDownloaded(_ preset: LLMPreset) -> Bool {
        resolvedLLMFileURL(for: preset) != nil
    }

    /// Tracks whether CoreML ANE specialization already completed for `preset` on the current iOS version.
    public func isPrewarmed(_ preset: WhisperPreset) -> Bool {
        let map = defaults.dictionary(forKey: DefaultsKey.prewarmedWhisperVariants) as? [String: String] ?? [:]
        return map[preset.rawValue] == currentOSBuildMarker
    }

    public func markPrewarmed(_ preset: WhisperPreset) {
        var map = defaults.dictionary(forKey: DefaultsKey.prewarmedWhisperVariants) as? [String: String] ?? [:]
        map[preset.rawValue] = currentOSBuildMarker
        defaults.set(map, forKey: DefaultsKey.prewarmedWhisperVariants)
    }

    public func clearPrewarmed(_ preset: WhisperPreset) {
        var map = defaults.dictionary(forKey: DefaultsKey.prewarmedWhisperVariants) as? [String: String] ?? [:]
        map.removeValue(forKey: preset.rawValue)
        defaults.set(map, forKey: DefaultsKey.prewarmedWhisperVariants)
    }

    /// Downloads the WhisperKit CoreML model + offline tokenizer, then optionally runs a one-time
    /// sequential Neural Engine prewarm so the first gym mic tap is fast and memory-safe.
    public func downloadWhisperModel(
        _ preset: WhisperPreset? = nil,
        onOptimizeModel: (@MainActor (WhisperPreset) async throws -> Void)? = nil
    ) async {
        guard !isDownloadingWhisper && !isOptimizingWhisper else { return }

        let targetPreset = preset ?? selectedWhisperPreset
        if selectedWhisperPreset != targetPreset {
            selectedWhisperPreset = targetPreset
        }

        ensureModelDirectories()
        let downloadID = UUID()
        activeWhisperDownloadID = downloadID
        isDownloadingWhisper = true
        isOptimizingWhisper = false
        whisperDownloadProgress = 0
        whisperDownloadStatusText = "Downloading \(targetPreset.shortDisplayName)…"
        whisperError = nil

        beginWhisperBackgroundTask(forDownloadID: downloadID)

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeWhisperDownloadID == downloadID {
                    self.isDownloadingWhisper = false
                    self.isOptimizingWhisper = false
                    self.activeWhisperDownloadTask = nil
                    self.activeWhisperDownloadID = nil
                    self.endWhisperBackgroundTask()
                }
            }

            do {
                let folderURL: URL
                do {
                    folderURL = try await WhisperKit.download(
                        variant: targetPreset.rawValue,
                        downloadBase: self.whisperBaseDirectory,
                        useBackgroundSession: false,
                        from: "argmaxinc/whisperkit-coreml"
                    ) { [weak self] progress in
                        let fraction = min(0.88, max(0.0, progress.fractionCompleted * 0.88))
                        Task { @MainActor [weak self] in
                            guard let self, self.activeWhisperDownloadID == downloadID else { return }
                            self.whisperDownloadProgress = fraction
                        }
                    }
                } catch {
                    if Self.isCancellationError(error) || Task.isCancelled || self.activeWhisperDownloadID != downloadID {
                        throw CancellationError()
                    }
                    // Fallback to shorter glob if upstream folder naming changes.
                    folderURL = try await WhisperKit.download(
                        variant: targetPreset.variantGlob,
                        downloadBase: self.whisperBaseDirectory,
                        useBackgroundSession: false,
                        from: "argmaxinc/whisperkit-coreml"
                    ) { [weak self] progress in
                        let fraction = min(0.88, max(0.0, progress.fractionCompleted * 0.88))
                        Task { @MainActor [weak self] in
                            guard let self, self.activeWhisperDownloadID == downloadID else { return }
                            self.whisperDownloadProgress = fraction
                        }
                    }
                }

                guard self.activeWhisperDownloadID == downloadID, !Task.isCancelled else {
                    throw CancellationError()
                }

                // Pre-cache tokenizer + config files while online so Airplane Mode works 100% offline.
                self.whisperDownloadProgress = 0.90
                self.whisperDownloadStatusText = "Caching offline tokenizer…"
                _ = try await ModelUtilities.loadTokenizer(
                    for: targetPreset.whisperModelVariant,
                    tokenizerFolder: self.whisperBaseDirectory,
                    additionalSearchPaths: [folderURL]
                )

                guard self.activeWhisperDownloadID == downloadID, !Task.isCancelled else {
                    throw CancellationError()
                }

                guard self.hasCachedTokenizer(for: targetPreset, modelFolder: folderURL) else {
                    throw ModelManagerError.whisperTokenizerMissing(
                        "Whisper tokenizer files were not cached locally. Check your Wi-Fi connection and retry."
                    )
                }

                self.excludeFromBackup(self.whisperBaseDirectory)
                self.excludeFromBackup(folderURL)
                self.saveWhisperRelativePath(for: targetPreset, folderURL: folderURL)
                self.clearPrewarmed(targetPreset)
                self.refreshDownloadState()

                // One-time sequential ANE specialization while still in Settings so the first gym
                // recording responds cleanly without a long compile pause or peak-RAM spike.
                if let onOptimizeModel {
                    self.isDownloadingWhisper = false
                    self.isOptimizingWhisper = true
                    self.whisperDownloadProgress = 0.94
                    self.whisperDownloadStatusText = "Optimizing for Neural Engine (one-time)…"
                    do {
                        try await onOptimizeModel(targetPreset)
                    } catch {
                        if Self.isCancellationError(error) || Task.isCancelled || self.activeWhisperDownloadID != downloadID {
                            throw CancellationError()
                        }
                        // Model weights are downloaded cleanly; surface optimization warning without failing download.
                        self.whisperError = "Model downloaded, but Neural Engine pre-optimization paused: \(error.localizedDescription)"
                    }
                }

                guard self.activeWhisperDownloadID == downloadID, !Task.isCancelled else {
                    throw CancellationError()
                }

                self.whisperDownloadProgress = 1.0
                self.whisperDownloadStatusText = ""
                self.selectedSpeechEngine = .whisperKit
                self.refreshDownloadState()
            } catch {
                guard self.activeWhisperDownloadID == downloadID else { return }
                if Self.isCancellationError(error) || Task.isCancelled {
                    self.whisperDownloadProgress = 0
                    self.whisperDownloadStatusText = ""
                    self.refreshDownloadState()
                } else {
                    self.whisperError = "Whisper download failed: \(error.localizedDescription)"
                    self.whisperDownloadProgress = 0
                    self.whisperDownloadStatusText = ""
                    self.refreshDownloadState()
                }
            }
        }

        activeWhisperDownloadTask = task
        await task.value
    }

    public func cancelWhisperDownload() {
        let taskToCancel = activeWhisperDownloadTask
        activeWhisperDownloadID = nil
        activeWhisperDownloadTask = nil
        isDownloadingWhisper = false
        isOptimizingWhisper = false
        whisperDownloadProgress = 0
        whisperDownloadStatusText = ""
        taskToCancel?.cancel()
        endWhisperBackgroundTask()
        cleanupIncompleteWhisperCache()
        refreshDownloadState()
    }

    public func deleteWhisperModel(_ preset: WhisperPreset? = nil) {
        let targetPreset = preset ?? selectedWhisperPreset
        if let folderURL = resolvedWhisperFolderURL(for: targetPreset) {
            try? FileManager.default.removeItem(at: folderURL)
        }
        removeWhisperRelativePath(for: targetPreset)
        clearPrewarmed(targetPreset)
        cleanupIncompleteWhisperCache()
        cleanupOrphanedTokenizer(for: targetPreset)
        whisperDownloadProgress = 0
        whisperDownloadStatusText = ""
        whisperError = nil
        refreshDownloadState()
        if selectedSpeechEngine == .whisperKit && !isWhisperDownloaded {
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
        let whisperFolder = resolvedWhisperFolderURL(for: selectedWhisperPreset)
        activeWhisperFolderURL = whisperFolder
        isWhisperDownloaded = (whisperFolder != nil)

        let llmFile = resolvedLLMFileURL(for: selectedLLMPreset)
        activeLLMFileURL = llmFile
        isLLMDownloaded = (llmFile != nil)

        totalStorageUsedDescription = Self.formattedDirectorySize(at: modelsRootDirectory)
    }

    public func resolvedWhisperFolderURL(for preset: WhisperPreset) -> URL? {
        let fileManager = FileManager.default

        // 1. Check persisted relative path under Whisper base directory.
        if let stored = defaults.dictionary(forKey: DefaultsKey.whisperRelativePaths) as? [String: String],
           let relative = stored[preset.rawValue], !relative.isEmpty {
            let candidate = whisperBaseDirectory.appendingPathComponent(relative, isDirectory: true)
            if Self.isValidWhisperFolder(candidate) && hasCachedTokenizer(for: preset, modelFolder: candidate) {
                return candidate
            }
        }

        // 2. Check standard HuggingFace Hub cache structure created by WhisperKit.download.
        let standardCandidates: [URL] = [
            whisperBaseDirectory
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(preset.rawValue, isDirectory: true),
            whisperBaseDirectory.appendingPathComponent(preset.rawValue, isDirectory: true)
        ]

        for candidate in standardCandidates where Self.isValidWhisperFolder(candidate) && hasCachedTokenizer(for: preset, modelFolder: candidate) {
            return candidate
        }

        // 3. Fallback scan inside Whisper base directory.
        guard let enumerator = fileManager.enumerator(
            at: whisperBaseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if url.lastPathComponent == preset.rawValue
                && Self.isValidWhisperFolder(url)
                && hasCachedTokenizer(for: preset, modelFolder: url) {
                return url
            }
        }

        return nil
    }

    // MARK: - Private Filesystem & Persistence Helpers

    private var customLLMDirectory: URL {
        llmBaseDirectory.appendingPathComponent("Custom", isDirectory: true)
    }

    private func beginWhisperBackgroundTask(forDownloadID downloadID: UUID) {
        endWhisperBackgroundTask()
        whisperBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "BuddyWhisperDownload") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeWhisperDownloadID == downloadID else { return }
                self.endWhisperBackgroundTask()
            }
        }
    }

    private func endWhisperBackgroundTask() {
        let taskID = whisperBackgroundTaskID
        guard taskID != .invalid else { return }
        whisperBackgroundTaskID = .invalid
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
        for directory in [modelsRootDirectory, whisperBaseDirectory, llmBaseDirectory, customLLMDirectory] {
            if !fileManager.fileExists(atPath: directory.path) {
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            excludeFromBackup(directory)
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private func saveWhisperRelativePath(for preset: WhisperPreset, folderURL: URL) {
        var stored = defaults.dictionary(forKey: DefaultsKey.whisperRelativePaths) as? [String: String] ?? [:]
        let basePath = whisperBaseDirectory.standardizedFileURL.path
        let folderPath = folderURL.standardizedFileURL.path
        if folderPath.hasPrefix(basePath) {
            let relative = String(folderPath.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            stored[preset.rawValue] = relative
        } else {
            stored[preset.rawValue] = folderURL.lastPathComponent
        }
        defaults.set(stored, forKey: DefaultsKey.whisperRelativePaths)
    }

    private func removeWhisperRelativePath(for preset: WhisperPreset) {
        var stored = defaults.dictionary(forKey: DefaultsKey.whisperRelativePaths) as? [String: String] ?? [:]
        stored.removeValue(forKey: preset.rawValue)
        defaults.set(stored, forKey: DefaultsKey.whisperRelativePaths)
    }

    /// Verifies BOTH `tokenizer.json` and `tokenizer_config.json` exist locally (both are required
    /// by `AutoTokenizer.from(modelFolder:)` for 100% offline Airplane Mode loading).
    private func hasCachedTokenizer(for preset: WhisperPreset, modelFolder: URL) -> Bool {
        let fileManager = FileManager.default
        let tokenizerRepoName = preset.tokenizerRepoName
        let candidateFolders: [URL] = [
            whisperBaseDirectory
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(tokenizerRepoName, isDirectory: true),
            modelFolder
        ]
        return candidateFolders.contains { folder in
            let tokenizerFile = folder.appendingPathComponent("tokenizer.json", isDirectory: false)
            let configFile = folder.appendingPathComponent("tokenizer_config.json", isDirectory: false)
            return fileManager.fileExists(atPath: tokenizerFile.path)
                && fileManager.fileExists(atPath: configFile.path)
        }
    }

    /// Sweeps partial `.incomplete` Hub download cache files so cancelled or deleted downloads
    /// never bloat `BuddyModels/Whisper` storage.
    private func cleanupIncompleteWhisperCache() {
        let fileManager = FileManager.default
        let hubCacheDir = whisperBaseDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true)

        guard fileManager.fileExists(atPath: hubCacheDir.path),
              let enumerator = fileManager.enumerator(at: hubCacheDir, includingPropertiesForKeys: nil) else {
            return
        }

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "incomplete" {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// Removes the cached HuggingFace tokenizer folder if no other installed Whisper preset needs it.
    private func cleanupOrphanedTokenizer(for deletedPreset: WhisperPreset) {
        let repoName = deletedPreset.tokenizerRepoName
        let stillNeeded = WhisperPreset.allCases.contains { other in
            other != deletedPreset && other.tokenizerRepoName == repoName && isDownloaded(other)
        }
        guard !stillNeeded else { return }

        let tokenizerFolder = whisperBaseDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoName, isDirectory: true)
        try? FileManager.default.removeItem(at: tokenizerFolder)
    }

    private static func isValidWhisperFolder(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let hasMel = fileManager.fileExists(atPath: url.appendingPathComponent("MelSpectrogram.mlmodelc").path)
            || fileManager.fileExists(atPath: url.appendingPathComponent("MelSpectrogram.mlpackage").path)
        let hasEncoder = fileManager.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path)
            || fileManager.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlpackage").path)
        let hasDecoder = fileManager.fileExists(atPath: url.appendingPathComponent("TextDecoder.mlmodelc").path)
            || fileManager.fileExists(atPath: url.appendingPathComponent("TextDecoder.mlpackage").path)
        return hasMel && hasEncoder && hasDecoder
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

    private static func formattedDirectorySize(at directory: URL) -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "0 MB"
        }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            totalBytes += Int64(size)
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
