import AVFoundation
import Foundation
import Observation

public enum AudioRecorderError: LocalizedError, Sendable {
    case permissionDenied
    case invalidInputFormat
    case engineStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission was denied. Enable Microphone access for Buddy in Settings."
        case .invalidInputFormat:
            return "Could not read audio from the device microphone."
        case .engineStartFailed(let detail):
            return "Could not start audio recording: \(detail)"
        }
    }
}

/// Thread-safe duration tracker updated directly on CoreAudio's realtime tap with zero heap allocations.
private final class LockedDurationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulatedSeconds: TimeInterval = 0
    private let maxDurationSeconds: TimeInterval

    init(maxDurationSeconds: TimeInterval) {
        self.maxDurationSeconds = maxDurationSeconds
    }

    func reset() {
        lock.lock()
        accumulatedSeconds = 0
        lock.unlock()
    }

    func record(frameCount: Int, sampleRate: Double) {
        guard frameCount > 0, sampleRate > 0 else { return }
        lock.lock()
        accumulatedSeconds = min(
            maxDurationSeconds,
            accumulatedSeconds + (Double(frameCount) / sampleRate)
        )
        lock.unlock()
    }

    var totalSeconds: TimeInterval {
        lock.lock()
        let duration = accumulatedSeconds
        lock.unlock()
        return duration
    }

    func drain() -> TimeInterval {
        lock.lock()
        let duration = accumulatedSeconds
        accumulatedSeconds = 0
        lock.unlock()
        return duration
    }
}

/// Thread-safe holder for the live PCM buffer listener (consumed by Apple On-Device Speech).
private final class LockedAudioBufferHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func set(_ newHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    func forward(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let activeHandler = handler
        lock.unlock()
        activeHandler?(buffer)
    }
}

private final class AudioNotificationObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(
        name: Notification.Name,
        object: Any?,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        self.token = NotificationCenter.default.addObserver(
            forName: name,
            object: object,
            queue: .main,
            using: handler
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

@Observable
@MainActor
public final class AudioRecorderService {
    /// Supports uninterrupted 3-minute full-session post-gym voice recaps alongside AppleSpeechService rollover.
    public static let maxRecordingSeconds: TimeInterval = 180
    private static let visualizerBarCount: Int = 24

    public var isRecording: Bool = false
    public var audioLevels: [Float] = Array(repeating: 0.08, count: visualizerBarCount)
    public var recordingDuration: TimeInterval = 0
    public var permissionDenied: Bool = false

    @ObservationIgnored public var onMaxDurationReached: (@MainActor () -> Void)?
    @ObservationIgnored public var onAudioInterrupted: (@MainActor (String) -> Void)?
    /// Invoked after the old audio tap is removed and the engine is stopped during an AirPods /
    /// Bluetooth route reconfiguration, before the new hardware-format tap is installed.
    @ObservationIgnored public var onEngineRestarted: (@MainActor () throws -> Void)?

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    private let durationTracker = LockedDurationTracker(maxDurationSeconds: maxRecordingSeconds)
    private let audioBufferHandler = LockedAudioBufferHandler()
    @ObservationIgnored private var recordingStartDate: Date?
    @ObservationIgnored private var durationTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionObserver: AudioNotificationObserverToken?
    @ObservationIgnored private var configChangeObserver: AudioNotificationObserverToken?
    @ObservationIgnored private var configRecoveryAttempts: Int = 0

    public init() {
        refreshPermissionStatus()
        installInterruptionObserver()
    }

    /// Sets or clears the realtime PCM buffer callback forwarded to Apple On-Device Speech.
    public func setAudioBufferHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        audioBufferHandler.set(handler)
    }

    public func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permissionDenied = false
            return true
        case .denied:
            permissionDenied = true
            return false
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            permissionDenied = !granted
            return granted
        @unknown default:
            let granted = await AVAudioApplication.requestRecordPermission()
            permissionDenied = !granted
            return granted
        }
    }

    /// Activates `AVAudioSession`, invokes `onSessionActivated` (so Apple On-Device Speech starts
    /// *after* the audio session is active and *before* buffers flow), and starts `AVAudioEngine`
    /// with a zero-allocation realtime tap.
    public func startRecording(
        onSessionActivated: (@MainActor () throws -> Void)? = nil
    ) async throws {
        let granted = await requestPermission()
        guard granted else {
            throw AudioRecorderError.permissionDenied
        }

        teardownEngine(deactivateSession: false)
        durationTracker.reset()
        configRecoveryAttempts = 0

        let session = AVAudioSession.sharedInstance()
        do {
            // `.default` mode enables iOS hardware mic AGC, directional beamforming, and voice
            // front-end conditioning for clean recognition even in a gym.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true, options: [])
        } catch {
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }

        do {
            try onSessionActivated?()
        } catch {
            deactivateAudioSession()
            throw error
        }

        let engine = AVAudioEngine()
        do {
            try configureAndStartEngine(engine)
        } catch {
            deactivateAudioSession()
            throw error
        }

        audioEngine = engine
        installConfigChangeObserver(for: engine)
        isRecording = true
        recordingDuration = 0
        recordingStartDate = Date()
        audioLevels = Array(repeating: 0.08, count: Self.visualizerBarCount)
        startDurationTimer()
    }

    /// Stops recording and returns the captured audio duration in seconds.
    public func stopRecording() -> TimeInterval {
        teardownEngine(deactivateSession: true)
        return durationTracker.drain()
    }

    public func cancelRecording() {
        teardownEngine(deactivateSession: true)
        durationTracker.reset()
    }

    // MARK: - Private Helpers

    private func configureAndStartEngine(_ engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        Self.installRealtimeTap(
            on: inputNode,
            inputFormat: inputFormat,
            durationTracker: durationTracker,
            bufferHandler: audioBufferHandler
        ) { [weak self] level in
            Task { @MainActor [weak self] in
                self?.appendVisualizerLevel(level)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }
    }

    private func installInterruptionObserver() {
        interruptionObserver = AudioNotificationObserverToken(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                  type == .began else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.cancelRecording()
                self.onAudioInterrupted?("Recording paused due to an audio interruption.")
            }
        }
    }

    private func installConfigChangeObserver(for engine: AVAudioEngine) {
        let expectedEngineID = ObjectIdentifier(engine)
        configChangeObserver = AudioNotificationObserverToken(
            name: .AVAudioEngineConfigurationChange,
            object: engine
        ) { [weak self] notification in
            let postedEngineID = (notification.object as? AVAudioEngine).map(ObjectIdentifier.init)
            guard postedEngineID == expectedEngineID else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.isRecording,
                      let currentEngine = self.audioEngine,
                      ObjectIdentifier(currentEngine) == expectedEngineID else {
                    return
                }
                self.handleEngineConfigurationChange(currentEngine)
            }
        }
    }

    private func handleEngineConfigurationChange(_ engine: AVAudioEngine) {
        let elapsed = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
        let bufferedDuration = durationTracker.totalSeconds

        // AirPods / Bluetooth headsets negotiate A2DP -> HFP ~50–250ms after engine.start().
        // Remove the old bus-0 tap and stop the engine FIRST so no trailing buffer in the old
        // format (e.g. 48 kHz) can reach the fresh SFSpeechAudioBufferRecognitionRequest.
        if configRecoveryAttempts < 2 && (elapsed < 1.0 || bufferedDuration < 0.3) {
            configRecoveryAttempts += 1
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()

            do {
                try onEngineRestarted?()
                try configureAndStartEngine(engine)
                return
            } catch {
                cancelRecording()
                onAudioInterrupted?(error.localizedDescription)
                return
            }
        }

        if bufferedDuration >= 0.15 {
            onMaxDurationReached?()
        } else {
            cancelRecording()
            onAudioInterrupted?("Audio route changed while starting recording. Please tap to try again.")
        }
    }

    private func refreshPermissionStatus() {
        permissionDenied = (AVAudioApplication.shared.recordPermission == .denied)
    }

    private func startDurationTimer() {
        durationTask?.cancel()
        durationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording, let start = self.recordingStartDate else {
                    break
                }
                let elapsed = Date().timeIntervalSince(start)
                self.recordingDuration = min(Self.maxRecordingSeconds, max(0, elapsed))
                if elapsed >= Self.maxRecordingSeconds {
                    self.onMaxDurationReached?()
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func appendVisualizerLevel(_ rawLevel: Float) {
        guard isRecording else { return }
        let clamped = min(1.0, max(0.08, rawLevel))
        let previous = audioLevels.last ?? 0.08
        let smoothed = (previous * 0.35) + (clamped * 0.65)
        if audioLevels.count >= Self.visualizerBarCount {
            audioLevels.removeFirst()
        }
        audioLevels.append(smoothed)
    }

    private func teardownEngine(deactivateSession: Bool) {
        durationTask?.cancel()
        durationTask = nil
        configChangeObserver = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        isRecording = false
        recordingStartDate = nil
        recordingDuration = 0
        audioLevels = Array(repeating: 0.08, count: Self.visualizerBarCount)

        if deactivateSession {
            deactivateAudioSession()
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    /// Installs the audio tap outside `@MainActor` isolation so CoreAudio's realtime
    /// thread performs zero heap allocations and never triggers a main-actor assertion.
    private nonisolated static func installRealtimeTap(
        on inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        durationTracker: LockedDurationTracker,
        bufferHandler: LockedAudioBufferHandler,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        let hardwareSampleRate = inputFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            bufferHandler.forward(buffer)
            durationTracker.record(frameCount: frameCount, sampleRate: hardwareSampleRate)

            let rms = computeRMSInPlace(from: buffer)
            let decibels = 20 * log10(max(rms, 1e-5))
            let normalized = min(1.0, max(0.08, (decibels + 52.0) / 44.0))
            onLevel(normalized)
        }
    }

    /// Computes mono RMS directly over hardware PCM buffers with zero heap allocations.
    private nonisolated static func computeRMSInPlace(from buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var sumSquares: Float = 0
        let invChannels = 1.0 / Float(channelCount)

        if let floatChannels = buffer.floatChannelData {
            if channelCount == 1 {
                let ptr = floatChannels[0]
                for frame in 0..<frameCount {
                    let s = ptr[frame]
                    sumSquares += s * s
                }
            } else {
                for frame in 0..<frameCount {
                    var mixed: Float = 0
                    for channel in 0..<channelCount {
                        mixed += floatChannels[channel][frame]
                    }
                    mixed *= invChannels
                    sumSquares += mixed * mixed
                }
            }
            return sqrt(sumSquares / Float(frameCount))
        }

        if let int16Channels = buffer.int16ChannelData {
            let scale = 1.0 / (Float(Int16.max) * Float(channelCount))
            for frame in 0..<frameCount {
                var mixed: Float = 0
                for channel in 0..<channelCount {
                    mixed += Float(int16Channels[channel][frame])
                }
                mixed *= scale
                sumSquares += mixed * mixed
            }
            return sqrt(sumSquares / Float(frameCount))
        }

        if let int32Channels = buffer.int32ChannelData {
            let scale = 1.0 / (Float(Int32.max) * Float(channelCount))
            for frame in 0..<frameCount {
                var mixed: Float = 0
                for channel in 0..<channelCount {
                    mixed += Float(int32Channels[channel][frame])
                }
                mixed *= scale
                sumSquares += mixed * mixed
            }
            return sqrt(sumSquares / Float(frameCount))
        }

        return 0
    }
}
