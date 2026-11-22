import AVFoundation
import Foundation
import Observation
import Speech

public enum AppleSpeechError: LocalizedError, Sendable {
    case permissionDenied
    case onDeviceUnavailable(String)
    case recognizerUnavailable
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech Recognition permission is needed for offline voice logging. Enable it in iOS Settings → Buddy."
        case .onDeviceUnavailable(let detail):
            return detail
        case .recognizerUnavailable:
            return "Apple On-Device Speech Recognizer is temporarily unavailable. Please try again in a moment."
        case .recognitionFailed(let detail):
            return "Speech recognition failed: \(detail)"
        }
    }
}

/// Summary of on-device offline readiness for the selected locale option.
public struct AppleSpeechAvailability: Equatable, Sendable {
    public let isReady: Bool
    public let activeLocaleIdentifier: String?
    public let activeLocaleDisplayName: String?
    public let usedFallbackFromDeviceLocale: Bool
    public let statusMessage: String

    public init(
        isReady: Bool,
        activeLocaleIdentifier: String?,
        activeLocaleDisplayName: String?,
        usedFallbackFromDeviceLocale: Bool,
        statusMessage: String
    ) {
        self.isReady = isReady
        self.activeLocaleIdentifier = activeLocaleIdentifier
        self.activeLocaleDisplayName = activeLocaleDisplayName
        self.usedFallbackFromDeviceLocale = usedFallbackFromDeviceLocale
        self.statusMessage = statusMessage
    }
}

/// Thread-safe holder for the active `SFSpeechAudioBufferRecognitionRequest`.
/// Keeps the critical section tiny (pointer swap only) and invokes `endAudio()` strictly
/// outside the lock to prevent priority inversion / XPC contention on CoreAudio's realtime IO thread.
private final class LockedSpeechRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = newRequest
        lock.unlock()
    }

    func swap(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        let previous = request
        request = newRequest
        lock.unlock()
        return previous
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    func endAudioAndClear() {
        lock.lock()
        let current = request
        request = nil
        lock.unlock()
        current?.endAudio()
    }

    func clearWithoutEnding() {
        lock.lock()
        request = nil
        lock.unlock()
    }
}

@Observable
@MainActor
public final class AppleSpeechService {
    private static let maxMidRecordingRollovers: Int = 12

    public var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    public var isListening: Bool = false

    private let activeRequestBox = LockedSpeechRequestBox()
    @ObservationIgnored private var activeRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var activeTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private var activeLocaleOption: AppleSpeechLocaleOption = .auto
    @ObservationIgnored private var activeContextualStrings: [String] = []
    @ObservationIgnored private var activePartialHandler: (@MainActor (String) -> Void)?
    @ObservationIgnored private var committedSegments: [String] = []
    @ObservationIgnored private var currentSegmentTranscript: String = ""
    @ObservationIgnored private var isStopping: Bool = false
    @ObservationIgnored private var didReceiveFinalResult: Bool = false
    @ObservationIgnored private var rolloverCount: Int = 0
    @ObservationIgnored private var pendingFatalError: AppleSpeechError?
    @ObservationIgnored private var finishContinuation: CheckedContinuation<String, Error>?
    @ObservationIgnored private var finishTimeoutTask: Task<Void, Never>?

    public init() {
        refreshAuthorizationStatus()
    }

    public func refreshAuthorizationStatus() {
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
    }

    public func requestAuthorization() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        authorizationStatus = current

        switch current {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { result in
                    continuation.resume(returning: result)
                }
            }
            authorizationStatus = status
            return status == .authorized
        @unknown default:
            return false
        }
    }

    /// Returns `true` only when Speech Recognition is not denied/restricted AND an on-device
    /// offline recognizer is installed for the chosen locale option.
    public func isReadyForOfflineVoice(for option: AppleSpeechLocaleOption) -> Bool {
        let status = authorizationStatus
        guard status != .denied && status != .restricted else {
            return false
        }
        return checkAvailability(for: option).isReady
    }

    /// Evaluates whether Apple's 100% offline on-device recognizer is available for the chosen
    /// locale option. When `.auto` is chosen, prefers `Locale.current` and falls back to an
    /// installed English offline recognizer (`en-IN`, `en-US`, `en-GB`) if the device locale's
    /// offline pack hasn't been downloaded yet.
    public func checkAvailability(for option: AppleSpeechLocaleOption) -> AppleSpeechAvailability {
        let resolved = resolveRecognizer(for: option)
        if let recognizer = resolved.recognizer {
            let identifier = recognizer.locale.identifier
            let displayName = Self.localizedDisplayName(for: recognizer.locale)
            if resolved.usedFallback {
                let deviceName = Self.localizedDisplayName(for: Locale.current)
                return AppleSpeechAvailability(
                    isReady: true,
                    activeLocaleIdentifier: identifier,
                    activeLocaleDisplayName: displayName,
                    usedFallbackFromDeviceLocale: true,
                    statusMessage: "Using \(displayName) offline. For \(deviceName), enable it in iOS Settings → General → Keyboard → Dictation Languages."
                )
            }
            return AppleSpeechAvailability(
                isReady: true,
                activeLocaleIdentifier: identifier,
                activeLocaleDisplayName: displayName,
                usedFallbackFromDeviceLocale: false,
                statusMessage: "On-Device Offline Ready · \(displayName)"
            )
        }

        return AppleSpeechAvailability(
            isReady: false,
            activeLocaleIdentifier: nil,
            activeLocaleDisplayName: nil,
            usedFallbackFromDeviceLocale: false,
            statusMessage: unavailableMessage(for: option)
        )
    }

    public func unavailableMessage(for option: AppleSpeechLocaleOption) -> String {
        switch option {
        case .auto:
            return "Apple On-Device Dictation isn't enabled on this iPhone yet. Turn on Dictation in iOS Settings → General → Keyboard."
        case .enIN, .enUS, .enGB, .enAU, .enCA:
            return "Offline dictation for \(option.displayName) isn't downloaded yet. Add it in iOS Settings → General → Keyboard → Dictation Languages, or pick Auto / English (US)."
        }
    }

    /// Starts a 100% on-device streaming recognition session (`requiresOnDeviceRecognition = true`)
    /// primed with Buddy's gym exercise vocabulary.
    public func startStreaming(
        localeOption: AppleSpeechLocaleOption,
        contextualStrings: [String],
        onPartialTranscript: @escaping @MainActor (String) -> Void
    ) throws {
        cancelStreaming()

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AppleSpeechError.permissionDenied
        }

        let resolved = resolveRecognizer(for: localeOption)
        guard let recognizer = resolved.recognizer else {
            throw AppleSpeechError.onDeviceUnavailable(unavailableMessage(for: localeOption))
        }
        guard recognizer.isAvailable else {
            throw AppleSpeechError.recognizerUnavailable
        }

        activeRecognizer = recognizer
        activeLocaleOption = localeOption
        activeContextualStrings = contextualStrings
        activePartialHandler = onPartialTranscript
        committedSegments = []
        currentSegmentTranscript = ""
        isStopping = false
        didReceiveFinalResult = false
        rolloverCount = 0
        pendingFatalError = nil
        isListening = true

        beginRecognitionTask(on: recognizer)
    }

    /// Thread-safe audio buffer entry point invoked from CoreAudio's realtime tap.
    public nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        activeRequestBox.append(buffer)
    }

    /// Signals end-of-audio and awaits Apple's final transcription pass (up to `timeoutSeconds`),
    /// always returning immediately if the task already terminated and preserving all committed
    /// segments captured before any mid-recording pause or rollover.
    public func finishStreaming(timeoutSeconds: TimeInterval = 1.2) async throws -> String {
        isStopping = true
        activeRequestBox.endAudioAndClear()
        isListening = false

        if didReceiveFinalResult || activeTask == nil {
            let combined = currentCombinedTranscript()
            let fatalError = pendingFatalError
            cleanupTaskState()
            if !combined.isEmpty {
                return combined
            }
            if let fatalError {
                throw fatalError
            }
            return ""
        }

        let currentSessionID = activeSessionID
        let transcript = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            // Defensive guard: never overwrite or leak a prior pending CheckedContinuation.
            if let prior = self.finishContinuation {
                self.finishContinuation = nil
                prior.resume(returning: self.currentCombinedTranscript())
            }
            self.finishContinuation = continuation
            self.finishTimeoutTask?.cancel()
            self.finishTimeoutTask = Task { @MainActor [weak self] in
                let delayNs = UInt64(max(0.2, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delayNs)
                guard let self, self.activeSessionID == currentSessionID else { return }
                let best = self.currentCombinedTranscript()
                self.resolvePendingFinish(with: .success(best))
            }
        }

        cleanupTaskState()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancelStreaming() {
        activeSessionID = nil
        isStopping = false
        activeRequestBox.clearWithoutEnding()
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil

        if let pending = finishContinuation {
            finishContinuation = nil
            pending.resume(throwing: CancellationError())
        }

        activeTask?.cancel()
        activeTask = nil
        activeRecognizer = nil
        activePartialHandler = nil
        committedSegments = []
        currentSegmentTranscript = ""
        didReceiveFinalResult = false
        rolloverCount = 0
        pendingFatalError = nil
        isListening = false
    }

    /// Merges committed pre-pause/pre-rollover speech segments with the active segment cleanly.
    public nonisolated static func mergeTranscriptSegments(
        committed: [String],
        current: String
    ) -> String {
        var parts: [String] = []
        for segment in committed {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        let currentTrimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTrimmed.isEmpty {
            if let last = parts.last, last.caseInsensitiveCompare(currentTrimmed) == .orderedSame {
                // Skip exact duplicate segment
            } else {
                parts.append(currentTrimmed)
            }
        }
        return parts.joined(separator: " ")
    }

    /// Detects when Apple's on-device recognizer resets `bestTranscription.formattedString` to a
    /// brand-new post-pause utterance (dropping pre-pause words) while ignoring normal in-place
    /// word refinements like `"dead lift 100 kg"` -> `"deadlift 100 kg"`.
    public nonisolated static func didResetAfterPause(
        previous: String,
        updated: String
    ) -> Bool {
        let prevTrimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prevTrimmed.isEmpty, !newTrimmed.isEmpty else { return false }

        let prevWords = prevTrimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let newWords = newTrimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)

        // Require at least 2 previously captured words and a clear shrinkage or disjoint restart.
        guard prevWords.count >= 2, newWords.count < prevWords.count else { return false }

        let prevLower = prevTrimmed.lowercased()
        let newLower = newTrimmed.lowercased()
        if prevLower.hasPrefix(newLower) || newLower.hasPrefix(prevLower) || prevLower.contains(newLower) {
            return false
        }

        if let prevFirst = prevWords.first, let newFirst = newWords.first,
           (prevFirst.hasPrefix(newFirst) || newFirst.hasPrefix(prevFirst)) {
            return false
        }

        return Set(prevWords).isDisjoint(with: Set(newWords))
    }

    /// Builds a prioritized list of gym phrases and canonical exercise names to bias Apple's
    /// on-device acoustic/language decoder toward workout logging terms.
    public nonisolated static func buildGymContextualStrings(recentExercises: [String] = []) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func add(_ phrase: String) {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }

        // 1. Exercises already performed in the current session get top priority.
        for name in recentExercises {
            add(name)
        }

        // 2. Core workout vocabulary & voice commands.
        let workoutTerms = [
            "sets", "set", "reps", "rep", "kg", "kilos", "kilograms",
            "lbs", "pounds", "bodyweight", "warmup", "warm up",
            "drop set", "dropset", "to failure", "seconds", "minutes",
            "delete last set", "delete last exercise", "undo",
            "change to", "update last set", "finish workout", "end workout",
            "RDL", "OHP", "DB", "incline", "decline", "cable", "dumbbell", "barbell"
        ]
        for term in workoutTerms {
            add(term)
        }

        // 3. All canonical gym movements in Buddy's ExerciseCatalog.
        for exercise in ExerciseCatalog.all {
            add(exercise.canonicalName)
        }

        return result
    }

    // MARK: - Private Helpers

    private func beginRecognitionTask(on recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = activeContextualStrings

        let sessionID = UUID()
        activeSessionID = sessionID
        didReceiveFinalResult = false

        // Swap the active request pointer atomically and end any previous request outside the lock.
        let previousRequest = activeRequestBox.swap(request)
        previousRequest?.endAudio()

        activeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let formatted = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorInfo: (domain: String, code: Int, description: String)? = error.map {
                let nsError = $0 as NSError
                return (nsError.domain, nsError.code, $0.localizedDescription)
            }

            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == sessionID else { return }

                if let formatted {
                    let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if Self.didResetAfterPause(previous: self.currentSegmentTranscript, updated: trimmed) {
                            self.committedSegments.append(self.currentSegmentTranscript)
                        }
                        self.currentSegmentTranscript = trimmed
                        self.activePartialHandler?(self.currentCombinedTranscript())
                    }
                }

                if isFinal {
                    self.handleTaskTerminated(errorInfo: nil)
                    return
                }

                if let errorInfo {
                    self.handleTaskTerminated(errorInfo: errorInfo)
                }
            }
        }
    }

    private func handleTaskTerminated(errorInfo: (domain: String, code: Int, description: String)?) {
        // Commit any active segment text before releasing this task.
        let trimmedCurrent = currentSegmentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCurrent.isEmpty {
            committedSegments.append(trimmedCurrent)
            currentSegmentTranscript = ""
        }

        activeTask?.cancel()
        activeTask = nil

        let isBenign = errorInfo.map { Self.isBenignNoSpeechOrCancelError(domain: $0.domain, code: $0.code) } ?? true

        // If the user is STILL actively recording (e.g. paused a few seconds in hands-free mode)
        // and Apple Speech ended early with `isFinal` or benign `1110`/`203`, transparently roll
        // over to a fresh recognition request while preserving all already-spoken segments.
        if !isStopping && finishContinuation == nil {
            if isBenign,
               let recognizer = activeRecognizer,
               recognizer.isAvailable,
               rolloverCount < Self.maxMidRecordingRollovers {
                rolloverCount += 1
                beginRecognitionTask(on: recognizer)
                return
            }

            // Non-benign error or rollover cap reached while still recording: mark task finished
            // so tapping Stop resolves immediately without stalling for 1.2s.
            didReceiveFinalResult = true
            isListening = false
            activeRequestBox.clearWithoutEnding()
            if let errorInfo, !isBenign {
                pendingFatalError = AppleSpeechError.recognitionFailed(errorInfo.description)
            }
            return
        }

        // Stopping / finalizing path: mark finished immediately and resolve any awaiting caller.
        didReceiveFinalResult = true
        isListening = false
        let combined = currentCombinedTranscript()

        if !combined.isEmpty {
            resolvePendingFinish(with: .success(combined))
        } else if isBenign {
            resolvePendingFinish(with: .success(""))
        } else if let errorInfo {
            let failure = AppleSpeechError.recognitionFailed(errorInfo.description)
            pendingFatalError = failure
            resolvePendingFinish(with: .failure(failure))
        } else {
            resolvePendingFinish(with: .success(""))
        }
    }

    private func currentCombinedTranscript() -> String {
        Self.mergeTranscriptSegments(
            committed: committedSegments,
            current: currentSegmentTranscript
        )
    }

    private func resolveRecognizer(
        for option: AppleSpeechLocaleOption
    ) -> (recognizer: SFSpeechRecognizer?, usedFallback: Bool) {
        if let explicit = option.explicitLocale {
            if let recognizer = SFSpeechRecognizer(locale: explicit),
               recognizer.supportsOnDeviceRecognition {
                return (recognizer, false)
            }
            return (nil, false)
        }

        // `.auto`: prefer the iPhone's current locale when offline recognition is installed.
        if let currentRecognizer = SFSpeechRecognizer(locale: Locale.current),
           currentRecognizer.supportsOnDeviceRecognition {
            return (currentRecognizer, false)
        }

        // Graceful offline fallback across common English locales if device region pack isn't installed.
        let fallbackIdentifiers = ["en-IN", "en-US", "en-GB", "en-AU", "en-CA"]
        for identifier in fallbackIdentifiers {
            let locale = Locale(identifier: identifier)
            if let candidate = SFSpeechRecognizer(locale: locale),
               candidate.supportsOnDeviceRecognition {
                return (candidate, true)
            }
        }

        return (nil, false)
    }

    private func resolvePendingFinish(with result: Result<String, Error>) {
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil

        guard let continuation = finishContinuation else { return }
        finishContinuation = nil

        switch result {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func cleanupTaskState() {
        activeSessionID = nil
        isStopping = false
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        finishContinuation = nil
        activeTask?.cancel()
        activeTask = nil
        activeRecognizer = nil
        activePartialHandler = nil
        committedSegments = []
        currentSegmentTranscript = ""
        didReceiveFinalResult = false
        rolloverCount = 0
        pendingFatalError = nil
        isListening = false
    }

    private nonisolated static func isBenignNoSpeechOrCancelError(domain: String, code: Int) -> Bool {
        // kAFAssistantErrorDomain: 203 (retry/empty), 209 (cancelled), 216 (cancelled), 1110 (no speech detected)
        if domain == "kAFAssistantErrorDomain" && [203, 209, 216, 1110].contains(code) {
            return true
        }
        // SFSpeechError / Cocoa user cancelled
        if domain == NSCocoaErrorDomain && code == NSUserCancelledError {
            return true
        }
        return false
    }

    private nonisolated static func localizedDisplayName(for locale: Locale) -> String {
        if let localized = Locale.current.localizedString(forIdentifier: locale.identifier),
           !localized.isEmpty {
            return localized
        }
        return locale.identifier
    }
}
