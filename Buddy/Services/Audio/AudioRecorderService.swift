import AVFoundation
import Foundation
import Observation

public enum AudioRecorderError: LocalizedError, Sendable {
    case permissionDenied
    case invalidInputFormat
    case converterCreationFailed
    case engineStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission was denied. Enable Microphone access for Buddy in Settings."
        case .invalidInputFormat:
            return "Could not read audio from the device microphone."
        case .converterCreationFailed:
            return "Could not configure the 16 kHz offline audio converter."
        case .engineStartFailed(let detail):
            return "Could not start audio recording: \(detail)"
        }
    }
}

/// Thread-safe bounded raw mono Float32 accumulator segmented by hardware sample rate.
/// Storing raw hardware-rate samples during capture avoids calling stateful `AVAudioConverter`
/// with `.noDataNow` on every 42ms realtime tap chunk (which introduces polyphase FIR glitches).
/// When `shouldStoreSamples` is false (Apple On-Device Speech streaming mode), only duration
/// is tracked so the realtime audio tap allocates zero heap memory.
private final class LockedRawAudioBuffer: @unchecked Sendable {
    struct Segment {
        let sampleRate: Double
        var samples: [Float]
    }

    private let lock = NSLock()
    private var segments: [Segment] = []
    private var accumulatedDurationSeconds: TimeInterval = 0
    private var shouldStoreSamples: Bool = true
    private let maxDurationSeconds: TimeInterval

    init(maxDurationSeconds: TimeInterval) {
        self.maxDurationSeconds = maxDurationSeconds
    }

    func reset(storeSamples: Bool) {
        lock.lock()
        segments.removeAll(keepingCapacity: false)
        accumulatedDurationSeconds = 0
        shouldStoreSamples = storeSamples
        lock.unlock()
    }

    var storesSamples: Bool {
        lock.lock()
        let flag = shouldStoreSamples
        lock.unlock()
        return flag
    }

    func recordDuration(frameCount: Int, sampleRate: Double) {
        guard frameCount > 0, sampleRate > 0 else { return }
        lock.lock()
        accumulatedDurationSeconds = min(
            maxDurationSeconds,
            accumulatedDurationSeconds + (Double(frameCount) / sampleRate)
        )
        lock.unlock()
    }

    func append(_ newSamples: [Float], sampleRate: Double) {
        guard !newSamples.isEmpty, sampleRate > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        let remainingSeconds = maxDurationSeconds - accumulatedDurationSeconds
        guard remainingSeconds > 0 else { return }

        let maxAllowedFrames = Int(ceil(remainingSeconds * sampleRate))
        let countToCopy = min(newSamples.count, maxAllowedFrames)
        guard countToCopy > 0 else { return }

        if shouldStoreSamples {
            let slice = countToCopy == newSamples.count ? newSamples : Array(newSamples.prefix(countToCopy))
            if let lastIndex = segments.indices.last,
               abs(segments[lastIndex].sampleRate - sampleRate) < 1.0 {
                segments[lastIndex].samples.append(contentsOf: slice)
            } else {
                var initial: [Float] = []
                initial.reserveCapacity(max(Int(sampleRate * 5), slice.count))
                initial.append(contentsOf: slice)
                segments.append(Segment(sampleRate: sampleRate, samples: initial))
            }
        }

        accumulatedDurationSeconds += Double(countToCopy) / sampleRate
    }

    var totalDurationSeconds: TimeInterval {
        lock.lock()
        let duration = accumulatedDurationSeconds
        lock.unlock()
        return duration
    }

    func drain() -> (segments: [Segment], duration: TimeInterval) {
        lock.lock()
        let copiedSegments = segments
        let duration = accumulatedDurationSeconds
        segments.removeAll(keepingCapacity: false)
        accumulatedDurationSeconds = 0
        lock.unlock()
        return (copiedSegments, duration)
    }
}

/// Thread-safe holder for an optional live PCM buffer listener (used by Apple On-Device Speech).
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
    public static let targetSampleRate: Double = 16_000
    public static let maxRecordingSeconds: TimeInterval = 60
    private static let visualizerBarCount: Int = 28

    public var isRecording: Bool = false
    public var audioLevels: [Float] = Array(repeating: 0.05, count: visualizerBarCount)
    public var recordingDuration: TimeInterval = 0
    public var permissionDenied: Bool = false

    @ObservationIgnored public var onMaxDurationReached: (@MainActor () -> Void)?
    @ObservationIgnored public var onAudioInterrupted: (@MainActor (String) -> Void)?
    /// Invoked after the old audio tap is removed and the engine is stopped during an AirPods /
    /// Bluetooth route reconfiguration, before the new hardware-format tap is installed.
    @ObservationIgnored public var onEngineRestarted: (@MainActor () throws -> Void)?

    @ObservationIgnored private var audioEngine: AVAudioEngine?
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

    /// Sets or clears a realtime audio buffer callback used for live streaming speech recognition.
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

    /// Activates `AVAudioSession`, invokes `onSessionActivated` (so streaming speech recognizers
    /// start *after* the audio session is active and *before* buffers flow), and starts `AVAudioEngine`.
    /// Set `captureRawSamples = false` when streaming directly to Apple Speech to avoid allocating
    /// up to 60s of redundant 48 kHz samples on the realtime audio thread.
    public func startRecording(
        captureRawSamples: Bool = true,
        onSessionActivated: (@MainActor () throws -> Void)? = nil
    ) async throws {
        let granted = await requestPermission()
        guard granted else {
            throw AudioRecorderError.permissionDenied
        }

        // Clean up any stale engine session before starting a fresh capture.
        teardownEngine(deactivateSession: false)
        rawAudioBuffer.reset(storeSamples: captureRawSamples)
        configRecoveryAttempts = 0

        let session = AVAudioSession.sharedInstance()
        do {
            // Use `.default` mode (not `.measurement`) so iOS enables hardware mic AGC,
            // directional beamforming, and voice front-end conditioning — matching WhisperKit's
            // own AudioProcessor and Apple Speech best practices.
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
        audioLevels = Array(repeating: 0.05, count: Self.visualizerBarCount)
        startDurationTimer()
    }

    /// Stops recording and returns clean, single-pass resampled and gently normalized
    /// 16 kHz mono Float32 PCM audio ready for WhisperKit.
    public func stopRecording() -> [Float] {
        teardownEngine(deactivateSession: true)
        let (segments, _) = rawAudioBuffer.drain()
        guard !segments.isEmpty else { return [] }

        var combined16k: [Float] = []
        for segment in segments {
            let resampled = Self.resampleTo16kHz(
                samples: segment.samples,
                fromSampleRate: segment.sampleRate
            )
            combined16k.append(contentsOf: resampled)
        }

        return Self.normalizeSpeechAudio(combined16k)
    }

    /// Stops recording and returns the captured audio duration without running 16 kHz resampling.
    /// Used when live streaming buffers were already consumed by Apple On-Device Speech.
    public func stopRecordingDurationOnly() -> TimeInterval {
        teardownEngine(deactivateSession: true)
        let (_, duration) = rawAudioBuffer.drain()
        return duration
    }

    public func cancelRecording() {
        teardownEngine(deactivateSession: true)
        rawAudioBuffer.reset(storeSamples: false)
    }

    // MARK: - Single-Pass Offline Audio Resampling & Conditioning

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
            return linearResampleTo16kHz(samples: samples, fromSampleRate: sourceSampleRate)
        }

        let ratio = targetSampleRate / sourceSampleRate
        let expectedOutputCount = max(1, Int(ceil(Double(samples.count) * ratio)) + 64)
        var outputSamples: [Float] = []
        outputSamples.reserveCapacity(expectedOutputCount)

        let feedChunkSize = 8_192
        let outputChunkCapacity: AVAudioFrameCount = 32_768
        guard let feedBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(feedChunkSize)),
              let feedChannel = feedBuffer.floatChannelData?[0],
              let outputChunk = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputChunkCapacity) else {
            return linearResampleTo16kHz(samples: samples, fromSampleRate: sourceSampleRate)
        }

        var inputOffset = 0
        var conversionError: NSError?

        samples.withUnsafeBufferPointer { src in
            guard let baseAddress = src.baseAddress else { return }

            while true {
                outputChunk.frameLength = 0
                let status = converter.convert(to: outputChunk, error: &conversionError) { inNumberOfPackets, outStatus in
                    let remaining = samples.count - inputOffset
                    guard remaining > 0 else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    let requested = max(1, Int(inNumberOfPackets))
                    let framesToCopy = min(remaining, min(feedChunkSize, requested))
                    feedChannel.update(from: baseAddress.advanced(by: inputOffset), count: framesToCopy)
                    feedBuffer.frameLength = AVAudioFrameCount(framesToCopy)
                    inputOffset += framesToCopy
                    outStatus.pointee = .haveData
                    return feedBuffer
                }

                if let outChannel = outputChunk.floatChannelData?[0], outputChunk.frameLength > 0 {
                    let produced = Int(outputChunk.frameLength)
                    outputSamples.append(contentsOf: UnsafeBufferPointer(start: outChannel, count: produced))
                }

                if status == .endOfStream || status == .error || conversionError != nil {
                    break
                }
                if status == .inputRanDry || outputChunk.frameLength == 0 {
                    break
                }
            }
        }

        if conversionError != nil || outputSamples.isEmpty {
            return linearResampleTo16kHz(samples: samples, fromSampleRate: sourceSampleRate)
        }

        return outputSamples
    }

    /// Removes DC offset and gently normalizes quiet speech toward a 0.75 level (clamped to
    /// `1.0x...6.0x` gain) using a 99th-percentile magnitude over the interior window so short
    /// button tap/release mic thumps never suppress or attenuate spoken words, while leaving
    /// near-silent noise floors unboosted.
    public nonisolated static func normalizeSpeechAudio(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        var sum: Double = 0
        for sample in samples where sample.isFinite {
            sum += Double(sample)
        }
        let mean = Float(sum / Double(samples.count))

        var centered = [Float](repeating: 0, count: samples.count)
        for index in 0..<samples.count {
            let raw = samples[index]
            centered[index] = raw.isFinite ? (raw - mean) : 0
        }

        // Exclude ~30ms at the start and end (480 samples at 16 kHz) when measuring speech level
        // so mechanical finger tap/release spikes next to the bottom iPhone mic don't skew gain.
        let edgeTrim = centered.count > 2_400 ? 480 : 0
        let measureStart = edgeTrim
        let measureEnd = centered.count - edgeTrim
        let measureCount = max(1, measureEnd - measureStart)

        var sumSquares: Double = 0
        // Stride-sample up to ~4096 points across the measurement window for fast O(N) percentile.
        let strideStep = max(1, measureCount / 4_096)
        var sampledMagnitudes: [Float] = []
        sampledMagnitudes.reserveCapacity((measureCount / strideStep) + 1)

        var index = measureStart
        while index < measureEnd {
            let value = centered[index]
            let magnitude = abs(value)
            sumSquares += Double(value) * Double(value)
            if (index - measureStart) % strideStep == 0 {
                sampledMagnitudes.append(magnitude)
            }
            index += 1
        }

        let rms = Float(sqrt(sumSquares / Double(measureCount)))
        sampledMagnitudes.sort()
        let p99Index = min(sampledMagnitudes.count - 1, Int(Double(sampledMagnitudes.count - 1) * 0.99))
        let robustLevel = sampledMagnitudes.isEmpty ? Float(0) : sampledMagnitudes[p99Index]

        // Only boost when real speech energy exceeds the room noise floor.
        guard robustLevel > 0.008, rms > 0.0015 else {
            return centered
        }

        let targetLevel: Float = 0.75
        // Never attenuate quiet speech (gain >= 1.0), and cap boost at 6x to avoid raising hiss.
        let gain = min(6.0, max(1.0, targetLevel / robustLevel))
        guard gain > 1.05 else {
            return centered
        }

        for i in 0..<centered.count {
            centered[i] = max(-0.98, min(0.98, centered[i] * gain))
        }
        return centered
    }

    private nonisolated static func linearResampleTo16kHz(
        samples: [Float],
        fromSampleRate sourceSampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty, sourceSampleRate > 0 else { return [] }
        let ratio = sourceSampleRate / targetSampleRate
        let outputLength = max(1, Int(Double(samples.count) / ratio))
        var result = [Float](repeating: 0, count: outputLength)

        for i in 0..<outputLength {
            let srcPosition = Double(i) * ratio
            let lowIndex = min(samples.count - 1, Int(srcPosition))
            let highIndex = min(samples.count - 1, lowIndex + 1)
            let frac = Float(srcPosition - Double(lowIndex))
            result[i] = samples[lowIndex] * (1.0 - frac) + samples[highIndex] * frac
        }
        return result
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
        let bufferedDuration = rawAudioBuffer.totalDurationSeconds

        // AirPods / Bluetooth headsets negotiate A2DP -> HFP ~50–250ms after engine.start().
        // Re-install the tap on the new hardware format instead of aborting as "too short".
        if configRecoveryAttempts < 2 && (elapsed < 1.0 || bufferedDuration < 0.3) {
            configRecoveryAttempts += 1
            // Remove the old bus-0 tap and stop the engine FIRST so no trailing buffer in the old
            // format (e.g. 48 kHz) can reach the fresh SFSpeechAudioBufferRecognitionRequest and
            // cause an NSInvalidArgumentException when the new 16/24 kHz HFP buffers arrive.
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
        let clamped = min(1.0, max(0.05, rawLevel))
        let previous = audioLevels.last ?? 0.05
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
        audioLevels = Array(repeating: 0.05, count: Self.visualizerBarCount)

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
    /// thread never triggers a main-actor executor assertion.
    private nonisolated static func installRealtimeTap(
        on inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        rawAudioBuffer: LockedRawAudioBuffer,
        bufferHandler: LockedAudioBufferHandler,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        let hardwareSampleRate = inputFormat.sampleRate
        let shouldStoreSamples = rawAudioBuffer.storesSamples

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            // Forward hardware PCM buffer directly to Apple On-Device Speech when active.
            bufferHandler.forward(buffer)

            let rms: Float
            if shouldStoreSamples {
                let monoSamples = extractMonoFloatSamples(from: buffer)
                guard !monoSamples.isEmpty else { return }
                rawAudioBuffer.append(monoSamples, sampleRate: hardwareSampleRate)

                var sumSquares: Float = 0
                for sample in monoSamples {
                    sumSquares += sample * sample
                }
                rms = sqrt(sumSquares / Float(max(1, monoSamples.count)))
            } else {
                // Zero-allocation path for Apple On-Device Speech streaming: track duration and
                // compute RMS in-place directly over the PCM buffer without heap allocations.
                rawAudioBuffer.recordDuration(frameCount: frameCount, sampleRate: hardwareSampleRate)
                rms = computeRMSInPlace(from: buffer)
            }

            let decibels = 20 * log10(max(rms, 1e-5))
            // Map typical gym speech range (-52 dB to -8 dB) into [0.05, 1.0].
            let normalized = min(1.0, max(0.05, (decibels + 52.0) / 44.0))
            onLevel(normalized)
        }
    }

    /// Computes mono RMS directly from an `AVAudioPCMBuffer` without heap allocations.
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

    /// Extracts mono Float32 samples cleanly from any hardware PCM buffer layout.
    private nonisolated static func extractMonoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return [] }

        if let floatChannels = buffer.floatChannelData {
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: floatChannels[0], count: frameCount))
            }
            var mono = [Float](repeating: 0, count: frameCount)
            let scale = 1.0 / Float(channelCount)
            for channel in 0..<channelCount {
                let ptr = floatChannels[channel]
                for frame in 0..<frameCount {
                    mono[frame] += ptr[frame] * scale
                }
            }
            return mono
        }

        if let int16Channels = buffer.int16ChannelData {
            var mono = [Float](repeating: 0, count: frameCount)
            let scale = 1.0 / (Float(Int16.max) * Float(channelCount))
            for channel in 0..<channelCount {
                let ptr = int16Channels[channel]
                for frame in 0..<frameCount {
                    mono[frame] += Float(ptr[frame]) * scale
                }
            }
            return mono
        }

        if let int32Channels = buffer.int32ChannelData {
            var mono = [Float](repeating: 0, count: frameCount)
            let scale = 1.0 / (Float(Int32.max) * Float(channelCount))
            for channel in 0..<channelCount {
                let ptr = int32Channels[channel]
                for frame in 0..<frameCount {
                    mono[frame] += Float(ptr[frame]) * scale
                }
            }
            return mono
        }

        return []
    }
}
