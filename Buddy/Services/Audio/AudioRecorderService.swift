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

/// Thread-safe bounded raw mono Float32 accumulator segmented by hardware sample rate.
/// When `shouldStoreSamples` is `false` (Apple Speech mode), only duration is tracked so the
/// realtime CoreAudio tap performs zero heap allocations.
private final class LockedRawAudioBuffer: @unchecked Sendable {
    struct Segment: Sendable {
        let sampleRate: Double
        var samples: [Float]
    }

    private let lock = NSLock()
    private var segments: [Segment] = []
    private var accumulatedSeconds: TimeInterval = 0
    private var shouldStoreSamples: Bool = false
    private let maxDurationSeconds: TimeInterval

    init(maxDurationSeconds: TimeInterval) {
        self.maxDurationSeconds = maxDurationSeconds
    }

    func reset(storeSamples: Bool) {
        lock.lock()
        segments.removeAll(keepingCapacity: false)
        accumulatedSeconds = 0
        shouldStoreSamples = storeSamples
        lock.unlock()
    }

    func record(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, sampleRate > 0 else { return }

        lock.lock()
        let remainingSeconds = maxDurationSeconds - accumulatedSeconds
        guard remainingSeconds > 0 else {
            lock.unlock()
            return
        }

        let maxAllowedFrames = Int((remainingSeconds * sampleRate).rounded(.down))
        let countToCopy = min(frameCount, max(0, maxAllowedFrames))
        guard countToCopy > 0 else {
            lock.unlock()
            return
        }

        let store = shouldStoreSamples
        if !store {
            accumulatedSeconds = min(maxDurationSeconds, accumulatedSeconds + (Double(countToCopy) / sampleRate))
            lock.unlock()
            return
        }

        let monoSlice = Self.extractMonoFloatSamples(from: buffer, maxFrames: countToCopy)
        if !monoSlice.isEmpty {
            if let lastIndex = segments.indices.last,
               abs(segments[lastIndex].sampleRate - sampleRate) < 1.0 {
                segments[lastIndex].samples.append(contentsOf: monoSlice)
            } else {
                var initial: [Float] = []
                initial.reserveCapacity(max(Int(sampleRate * 4), monoSlice.count))
                initial.append(contentsOf: monoSlice)
                segments.append(Segment(sampleRate: sampleRate, samples: initial))
            }
        }

        accumulatedSeconds = min(maxDurationSeconds, accumulatedSeconds + (Double(countToCopy) / sampleRate))
        lock.unlock()
    }

    var totalSeconds: TimeInterval {
        lock.lock()
        let duration = accumulatedSeconds
        lock.unlock()
        return duration
    }

    func drain() -> (duration: TimeInterval, segments: [Segment]) {
        lock.lock()
        let duration = accumulatedSeconds
        let capturedSegments = segments
        segments.removeAll(keepingCapacity: false)
        accumulatedSeconds = 0
        shouldStoreSamples = false
        lock.unlock()
        return (duration, capturedSegments)
    }

    private static func extractMonoFloatSamples(from buffer: AVAudioPCMBuffer, maxFrames: Int) -> [Float] {
        let channelCount = Int(buffer.format.channelCount)
        guard maxFrames > 0, channelCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: maxFrames)
        let invChannels = 1.0 / Float(channelCount)

        if let floatChannels = buffer.floatChannelData {
            if channelCount == 1 {
                let ptr = floatChannels[0]
                for frame in 0..<maxFrames {
                    output[frame] = ptr[frame]
                }
            } else {
                for frame in 0..<maxFrames {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += floatChannels[channel][frame]
                    }
                    output[frame] = sum * invChannels
                }
            }
            return output
        }

        if let int16Channels = buffer.int16ChannelData {
            let scale = 1.0 / (Float(Int16.max) * Float(channelCount))
            for frame in 0..<maxFrames {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += Float(int16Channels[channel][frame])
                }
                output[frame] = sum * scale
            }
            return output
        }

        if let int32Channels = buffer.int32ChannelData {
            let scale = 1.0 / (Float(Int32.max) * Float(channelCount))
            for frame in 0..<maxFrames {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += Float(int32Channels[channel][frame])
                }
                output[frame] = sum * scale
            }
            return output
        }

        return []
    }
}

/// Thread-safe holder for the live PCM buffer listener (consumed by Apple Speech).
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

/// Controls hardware noise suppression and microphone routing for loud gym environments.
public struct AudioCaptureOptions: Equatable, Sendable {
    /// Activates Apple's hardware Voice Processing I/O (`setVoiceProcessingEnabled(true)` + AGC)
    /// to suppress loud gym music, bass, and clanking plates while keeping other audio ducking minimal.
    public var enableVoiceIsolation: Bool
    /// Routes recording to the iPhone's close-talk beamforming microphone while keeping
    /// `.allowBluetoothA2DP` enabled so AirPods continue playing stereo music without HFP downgrade.
    public var preferBuiltInMic: Bool

    public init(enableVoiceIsolation: Bool = true, preferBuiltInMic: Bool = true) {
        self.enableVoiceIsolation = enableVoiceIsolation
        self.preferBuiltInMic = preferBuiltInMic
    }
}

/// Pure representation of the `AVAudioSession` mode & category options selected for a capture profile.
public struct AudioSessionConfiguration: Equatable, @unchecked Sendable {
    public let mode: AVAudioSession.Mode
    public let options: AVAudioSession.CategoryOptions

    public init(mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) {
        self.mode = mode
        self.options = options
    }
}

@Observable
@MainActor
public final class AudioRecorderService {
    /// Target mono sample rate required by OpenAI Whisper / WhisperKit CoreML models.
    public static let targetSampleRate: Double = 16_000
    /// Supports uninterrupted 3-minute full-session post-gym voice recaps.
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
    @ObservationIgnored private var currentCaptureOptions: AudioCaptureOptions = AudioCaptureOptions()
    private let rawAudioBuffer = LockedRawAudioBuffer(maxDurationSeconds: maxRecordingSeconds)
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

    /// Computes the optimal `AVAudioSession` mode and category options for the requested capture profile.
    ///
    /// When `preferBuiltInMic` is enabled, uses `.default` mode + `.allowBluetoothA2DP` (omitting
    /// `.allowBluetooth` HFP) because `.voiceChat` implicitly re-enables Bluetooth HFP call mode.
    /// Noise suppression is still applied at the hardware DSP level via `setVoiceProcessingEnabled(true)`.
    public nonisolated static func sessionConfiguration(
        for options: AudioCaptureOptions
    ) -> AudioSessionConfiguration {
        if options.preferBuiltInMic {
            return AudioSessionConfiguration(
                mode: .default,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
            )
        }

        return AudioSessionConfiguration(
            mode: options.enableVoiceIsolation ? .voiceChat : .default,
            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
    }

    /// Sets or clears the realtime PCM buffer callback forwarded to Apple Speech.
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

    /// Activates `AVAudioSession`, configures gym mic routing & hardware noise isolation,
    /// invokes `onSessionActivated` (so Apple Speech starts *after* the audio session is active
    /// and *before* buffers flow), and starts `AVAudioEngine`.
    /// Set `captureRawSamples = true` when recording for offline WhisperKit transcription.
    public func startRecording(
        options: AudioCaptureOptions = AudioCaptureOptions(),
        captureRawSamples: Bool = false,
        onSessionActivated: (@MainActor () throws -> Void)? = nil
    ) async throws {
        let granted = await requestPermission()
        guard granted else {
            throw AudioRecorderError.permissionDenied
        }

        teardownEngine(deactivateSession: false)
        rawAudioBuffer.reset(storeSamples: captureRawSamples)
        configRecoveryAttempts = 0
        currentCaptureOptions = options

        let session = AVAudioSession.sharedInstance()
        let config = Self.sessionConfiguration(for: options)
        do {
            do {
                try session.setCategory(
                    .playAndRecord,
                    mode: config.mode,
                    options: config.options
                )
            } catch {
                // Fallback to `.default` mode if a specific audio route rejects `.voiceChat`.
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: config.options
                )
            }
            try session.setActive(true, options: [])
            configurePreferredMicrophoneInput(session: session, preferBuiltInMic: options.preferBuiltInMic)
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

    /// Stops recording and returns the captured audio duration in seconds (used by Apple Speech mode).
    public func stopRecording() -> TimeInterval {
        teardownEngine(deactivateSession: true)
        return rawAudioBuffer.drain().duration
    }

    /// Stops recording and resamples captured hardware-rate mono audio to 16 kHz Float32 off-MainActor
    /// for WhisperKit transcription.
    public func stopRecordingAndDrain16kHzSamples() async -> (duration: TimeInterval, samples: [Float]) {
        teardownEngine(deactivateSession: true)
        let drained = rawAudioBuffer.drain()
        guard !drained.segments.isEmpty else {
            return (drained.duration, [])
        }

        let segments = drained.segments
        let samples16k: [Float] = await Task.detached(priority: .userInitiated) {
            var combined: [Float] = []
            for segment in segments {
                let resampled = Self.resampleTo16kHz(
                    samples: segment.samples,
                    fromSampleRate: segment.sampleRate
                )
                combined.append(contentsOf: resampled)
            }
            return combined
        }.value

        return (drained.duration, samples16k)
    }

    public func cancelRecording() {
        teardownEngine(deactivateSession: true)
        rawAudioBuffer.reset(storeSamples: false)
    }

    // MARK: - Single-Pass Offline 16 kHz Resampling

    /// Resamples mono Float32 samples to 16 kHz in ONE continuous `AVAudioConverter` pass
    /// (sequential `.haveData` slices followed by `.endOfStream`) so polyphase FIR filter state
    /// never stalls or glitches at buffer boundaries.
    public nonisolated static func resampleTo16kHz(
        samples: [Float],
        fromSampleRate sourceSampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty, sourceSampleRate > 0 else { return [] }
        if abs(sourceSampleRate - targetSampleRate) < 1.0 {
            return samples
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ),
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return linearResampleFallback(samples: samples, from: sourceSampleRate, to: targetSampleRate)
        }

        let estimatedOutputFrames = Int(ceil(Double(samples.count) * (targetSampleRate / sourceSampleRate))) + 64
        var result: [Float] = []
        result.reserveCapacity(max(estimatedOutputFrames, 64))

        let inputChunkSize = 16_384
        var inputOffset = 0
        let outputChunkCapacity: AVAudioFrameCount = 8_192

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputChunkCapacity
        ) else {
            return linearResampleFallback(samples: samples, from: sourceSampleRate, to: targetSampleRate)
        }

        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?

            let status = converter.convert(to: outputBuffer, error: &conversionError) { requestedFrames, outStatus in
                if inputOffset >= samples.count {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let framesToProvide = min(Int(requestedFrames), min(inputChunkSize, samples.count - inputOffset))
                guard framesToProvide > 0,
                      let chunkBuffer = AVAudioPCMBuffer(
                        pcmFormat: inputFormat,
                        frameCapacity: AVAudioFrameCount(framesToProvide)
                      ),
                      let channelData = chunkBuffer.floatChannelData?[0] else {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                chunkBuffer.frameLength = AVAudioFrameCount(framesToProvide)
                samples.withUnsafeBufferPointer { sourcePtr in
                    if let base = sourcePtr.baseAddress {
                        channelData.update(from: base.advanced(by: inputOffset), count: framesToProvide)
                    }
                }
                inputOffset += framesToProvide
                outStatus.pointee = .haveData
                return chunkBuffer
            }

            if conversionError != nil || status == .error {
                return linearResampleFallback(samples: samples, from: sourceSampleRate, to: targetSampleRate)
            }

            let produced = Int(outputBuffer.frameLength)
            if produced > 0, let outPtr = outputBuffer.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: outPtr, count: produced))
            }

            if status == .endOfStream || produced == 0 {
                break
            }
        }

        return result
    }

    private nonisolated static func linearResampleFallback(
        samples: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        let ratio = sourceRate / targetRate
        let outputCount = max(1, Int((Double(samples.count) / ratio).rounded()))
        var output = [Float](repeating: 0, count: outputCount)
        let lastIndex = samples.count - 1

        for i in 0..<outputCount {
            let srcPos = Double(i) * ratio
            let idx0 = min(lastIndex, Int(srcPos))
            let idx1 = min(lastIndex, idx0 + 1)
            let frac = Float(srcPos - Double(idx0))
            output[i] = samples[idx0] * (1.0 - frac) + samples[idx1] * frac
        }
        return output
    }

    // MARK: - Private Helpers

    private func configurePreferredMicrophoneInput(session: AVAudioSession, preferBuiltInMic: Bool) {
        if preferBuiltInMic {
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMic)
            }
        } else {
            try? session.setPreferredInput(nil)
        }
    }

    private func configureAndStartEngine(_ engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        if currentCaptureOptions.enableVoiceIsolation {
            // Must be enabled BEFORE querying outputFormat(forBus: 0) or installing the tap,
            // because Voice Processing I/O reconfigures the hardware input format (typically mono float32).
            do {
                if !inputNode.isVoiceProcessingEnabled {
                    try inputNode.setVoiceProcessingEnabled(true)
                }
                inputNode.isVoiceProcessingAGCEnabled = true
                // Keep gym music playing on AirPods undisturbed while still suppressing mic noise.
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
            } catch {
                // Gracefully fall back to unprocessed capture on Simulator or unsupported routes.
                if inputNode.isVoiceProcessingEnabled {
                    try? inputNode.setVoiceProcessingEnabled(false)
                }
            }
        } else if inputNode.isVoiceProcessingEnabled {
            try? inputNode.setVoiceProcessingEnabled(false)
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        Self.installRealtimeTap(
            on: inputNode,
            inputFormat: inputFormat,
            rawAudioBuffer: rawAudioBuffer,
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
        let bufferedDuration = rawAudioBuffer.totalSeconds

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
            if engine.inputNode.isVoiceProcessingEnabled {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
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
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredInput(nil)
        try? session.setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    /// Installs the audio tap outside `@MainActor` isolation so CoreAudio's realtime
    /// thread never triggers a main-actor assertion.
    private nonisolated static func installRealtimeTap(
        on inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        rawAudioBuffer: LockedRawAudioBuffer,
        bufferHandler: LockedAudioBufferHandler,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        let hardwareSampleRate = inputFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            bufferHandler.forward(buffer)
            rawAudioBuffer.record(buffer: buffer, sampleRate: hardwareSampleRate)

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
