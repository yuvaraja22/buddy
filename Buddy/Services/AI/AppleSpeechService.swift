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
            return "Speech Recognition permission is needed for Apple On-Device voice logging. Enable it in iOS Settings, or switch to WhisperKit in Buddy Settings."
        case .onDeviceUnavailable(let detail):
            return detail
        case .recognizerUnavailable:
            return "Apple On-Device Speech Recognizer is temporarily unavailable. Please try again or switch to WhisperKit in Settings."
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

/// Thread-safe holder for the active `SFSpeechAudioBufferRecognitionRequest` so CoreAudio's
/// realtime tap can append buffers safely without racing against `endAudio()` on MainActor.
private final class LockedSpeechRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = newRequest
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        current?.append(buffer)
        lock.unlock()
    }

    func endAudioAndClear() {
        lock.lock()
        let current = request
        request = nil
        current?.endAudio()
        lock.unlock()
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
    public var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    public var isListening: Bool = false

    private let activeRequestBox = LockedSpeechRequestBox()
    @ObservationIgnored private var activeRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var activeTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private var latestNonEmptyTranscript: String = ""
    @ObservationIgnored private var didReceiveFinalResult: Bool = false
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
            return "Apple On-Device Dictation isn't enabled on this iPhone yet. Turn on Dictation in iOS Settings → General → Keyboard, or switch Speech Engine to WhisperKit in Buddy Settings."
        case .enIN, .enUS, .enGB, .enAU, .enCA:
            return "Offline dictation for \(option.displayName) isn't downloaded yet. Add it in iOS Settings → General → Keyboard → Dictation Languages, pick Auto / English (US), or switch to WhisperKit."
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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = contextualStrings

        let sessionID = UUID()
        activeSessionID = sessionID
        activeRecognizer = recognizer
        latestNonEmptyTranscript = ""
        didReceiveFinalResult = false
        isListening = true
        activeRequestBox.set(request)

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
                        self.latestNonEmptyTranscript = trimmed
                        onPartialTranscript(trimmed)
                    }
                }

                if isFinal {
                    self.didReceiveFinalResult = true
                    self.isListening = false
                    let best = self.latestNonEmptyTranscript
                    self.resolvePendingFinish(with: .success(best))
                    return
                }

                if let errorInfo {
                    self.isListening = false
                    // iOS Speech frequently reports benign stop/cancellation/no-speech errors
                    // (kAFAssistantErrorDomain 203, 209, 216, 1110) even after delivering a valid
                    // partial transcript. Never throw away words we already captured!
                    if !self.latestNonEmptyTranscript.isEmpty {
                        self.resolvePendingFinish(with: .success(self.latestNonEmptyTranscript))
                    } else if Self.isBenignNoSpeechOrCancelError(domain: errorInfo.domain, code: errorInfo.code) {
                        self.resolvePendingFinish(with: .success(""))
                    } else {
                        self.resolvePendingFinish(with: .failure(AppleSpeechError.recognitionFailed(errorInfo.description)))
                    }
                }
            }
        }
    }

    /// Thread-safe audio buffer entry point invoked from CoreAudio's realtime tap.
    public nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        activeRequestBox.append(buffer)
    }

    /// Signals end-of-audio and awaits Apple's final transcription pass (up to `timeoutSeconds`),
    /// always falling back cleanly to the latest captured live partial transcript on timeout.
    public func finishStreaming(timeoutSeconds: TimeInterval = 1.2) async throws -> String {
        activeRequestBox.endAudioAndClear()
        isListening = false

        if didReceiveFinalResult || activeTask == nil {
            let finalText = latestNonEmptyTranscript
            cleanupTaskState()
            return finalText
        }

        let currentSessionID = activeSessionID
        let transcript = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.finishContinuation = continuation
            self.finishTimeoutTask?.cancel()
            self.finishTimeoutTask = Task { @MainActor [weak self] in
                let delayNs = UInt64(max(0.2, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delayNs)
                guard let self, self.activeSessionID == currentSessionID else { return }
                let best = self.latestNonEmptyTranscript
                self.resolvePendingFinish(with: .success(best))
            }
        }

        cleanupTaskState()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancelStreaming() {
        activeSessionID = nil
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
        latestNonEmptyTranscript = ""
        didReceiveFinalResult = false
        isListening = false
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
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        finishContinuation = nil
        activeTask?.cancel()
        activeTask = nil
        activeRecognizer = nil
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
