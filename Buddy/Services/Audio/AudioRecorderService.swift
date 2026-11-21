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

/// Thread-safe bounded sample accumulator for 16 kHz mono Float32 PCM audio.
private final class LockedSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private let maxSampleCount: Int

    init(maxSampleCount: Int) {
        self.maxSampleCount = maxSampleCount
        self.samples.reserveCapacity(16_000 * 10)
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func append(_ newSamples: UnsafeBufferPointer<Float>) {
        guard !newSamples.isEmpty else { return }
        lock.lock()
        let remaining = maxSampleCount - samples.count
        if remaining > 0 {
            let countToCopy = min(remaining, newSamples.count)
            samples.append(contentsOf: newSamples.prefix(countToCopy))
        }
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        let copy = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        return copy
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

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    private let sampleBuffer = LockedSampleBuffer(
        maxSampleCount: Int(targetSampleRate * maxRecordingSeconds)
    )
    @ObservationIgnored private var recordingStartDate: Date?
    @ObservationIgnored private var durationTask: Task<Void, Never>?

    public init() {
        refreshPermissionStatus()
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

    public func startRecording() async throws {
        let granted = await requestPermission()
        guard granted else {
            throw AudioRecorderError.permissionDenied
        }

        // Clean up any stale engine session before starting a fresh capture.
        teardownEngine(deactivateSession: false)
        sampleBuffer.reset()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true, options: [])
        } catch {
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            deactivateAudioSession()
            throw AudioRecorderError.invalidInputFormat
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            deactivateAudioSession()
            throw AudioRecorderError.converterCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            deactivateAudioSession()
            throw AudioRecorderError.converterCreationFailed
        }

        Self.installRealtimeTap(
            on: inputNode,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            converter: converter,
            sampleBuffer: sampleBuffer
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
            deactivateAudioSession()
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }

        audioEngine = engine
        isRecording = true
        recordingDuration = 0
        recordingStartDate = Date()
        audioLevels = Array(repeating: 0.05, count: Self.visualizerBarCount)
        startDurationTimer()
    }

    public func stopRecording() -> [Float] {
        teardownEngine(deactivateSession: true)
        return sampleBuffer.drain()
    }

    public func cancelRecording() {
        teardownEngine(deactivateSession: true)
        sampleBuffer.reset()
    }

    // MARK: - Private Helpers

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
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        sampleBuffer: LockedSampleBuffer,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            guard buffer.frameLength > 0 else { return }

            let outputCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 16
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(1, outputCapacity)
            ) else {
                return
            }

            var conversionError: NSError?
            var didProvideInput = false
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error,
                  conversionError == nil,
                  outputBuffer.frameLength > 0,
                  let channelPointer = outputBuffer.floatChannelData?[0] else {
                return
            }

            let frameCount = Int(outputBuffer.frameLength)
            let samples = UnsafeBufferPointer(start: channelPointer, count: frameCount)
            sampleBuffer.append(samples)

            var sumSquares: Float = 0
            for sample in samples {
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Float(max(1, frameCount)))
            let decibels = 20 * log10(max(rms, 1e-5))
            // Map typical gym speech range (-52 dB to -8 dB) into [0.05, 1.0].
            let normalized = min(1.0, max(0.05, (decibels + 52.0) / 44.0))
            onLevel(normalized)
        }
    }
}
