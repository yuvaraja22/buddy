import XCTest
@testable import Buddy

final class SpeechAndAudioTests: XCTestCase {
    func testSinglePassResampleTo16kHzPreserves48kHzSineContinuity() {
        let sourceRate: Double = 48_000
        let durationSeconds: Double = 3.0
        let totalSamples = Int(sourceRate * durationSeconds)
        let frequency: Double = 440.0
        let amplitude: Float = 0.5

        let sine48k: [Float] = (0..<totalSamples).map { index in
            let t = Double(index) / sourceRate
            return amplitude * Float(sin(2.0 * Double.pi * frequency * t))
        }

        let resampled = AudioRecorderService.resampleTo16kHz(samples: sine48k, fromSampleRate: sourceRate)

        let expectedCount = Int(AudioRecorderService.targetSampleRate * durationSeconds)
        XCTAssertLessThanOrEqual(abs(resampled.count - expectedCount), 128)
        XCTAssertTrue(resampled.allSatisfy { $0.isFinite })

        // Skip short polyphase filter ramp-in/ramp-out edges and verify steady-state amplitude & smoothness.
        let interior = Array(resampled[256..<(resampled.count - 256)])
        let peak = interior.map(abs).max() ?? 0
        XCTAssertEqual(peak, amplitude, accuracy: 0.06)

        // Expected max adjacent sample step for a 440 Hz, 0.5-amplitude sine at 16 kHz is
        // 2 * pi * 440 / 16000 * 0.5 ~= 0.0864. Any chunk-boundary glitch would spike far above 0.25.
        var maxDelta: Float = 0
        for i in 1..<interior.count {
            let delta = abs(interior[i] - interior[i - 1])
            if delta > maxDelta {
                maxDelta = delta
            }
        }
        XCTAssertLessThan(maxDelta, 0.16, "Resampled 440 Hz sine must remain smooth with zero chunk-boundary glitches")
    }

    func testResampleTo16kHzPassesThroughAlready16kHzSamples() {
        let input: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5]
        let output = AudioRecorderService.resampleTo16kHz(samples: input, fromSampleRate: 16_000)
        XCTAssertEqual(output, input)
    }

    func testNormalizeSpeechAudioBoostsQuietSpeechWithoutAmplifyingSilence() {
        // Quiet spoken signal (~-20 dB peak = 0.10) should be gently lifted toward 0.75 (capped at 6x -> 0.60).
        let quietSine: [Float] = (0..<16_000).map { index in
            0.10 * Float(sin(2.0 * Double.pi * 300.0 * Double(index) / 16_000.0))
        }
        let boosted = AudioRecorderService.normalizeSpeechAudio(quietSine)
        let boostedPeak = boosted.map(abs).max() ?? 0
        XCTAssertEqual(boostedPeak, 0.60, accuracy: 0.03)
        XCTAssertTrue(boosted.allSatisfy { $0.isFinite && abs($0) <= 0.98 })

        // Pure room noise floor (~-55 dB = 0.0015) must NOT be amplified into fake speech/hallucinations.
        let nearSilence: [Float] = (0..<16_000).map { index in
            0.001 * Float(sin(2.0 * Double.pi * 120.0 * Double(index) / 16_000.0))
        }
        let preserved = AudioRecorderService.normalizeSpeechAudio(nearSilence)
        let preservedPeak = preserved.map(abs).max() ?? 0
        XCTAssertLessThan(preservedPeak, 0.005)
    }

    func testGymContextualStringsPrioritizeRecentExercisesAndIncludeCatalog() {
        let phrases = AppleSpeechService.buildGymContextualStrings(
            recentExercises: ["Leg Extension", "Romanian Deadlift", "leg extension"]
        )

        XCTAssertEqual(phrases.first, "Leg Extension")
        XCTAssertTrue(phrases.prefix(3).contains("Romanian Deadlift"))
        XCTAssertTrue(phrases.contains("sets"))
        XCTAssertTrue(phrases.contains("reps"))
        XCTAssertTrue(phrases.contains("kg"))
        XCTAssertTrue(phrases.contains("Bench Press"))
        XCTAssertTrue(phrases.contains("Bulgarian Split Squat"))

        // Case-insensitive deduplication check
        let lowercased = phrases.map { $0.lowercased() }
        XCTAssertEqual(lowercased.count, Set(lowercased).count)
    }

    @MainActor
    func testModelManagerDefaultsToAppleOnDeviceSpeechAndSupportsUpgradedWhisperPresets() throws {
        let suiteName = "com.yuvaraja.buddy.tests.speech.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ModelManager(defaults: defaults)
        XCTAssertEqual(manager.selectedSpeechEngine, .appleOnDevice)
        XCTAssertEqual(manager.selectedAppleSpeechLocale, .auto)
        XCTAssertEqual(manager.selectedWhisperPreset, .largeV3Turbo)
        XCTAssertTrue(manager.isVoiceReady)

        // Verify upgraded WhisperKit presets match verified HuggingFace folder & tokenizer names.
        XCTAssertEqual(WhisperPreset.largeV3Turbo.rawValue, "openai_whisper-large-v3-v20240930_626MB")
        XCTAssertEqual(WhisperPreset.largeV3Turbo.tokenizerRepoName, "openai/whisper-large-v3")
        XCTAssertEqual(WhisperPreset.largeV3Turbo.languageCode, "en")

        XCTAssertEqual(WhisperPreset.small.rawValue, "openai_whisper-small_216MB")
        XCTAssertEqual(WhisperPreset.small.tokenizerRepoName, "openai/whisper-small")
        XCTAssertEqual(WhisperPreset.small.languageCode, "en")

        // Switching to WhisperKit without a downloaded Whisper model flips isVoiceReady to false
        // and persists engine + locale preferences across instances.
        manager.selectedSpeechEngine = .whisperKit
        manager.selectedAppleSpeechLocale = .enIN
        XCTAssertFalse(manager.isVoiceReady)

        let reloaded = ModelManager(defaults: defaults)
        XCTAssertEqual(reloaded.selectedSpeechEngine, .whisperKit)
        XCTAssertEqual(reloaded.selectedAppleSpeechLocale, .enIN)
    }
}
