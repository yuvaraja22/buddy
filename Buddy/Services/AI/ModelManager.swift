import Foundation
import Observation
import WhisperKit

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
public typealias AppleSpeechLocaleOption = ModelManager.AppleSpeechLocaleOption
public typealias WhisperPreset = ModelManager.WhisperPreset
public typealias LLMPreset = ModelManager.LLMPreset

@Observable
@MainActor
public final class ModelManager {
    public enum SpeechEngine: String, CaseIterable, Identifiable, Codable, Sendable {
        case appleOnDevice = "apple-on-device"
        case whisperKit = "whisperkit"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .appleOnDevice: return "Apple On-Device"
            case .whisperKit: return "WhisperKit (CoreML)"
            }
        }

        public var shortName: String {
            switch self {
            case .appleOnDevice: return "Apple Speech"
            case .whisperKit: return "WhisperKit"
            }
        }

        public var subtitle: String {
            switch self {
            case .appleOnDevice:
                return "Instant live captions, 0 MB download, strong accent support & zero extra RAM"
            case .whisperKit:
                return "OpenAI Whisper running offline via CoreML + Apple Neural Engine"
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

    public enum WhisperPreset: String, CaseIterable, Identifiable, Codable, Sendable {
        case largeV3Turbo = "openai_whisper-large-v3-v20240930_626MB"
        case small = "openai_whisper-small_216MB"
        case baseEn = "openai_whisper-base.en"
        case baseMultilingual = "openai_whisper-base"
        case tinyEn = "openai_whisper-tiny.en"

        public var id: String { rawValue }

        public var variantGlob: String {
            switch self {
            case .largeV3Turbo: return "large-v3-v20240930_626MB"
            case .small: return "small_216MB"
            case .baseEn: return "base.en"
            case .baseMultilingual: return "base"
            case .tinyEn: return "tiny.en"
            }
        }

        public var displayName: String {
            switch self {
            case .largeV3Turbo: return "Whisper Large v3 Turbo"
            case .small: return "Whisper Small"
            case .baseEn: return "Whisper Base (English)"
            case .baseMultilingual: return "Whisper Base (Multilingual)"
            case .tinyEn: return "Whisper Tiny (English)"
            }
        }

        public var subtitle: String {
            switch self {
            case .largeV3Turbo: return "Best Whisper accuracy & global accents (~626 MB)"
            case .small: return "High accuracy with smaller footprint (~216 MB)"
            case .baseEn: return "Balanced speed & size (English-only)"
            case .baseMultilingual: return "Lightweight multilingual Whisper"
            case .tinyEn: return "Fastest transcription & lowest RAM"
            }
        }

        public var approximateSizeMB: Int {
            switch self {
            case .largeV3Turbo: return 626
            case .small: return 216
            case .baseEn: return 145
            case .baseMultilingual: return 145
            case .tinyEn: return 75
            }
        }

        public var languageCode: String? {
            switch self {
            case .largeV3Turbo, .small, .baseEn, .tinyEn:
                return "en"
            case .baseMultilingual:
                return nil
            }
        }

        var whisperModelVariant: ModelVariant {
            switch self {
            case .largeV3Turbo: return .largev3
            case .small: return .small
            case .baseEn: return .baseEn
            case .baseMultilingual: return .base
            case .tinyEn: return .tinyEn
            }
        }

        public var tokenizerRepoName: String {
            switch self {
            case .largeV3Turbo: return "openai/whisper-large-v3"
            case .small: return "openai/whisper-small"
            case .baseEn: return "openai/whisper-base.en"
            case .baseMultilingual: return "openai/whisper-base"
            case .tinyEn: return "openai/whisper-tiny.en"
            }
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
        static let selectedAppleSpeechLocale = "buddy.models.appleSpeechLocale"
        static let selectedWhisperPreset = "buddy.models.selectedWhisperPreset"
        static let selectedLLMPreset = "buddy.models.selectedLLMPreset"
        static let customLLMFileName = "buddy.models.customLLMFileName"
        static let whisperRelativePaths = "buddy.models.whisperRelativePaths"
    }

    public let modelsRootDirectory: URL
    public let whisperBaseDirectory: URL
    public let llmBaseDirectory: URL

    @ObservationIgnored private var isInitializing: Bool = true

    public var selectedSpeechEngine: SpeechEngine = .appleOnDevice {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedSpeechEngine.rawValue, forKey: DefaultsKey.selectedSpeechEngine)
        }
    }

    public var selectedAppleSpeechLocale: AppleSpeechLocaleOption = .auto {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedAppleSpeechLocale.rawValue, forKey: DefaultsKey.selectedAppleSpeechLocale)
        }
    }

    public var selectedWhisperPreset: WhisperPreset = .largeV3Turbo {
        didSet {
            guard !isInitializing else { return }
            defaults.set(selectedWhisperPreset.rawValue, forKey: DefaultsKey.selectedWhisperPreset)
            refreshDownloadState()
        }
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
    public var llmDownloadProgress: Double = 0
    public var isDownloadingLLM: Bool = false
    public var downloadError: String?

    public var isWhisperDownloaded: Bool = false
    public var isLLMDownloaded: Bool = false
    public var activeWhisperFolderURL: URL?
    public var activeLLMFileURL: URL?
    public var totalStorageUsedDescription: String = "0 MB"

    /// Evaluates whether voice logging is actually usable given Apple On-Device Speech permission
    /// and offline dictation availability (or local WhisperKit files when WhisperKit is selected).
    public func isVoiceReady(appleSpeechReady: Bool) -> Bool {
        switch selectedSpeechEngine {
        case .appleOnDevice:
            return appleSpeechReady
        case .whisperKit:
            return isWhisperDownloaded
        }
    }

    /// Returns `true` only when both the active voice engine and the local LLM are ready offline.
    public func isAllReady(appleSpeechReady: Bool) -> Bool {
        isVoiceReady(appleSpeechReady: appleSpeechReady) && isLLMDownloaded
    }

    /// Returns whether all required *downloadable* model files for the selected engine are on disk.
    public var isAllDownloaded: Bool {
        switch selectedSpeechEngine {
        case .appleOnDevice:
            return isLLMDownloaded
        case .whisperKit:
            return isWhisperDownloaded && isLLMDownloaded
        }
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var activeLLMDownloadSession: URLSession?
    @ObservationIgnored private var activeLLMDownloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var activeLLMDownloadID: UUID?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.modelsRootDirectory = appSupport.appendingPathComponent("BuddyModels", isDirectory: true)
        self.whisperBaseDirectory = modelsRootDirectory.appendingPathComponent("Whisper", isDirectory: true)
        self.llmBaseDirectory = modelsRootDirectory.appendingPathComponent("LLM", isDirectory: true)

        if let storedEngine = defaults.string(forKey: DefaultsKey.selectedSpeechEngine),
           let parsedEngine = SpeechEngine(rawValue: storedEngine) {
            self.selectedSpeechEngine = parsedEngine
        }

        if let storedLocale = defaults.string(forKey: DefaultsKey.selectedAppleSpeechLocale),
           let parsedLocale = AppleSpeechLocaleOption(rawValue: storedLocale) {
            self.selectedAppleSpeechLocale = parsedLocale
        }

        if let storedWhisper = defaults.string(forKey: DefaultsKey.selectedWhisperPreset),
           let parsedWhisper = WhisperPreset(rawValue: storedWhisper) {
            self.selectedWhisperPreset = parsedWhisper
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

    public func downloadWhisperModel(_ preset: WhisperPreset? = nil) async {
        guard !isDownloadingWhisper else { return }

        let targetPreset = preset ?? selectedWhisperPreset
        if selectedWhisperPreset != targetPreset {
            selectedWhisperPreset = targetPreset
        }

        ensureModelDirectories()
        isDownloadingWhisper = true
        whisperDownloadProgress = 0
        downloadError = nil
        defer { isDownloadingWhisper = false }

        do {
            let folderURL: URL
            do {
                folderURL = try await WhisperKit.download(
                    variant: targetPreset.rawValue,
                    downloadBase: whisperBaseDirectory,
                    useBackgroundSession: false,
                    from: "argmaxinc/whisperkit-coreml"
                ) { [weak self] progress in
                    let fraction = min(0.90, max(0.0, progress.fractionCompleted * 0.90))
                    Task { @MainActor [weak self] in
                        self?.whisperDownloadProgress = fraction
                    }
                }
            } catch {
                // Fallback to shorter glob if upstream naming changes.
                folderURL = try await WhisperKit.download(
                    variant: targetPreset.variantGlob,
                    downloadBase: whisperBaseDirectory,
                    useBackgroundSession: false,
                    from: "argmaxinc/whisperkit-coreml"
                ) { [weak self] progress in
                    let fraction = min(0.90, max(0.0, progress.fractionCompleted * 0.90))
                    Task { @MainActor [weak self] in
                        self?.whisperDownloadProgress = fraction
                    }
                }
            }

            // Pre-cache tokenizer files while online (mandatory so Airplane Mode works 100% offline).
            whisperDownloadProgress = 0.94
            _ = try await ModelUtilities.loadTokenizer(
                for: targetPreset.whisperModelVariant,
                tokenizerFolder: whisperBaseDirectory,
                additionalSearchPaths: [folderURL]
            )

            guard hasCachedTokenizer(for: targetPreset, modelFolder: folderURL) else {
                throw ModelManagerError.invalidGGUFFile("Whisper tokenizer files were not cached locally. Check your Wi-Fi connection and retry.")
            }

            excludeFromBackup(whisperBaseDirectory)
            excludeFromBackup(folderURL)
            saveWhisperRelativePath(for: targetPreset, folderURL: folderURL)

            whisperDownloadProgress = 1.0
            refreshDownloadState()
        } catch is CancellationError {
            whisperDownloadProgress = 0
        } catch {
            downloadError = "Whisper download failed: \(error.localizedDescription)"
            whisperDownloadProgress = 0
            refreshDownloadState()
        }
    }

    public func downloadLLMModel(_ preset: LLMPreset? = nil) async {
        guard !isDownloadingLLM else { return }

        let targetPreset = preset ?? selectedLLMPreset
        guard targetPreset != .custom,
              let remoteURL = targetPreset.downloadURL,
              !targetPreset.fileName.isEmpty else {
            downloadError = ModelManagerError.invalidDownloadURL.localizedDescription
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
        downloadError = nil

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
                downloadError = "LLM download failed: \(error.localizedDescription)"
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
        downloadError = nil
        if selectedSpeechEngine == .whisperKit {
            let targetWhisper = selectedWhisperPreset
            if !isDownloaded(targetWhisper) {
                await downloadWhisperModel(targetWhisper)
            }
        }

        if !isDownloaded(.qwen25_1_5B) {
            await downloadLLMModel(.qwen25_1_5B)
        } else if selectedLLMPreset != .qwen25_1_5B {
            selectedLLMPreset = .qwen25_1_5B
        }
        refreshDownloadState()
    }

    public func importCustomGGUF(from url: URL) throws {
        ensureModelDirectories()
        downloadError = nil

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

    public func deleteWhisperModel(_ preset: WhisperPreset? = nil) {
        let targetPreset = preset ?? selectedWhisperPreset
        if let folderURL = resolvedWhisperFolderURL(for: targetPreset) {
            try? FileManager.default.removeItem(at: folderURL)
        }
        removeWhisperRelativePath(for: targetPreset)
        whisperDownloadProgress = 0
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

    // MARK: - Private Filesystem & Persistence Helpers

    private var customLLMDirectory: URL {
        llmBaseDirectory.appendingPathComponent("Custom", isDirectory: true)
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

    private func resolvedWhisperFolderURL(for preset: WhisperPreset) -> URL? {
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

        // 3. Fallback shallow scan inside Whisper base directory.
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
            if url.lastPathComponent == preset.rawValue && Self.isValidWhisperFolder(url) && hasCachedTokenizer(for: preset, modelFolder: url) {
                return url
            }
        }

        return nil
    }

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
            return fileManager.fileExists(atPath: tokenizerFile.path)
        }
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
                // Backward-compatible lookup if a custom file was imported before Custom/ isolation.
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
