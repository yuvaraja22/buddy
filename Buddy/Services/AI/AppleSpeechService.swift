import AVFoundation
import Foundation
import Network
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
            return "Speech Recognition permission is needed for voice logging. Enable it in iOS Settings → Buddy."
        case .onDeviceUnavailable(let detail):
            return detail
        case .recognizerUnavailable:
            return "Apple Speech Recognizer is temporarily unavailable. Please try again in a moment."
        case .recognitionFailed(let detail):
            return "Speech recognition failed: \(detail)"
        }
    }
}

/// Summary of Apple Speech readiness for the selected locale option and recognition mode.
public struct AppleSpeechAvailability: Equatable, Sendable {
    public let isReady: Bool
    public let activeLocaleIdentifier: String?
    public let activeLocaleDisplayName: String?
    public let usedFallbackFromDeviceLocale: Bool
    public let statusMessage: String
    public let supportsOfflineFallback: Bool

    public init(
        isReady: Bool,
        activeLocaleIdentifier: String?,
        activeLocaleDisplayName: String?,
        usedFallbackFromDeviceLocale: Bool,
        statusMessage: String,
        supportsOfflineFallback: Bool = false
    ) {
        self.isReady = isReady
        self.activeLocaleIdentifier = activeLocaleIdentifier
        self.activeLocaleDisplayName = activeLocaleDisplayName
        self.usedFallbackFromDeviceLocale = usedFallbackFromDeviceLocale
        self.statusMessage = statusMessage
        self.supportsOfflineFallback = supportsOfflineFallback
    }
}

/// Lightweight, lock-protected network monitor used in `.hybridAuto` mode so Buddy immediately
/// switches to on-device Apple Speech when the gym has no signal instead of waiting for a timeout.
private final class NetworkReachabilityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.yuvaraja.buddy.speech.network", qos: .utility)
    private let lock = NSLock()
    private var reachable: Bool = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.reachable = (path.status == .satisfied)
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var isReachable: Bool {
        lock.lock()
        let current = reachable
        lock.unlock()
        return current
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
    /// `true` while the active recognition session is using Apple's Cloud-Enhanced model.
    public var isUsingCloudEnhancedSpeech: Bool = false

    private let activeRequestBox = LockedSpeechRequestBox()
    private let networkMonitor = NetworkReachabilityMonitor()
    @ObservationIgnored private var activeRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var activeTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private var activeLocaleOption: AppleSpeechLocaleOption = .auto
    @ObservationIgnored private var activeRecognitionMode: AppleSpeechRecognitionMode = .hybridAuto
    @ObservationIgnored private var activeSessionForcedOnDevice: Bool = false
    @ObservationIgnored private var activeContextualStrings: [String] = []
    @ObservationIgnored private var activeParserContext: ActiveSessionPromptContext = ActiveSessionPromptContext()
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

    /// Returns `true` when Speech Recognition is not denied/restricted AND a recognizer is ready
    /// for the selected locale and recognition mode.
    public func isReadyForVoice(
        for option: AppleSpeechLocaleOption,
        mode: AppleSpeechRecognitionMode = .hybridAuto
    ) -> Bool {
        let status = authorizationStatus
        guard status != .denied && status != .restricted else {
            return false
        }
        return checkAvailability(for: option, mode: mode).isReady
    }

    /// Returns `true` only when Speech Recognition is not denied/restricted AND an on-device
    /// offline recognizer is installed for the chosen locale option.
    public func isReadyForOfflineVoice(for option: AppleSpeechLocaleOption) -> Bool {
        isReadyForVoice(for: option, mode: .offlineOnly)
    }

    /// Evaluates whether Apple Speech is available for the chosen locale option and recognition mode.
    /// In `.hybridAuto`, uses Apple's stronger cloud-assisted speech model whenever online and
    /// automatically falls back to on-device dictation when offline.
    public func checkAvailability(
        for option: AppleSpeechLocaleOption,
        mode: AppleSpeechRecognitionMode = .hybridAuto
    ) -> AppleSpeechAvailability {
        let isOnline = networkMonitor.isReachable
        let resolved = resolveRecognizer(for: option, mode: mode, isOnline: isOnline)
        if let recognizer = resolved.recognizer {
            let identifier = recognizer.locale.identifier
            let displayName = Self.localizedDisplayName(for: recognizer.locale)
            let hasOffline = recognizer.supportsOnDeviceRecognition

            if mode == .offlineOnly {
                if resolved.usedFallback {
                    let deviceName = Self.localizedDisplayName(for: Locale.current)
                    return AppleSpeechAvailability(
                        isReady: true,
                        activeLocaleIdentifier: identifier,
                        activeLocaleDisplayName: displayName,
                        usedFallbackFromDeviceLocale: true,
                        statusMessage: "Using \(displayName) offline. For \(deviceName), enable it in iOS Settings → General → Keyboard → Dictation Languages.",
                        supportsOfflineFallback: true
                    )
                }
                return AppleSpeechAvailability(
                    isReady: true,
                    activeLocaleIdentifier: identifier,
                    activeLocaleDisplayName: displayName,
                    usedFallbackFromDeviceLocale: false,
                    statusMessage: "On-Device Offline Ready · \(displayName)",
                    supportsOfflineFallback: true
                )
            }

            // `.hybridAuto` status copy
            let statusMessage: String
            if isOnline && hasOffline {
                statusMessage = "Cloud-Enhanced + Offline Fallback · \(displayName)"
            } else if isOnline {
                statusMessage = "Cloud-Enhanced Ready · \(displayName) (add Dictation pack in iOS Settings for offline fallback)"
            } else {
                statusMessage = "Offline Fallback Ready · \(displayName)"
            }

            return AppleSpeechAvailability(
                isReady: true,
                activeLocaleIdentifier: identifier,
                activeLocaleDisplayName: displayName,
                usedFallbackFromDeviceLocale: resolved.usedFallback,
                statusMessage: statusMessage,
                supportsOfflineFallback: hasOffline
            )
        }

        return AppleSpeechAvailability(
            isReady: false,
            activeLocaleIdentifier: nil,
            activeLocaleDisplayName: nil,
            usedFallbackFromDeviceLocale: false,
            statusMessage: unavailableMessage(for: option, mode: mode),
            supportsOfflineFallback: false
        )
    }

    public func unavailableMessage(
        for option: AppleSpeechLocaleOption,
        mode: AppleSpeechRecognitionMode = .offlineOnly
    ) -> String {
        if mode == .hybridAuto && !networkMonitor.isReachable {
            return "You're offline and \(option.displayName) offline dictation isn't downloaded yet. Add it in iOS Settings → General → Keyboard → Dictation Languages."
        }
        switch option {
        case .auto:
            return "Apple Dictation isn't enabled on this iPhone yet. Turn on Dictation in iOS Settings → General → Keyboard."
        case .enIN, .enUS, .enGB, .enAU, .enCA:
            return "Offline dictation for \(option.displayName) isn't downloaded yet. Add it in iOS Settings → General → Keyboard → Dictation Languages, or pick Auto / English (US)."
        }
    }

    /// Starts a streaming Apple Speech recognition session primed with Buddy's gym exercise vocabulary
    /// and workout-aware N-best hypothesis reranking.
    public func startStreaming(
        localeOption: AppleSpeechLocaleOption,
        recognitionMode: AppleSpeechRecognitionMode = .hybridAuto,
        contextualStrings: [String],
        parserContext: ActiveSessionPromptContext = ActiveSessionPromptContext(),
        onPartialTranscript: @escaping @MainActor (String) -> Void
    ) throws {
        cancelStreaming()

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AppleSpeechError.permissionDenied
        }

        let isOnline = networkMonitor.isReachable
        let resolved = resolveRecognizer(for: localeOption, mode: recognitionMode, isOnline: isOnline)
        guard let recognizer = resolved.recognizer else {
            throw AppleSpeechError.onDeviceUnavailable(unavailableMessage(for: localeOption, mode: recognitionMode))
        }
        guard recognizer.isAvailable || (recognitionMode == .offlineOnly && recognizer.supportsOnDeviceRecognition) else {
            throw AppleSpeechError.recognizerUnavailable
        }

        activeRecognizer = recognizer
        activeLocaleOption = localeOption
        activeRecognitionMode = recognitionMode
        activeSessionForcedOnDevice = false
        activeContextualStrings = contextualStrings
        activeParserContext = parserContext
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
        activeSessionForcedOnDevice = false
        committedSegments = []
        currentSegmentTranscript = ""
        didReceiveFinalResult = false
        rolloverCount = 0
        pendingFatalError = nil
        isListening = false
        isUsingCloudEnhancedSpeech = false
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

    /// Detects when Apple's recognizer resets `bestTranscription.formattedString` to a
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

    private nonisolated static let rawGymKeywords: Set<String> = [
        "set", "sets", "rep", "reps", "kg", "kgs", "kilo", "kilos", "kilogram", "kilograms",
        "lb", "lbs", "pound", "pounds", "bodyweight", "warmup", "dropset", "failure",
        "second", "seconds", "minute", "minutes", "rdl", "ohp", "dumbbell", "barbell", "cable"
    ]

    /// Reranks Apple Speech's N-best alternative hypotheses (`result.transcriptions`) using Buddy's
    /// workout domain so noisy-gym homophones (e.g. `"bench price 60 kg 3 sex 10 wraps"` vs
    /// `"bench press 60 kg 3 sets 10 reps"`, or `"black spot"` vs `"hack squat"`) pick the
    /// workout-valid transcription while preserving Apple's top acoustic choice on ties.
    public nonisolated static func selectBestGymTranscription(
        candidates: [String],
        context: ActiveSessionPromptContext = ActiveSessionPromptContext()
    ) -> String {
        var unique: [String] = []
        var seen = Set<String>()
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                unique.append(trimmed)
            }
        }

        guard let first = unique.first else { return "" }
        if unique.count == 1 { return first }

        let recentLower = Set(context.recentExercisesInSession.map { $0.lowercased() })
        let lastLower = context.lastExerciseName?.lowercased()

        var bestCandidate = first
        var bestScore = Int.min

        for (index, candidate) in unique.enumerated() {
            // Small conservative tie-breaker favoring Apple's top acoustic hypothesis (`bestTranscription`).
            var score = (index == 0 ? 2 : 0)
            let lowered = candidate.lowercased()
            let tokens = Set(
                lowered
                    .split { !($0.isLetter || $0.isNumber) }
                    .map(String.init)
            )

            // Reward clean, uncorrupted workout vocabulary present in the raw transcript.
            let matchedKeywords = tokens.intersection(rawGymKeywords).count
            score += min(8, matchedKeywords * 2)

            let intent = RuleBasedWorkoutParser.parse(candidate, context: context)
            if intent.action != .unknown {
                score += 10
                if intent.action == .logSets {
                    for item in intent.items {
                        let isKnown = ExerciseCatalog.isKnownExercise(item.exerciseName)
                        if isKnown {
                            score += 12
                            // Extra boost when the raw text itself contains the exercise name cleanly
                            // (prefers "bench press" over repaired "bench price").
                            let canonicalLower = item.exerciseName.lowercased()
                            if lowered.contains(canonicalLower) {
                                score += 4
                            }
                        }
                        let itemLower = item.exerciseName.lowercased()
                        if itemLower == lastLower || recentLower.contains(itemLower) {
                            score += 5
                        }
                        if item.weightValue != nil {
                            score += 3
                        }
                        if item.reps != nil || item.durationSeconds != nil {
                            score += 3
                        }
                        if item.setCount > 1 {
                            score += 1
                        }
                    }
                } else {
                    score += 8
                }
            } else {
                // Partial in-progress utterance (e.g. "bench press" vs "bench price" before numbers arrive).
                if ExerciseCatalog.isKnownExercise(candidate) {
                    score += 8
                }
                if recentLower.contains(lowered) || lowered == lastLower {
                    score += 5
                }
            }

            if score > bestScore {
                bestScore = score
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    /// Builds a prioritized list of gym phrases and canonical exercise names to bias Apple's
    /// acoustic/language decoder toward workout logging terms.
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

        let useOnDevice: Bool
        switch activeRecognitionMode {
        case .offlineOnly:
            useOnDevice = true
        case .hybridAuto:
            if activeSessionForcedOnDevice && recognizer.supportsOnDeviceRecognition {
                useOnDevice = true
            } else if !networkMonitor.isReachable && recognizer.supportsOnDeviceRecognition {
                useOnDevice = true
            } else {
                useOnDevice = false
            }
        }

        request.requiresOnDeviceRecognition = useOnDevice
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = activeContextualStrings
        isUsingCloudEnhancedSpeech = !useOnDevice

        let sessionID = UUID()
        activeSessionID = sessionID
        didReceiveFinalResult = false

        // Swap the active request pointer atomically and end any previous request outside the lock.
        let previousRequest = activeRequestBox.swap(request)
        previousRequest?.endAudio()

        activeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let candidates: [String] = result.map { recResult in
                var list: [String] = []
                let best = recResult.bestTranscription.formattedString
                if !best.isEmpty {
                    list.append(best)
                }
                for alt in recResult.transcriptions.prefix(5) {
                    let text = alt.formattedString
                    if !text.isEmpty {
                        list.append(text)
                    }
                }
                return list
            } ?? []
            let isFinal = result?.isFinal ?? false
            let errorInfo: (domain: String, code: Int, description: String)? = error.map {
                let nsError = $0 as NSError
                return (nsError.domain, nsError.code, $0.localizedDescription)
            }

            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == sessionID else { return }

                if !candidates.isEmpty {
                    let chosen = Self.selectBestGymTranscription(
                        candidates: candidates,
                        context: self.activeParserContext
                    )
                    let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if let recognizer = activeRecognizer,
               rolloverCount < Self.maxMidRecordingRollovers {
                if isBenign && (recognizer.isAvailable || recognizer.supportsOnDeviceRecognition) {
                    rolloverCount += 1
                    beginRecognitionTask(on: recognizer)
                    return
                }
                // Automatic mid-recording fallback: if cloud-enhanced speech hits a gym network
                // glitch while still recording, switch seamlessly to Apple On-Device Speech.
                if !isBenign && activeRecognitionMode == .hybridAuto && !activeSessionForcedOnDevice && recognizer.supportsOnDeviceRecognition {
                    activeSessionForcedOnDevice = true
                    rolloverCount += 1
                    beginRecognitionTask(on: recognizer)
                    return
                }
            }

            // Non-benign error or rollover cap reached while still recording: mark task finished
            // so tapping Stop resolves immediately without stalling.
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

    private func isRecognizerSupported(
        _ recognizer: SFSpeechRecognizer,
        mode: AppleSpeechRecognitionMode,
        isOnline: Bool
    ) -> Bool {
        switch mode {
        case .offlineOnly:
            return recognizer.supportsOnDeviceRecognition
        case .hybridAuto:
            return recognizer.supportsOnDeviceRecognition || (isOnline && recognizer.isAvailable)
        }
    }

    private func resolveRecognizer(
        for option: AppleSpeechLocaleOption,
        mode: AppleSpeechRecognitionMode,
        isOnline: Bool
    ) -> (recognizer: SFSpeechRecognizer?, usedFallback: Bool) {
        if let explicit = option.explicitLocale {
            if let recognizer = SFSpeechRecognizer(locale: explicit),
               isRecognizerSupported(recognizer, mode: mode, isOnline: isOnline) {
                return (recognizer, false)
            }
            return (nil, false)
        }

        // `.auto`: prefer the iPhone's current locale when supported for the selected mode.
        if let currentRecognizer = SFSpeechRecognizer(locale: Locale.current),
           isRecognizerSupported(currentRecognizer, mode: mode, isOnline: isOnline) {
            return (currentRecognizer, false)
        }

        // Graceful fallback across common English locales if device region pack isn't installed.
        let fallbackIdentifiers = ["en-IN", "en-US", "en-GB", "en-AU", "en-CA"]
        for identifier in fallbackIdentifiers {
            let locale = Locale(identifier: identifier)
            if let candidate = SFSpeechRecognizer(locale: locale),
               isRecognizerSupported(candidate, mode: mode, isOnline: isOnline) {
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
        activeSessionForcedOnDevice = false
        committedSegments = []
        currentSegmentTranscript = ""
        didReceiveFinalResult = false
        rolloverCount = 0
        pendingFatalError = nil
        isListening = false
        isUsingCloudEnhancedSpeech = false
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
