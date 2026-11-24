import AVFoundation
import SwiftData
import XCTest
@testable import Buddy

final class SpeechAndAudioTests: XCTestCase {
    func testAppleSpeechPauseResetDetectionAndSegmentMerging() {
        // Post-pause reset: recognizer dropped "leg extension 3 sets" and restarted with "15 reps"
        XCTAssertTrue(
            AppleSpeechService.didResetAfterPause(
                previous: "leg extension 3 sets",
                updated: "15 reps"
            )
        )

        // Normal in-place word refinements must NOT trigger false segment splits
        XCTAssertFalse(
            AppleSpeechService.didResetAfterPause(
                previous: "dead lift 100 kg",
                updated: "deadlift 100 kg"
            )
        )
        XCTAssertFalse(
            AppleSpeechService.didResetAfterPause(
                previous: "bench press",
                updated: "bench press 60 kg"
            )
        )

        let merged = AppleSpeechService.mergeTranscriptSegments(
            committed: ["Leg extension 3 sets", "  "],
            current: "15 reps"
        )
        XCTAssertEqual(merged, "Leg extension 3 sets 15 reps")
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

        let lowercased = phrases.map { $0.lowercased() }
        XCTAssertEqual(lowercased.count, Set(lowercased).count)
    }

    func testMuscleGroupThumbnailAssetMappingCoversEveryGroup() {
        let validAssets: Set<String> = [
            "WorkoutThumbLegs",
            "WorkoutThumbChest",
            "WorkoutThumbBack",
            "WorkoutThumbShoulders",
            "WorkoutThumbArms",
            "WorkoutThumbCore",
            "WorkoutThumbFullBody"
        ]

        for group in MuscleGroup.allCases {
            XCTAssertTrue(
                validAssets.contains(group.thumbnailAssetName),
                "Unexpected thumbnail asset '\(group.thumbnailAssetName)' for \(group)"
            )
        }
        XCTAssertEqual(MuscleGroup.quads.thumbnailAssetName, "WorkoutThumbLegs")
        XCTAssertEqual(MuscleGroup.chest.thumbnailAssetName, "WorkoutThumbChest")
        XCTAssertEqual(MuscleGroup.back.thumbnailAssetName, "WorkoutThumbBack")
        XCTAssertEqual(MuscleGroup.biceps.thumbnailAssetName, "WorkoutThumbArms")
    }

    func testBuddyAppearanceColorSchemeAndUIUserInterfaceStyleMapping() {
        XCTAssertEqual(BuddyAppearance.dark.colorScheme, .dark)
        XCTAssertEqual(BuddyAppearance.light.colorScheme, .light)
        XCTAssertNil(BuddyAppearance.system.colorScheme)

        XCTAssertEqual(BuddyAppearance.dark.uiUserInterfaceStyle, .dark)
        XCTAssertEqual(BuddyAppearance.light.uiUserInterfaceStyle, .light)
        XCTAssertEqual(BuddyAppearance.system.uiUserInterfaceStyle, .unspecified)
    }

    func testWeightUnitFormatWeightNumberAvoidsIEEE754LbsDrift() {
        // 205 lbs round-tripped through kg produces 205.00000000000003 unrounded; must render "205".
        let kg205 = WeightUnit.lbs.toKg(205.0)
        XCTAssertEqual(WeightUnit.lbs.formatWeightNumber(kg: kg205), "205")

        let kg135 = WeightUnit.lbs.toKg(135.0)
        XCTAssertEqual(WeightUnit.lbs.formatWeightNumber(kg: kg135), "135")

        let kg62_5 = WeightUnit.kg.toKg(62.5)
        XCTAssertEqual(WeightUnit.kg.formatWeightNumber(kg: kg62_5), "62.5")
    }

    @MainActor
    func testRecentlyActiveEntriesBringsSupersettedExerciseToTop() throws {
        let schema = Schema([
            WorkoutSession.self,
            ExerciseEntry.self,
            LoggedSet.self,
            CoachMessage.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let t1 = t0.addingTimeInterval(60)
        let t2 = t0.addingTimeInterval(120)

        let session = WorkoutSession(startedAt: t0, title: "Push Day", isActive: true)
        context.insert(session)

        let bench = ExerciseEntry(
            exerciseName: "Bench Press",
            canonicalName: "bench press",
            muscleGroup: .chest,
            orderIndex: 0,
            createdAt: t0
        )
        let incline = ExerciseEntry(
            exerciseName: "Incline Dumbbell Press",
            canonicalName: "incline dumbbell press",
            muscleGroup: .chest,
            orderIndex: 1,
            createdAt: t1
        )
        context.insert(bench)
        context.insert(incline)
        bench.session = session
        incline.session = session
        session.entries.append(contentsOf: [bench, incline])

        let benchSet1 = LoggedSet(setNumber: 1, reps: 10, weightKg: 60, loggedAt: t0)
        let inclineSet1 = LoggedSet(setNumber: 1, reps: 12, weightKg: 24, loggedAt: t1)
        let benchSet2 = LoggedSet(setNumber: 2, reps: 10, weightKg: 60, loggedAt: t2)
        context.insert(benchSet1)
        context.insert(inclineSet1)
        context.insert(benchSet2)
        benchSet1.entry = bench
        benchSet2.entry = bench
        inclineSet1.entry = incline
        bench.sets.append(contentsOf: [benchSet1, benchSet2])
        incline.sets.append(inclineSet1)

        let ordered = session.recentlyActiveEntries
        XCTAssertEqual(ordered.first?.exerciseName, "Bench Press")
        XCTAssertEqual(ordered.last?.exerciseName, "Incline Dumbbell Press")
    }

    func testWorkoutSplitFilterClassifiesUpperLowerFullAndCoreCleanly() {
        // Upper workout finishing with an accessory plank stays Upper
        XCTAssertEqual(
            WorkoutSplitFilter.classify(muscleGroups: [.chest, .triceps, .core], title: "Push Day"),
            .upper
        )
        // Lower workout finishing with a plank stays Lower
        XCTAssertEqual(
            WorkoutSplitFilter.classify(muscleGroups: [.quads, .hamstrings, .core], title: "Leg Day"),
            .lower
        )
        // Full-body session spanning upper + lower lifts goes to Full / Other
        XCTAssertEqual(
            WorkoutSplitFilter.classify(muscleGroups: [.chest, .quads], title: "Full Body"),
            .other
        )
        // Core/Cardio-only session goes to Full / Other
        XCTAssertEqual(
            WorkoutSplitFilter.classify(muscleGroups: [.core, .cardio], title: "Core & Conditioning"),
            .other
        )
    }

    @MainActor
    func testModelManagerPersistsSpeechEngineWhisperPresetAndPrewarmState() throws {
        let suiteName = "com.yuvaraja.buddy.tests.speech.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let eightGB: UInt64 = 8 * 1_073_741_824
        let manager = ModelManager(
            defaults: defaults,
            osBuildMarker: "iOS 18.5 (22F76)",
            physicalMemoryBytes: eightGB
        )
        XCTAssertEqual(manager.selectedSpeechEngine, .appleSpeech)
        XCTAssertEqual(manager.selectedWhisperPreset, .largeV3Turbo)
        XCTAssertEqual(manager.effectiveSpeechEngine, .appleSpeech)
        XCTAssertEqual(manager.selectedAppleSpeechLocale, .auto)
        XCTAssertFalse(manager.isPrewarmed(.largeV3Turbo))
        XCTAssertFalse(manager.isAllReady(appleSpeechReady: false))

        // Selecting WhisperKit before downloading still falls back cleanly to Apple Speech.
        manager.selectedSpeechEngine = .whisperKit
        manager.selectedWhisperPreset = .largeV3TurboCompact
        manager.selectedAppleSpeechLocale = .enIN
        manager.markPrewarmed(.largeV3TurboCompact)
        XCTAssertEqual(manager.effectiveSpeechEngine, .appleSpeech)
        XCTAssertTrue(manager.isPrewarmed(.largeV3TurboCompact))

        let reloadedSameOS = ModelManager(
            defaults: defaults,
            osBuildMarker: "iOS 18.5 (22F76)",
            physicalMemoryBytes: eightGB
        )
        XCTAssertEqual(reloadedSameOS.selectedSpeechEngine, .whisperKit)
        XCTAssertEqual(reloadedSameOS.selectedWhisperPreset, .largeV3TurboCompact)
        XCTAssertEqual(reloadedSameOS.selectedAppleSpeechLocale, .enIN)
        XCTAssertTrue(reloadedSameOS.isPrewarmed(.largeV3TurboCompact))

        // iOS updates invalidate CoreML ANE caches, so prewarm state must reset on a new OS build.
        let reloadedNewOS = ModelManager(
            defaults: defaults,
            osBuildMarker: "iOS 19.0 (23A100)",
            physicalMemoryBytes: eightGB
        )
        XCTAssertFalse(reloadedNewOS.isPrewarmed(.largeV3TurboCompact))
    }

    @MainActor
    func testModelManagerSelectsRAMSafeDefaultWhisperPreset() throws {
        let suite4 = "com.yuvaraja.buddy.tests.ram4.\(UUID().uuidString)"
        let suite6 = "com.yuvaraja.buddy.tests.ram6.\(UUID().uuidString)"
        let suite8 = "com.yuvaraja.buddy.tests.ram8.\(UUID().uuidString)"
        let defaults4 = try XCTUnwrap(UserDefaults(suiteName: suite4))
        let defaults6 = try XCTUnwrap(UserDefaults(suiteName: suite6))
        let defaults8 = try XCTUnwrap(UserDefaults(suiteName: suite8))
        defer {
            defaults4.removePersistentDomain(forName: suite4)
            defaults6.removePersistentDomain(forName: suite6)
            defaults8.removePersistentDomain(forName: suite8)
        }

        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(ModelManager.recommendedWhisperPreset(forPhysicalMemoryBytes: 4 * gib), .smallEn)
        XCTAssertEqual(ModelManager.recommendedWhisperPreset(forPhysicalMemoryBytes: 6 * gib), .largeV3TurboCompact)
        XCTAssertEqual(ModelManager.recommendedWhisperPreset(forPhysicalMemoryBytes: 8 * gib), .largeV3Turbo)

        let m4 = ModelManager(defaults: defaults4, physicalMemoryBytes: 4 * gib)
        XCTAssertEqual(m4.selectedWhisperPreset, .smallEn)
        XCTAssertTrue(m4.isLowRAMDeviceForLargeWhisper)

        let m6 = ModelManager(defaults: defaults6, physicalMemoryBytes: 6 * gib)
        XCTAssertEqual(m6.selectedWhisperPreset, .largeV3TurboCompact)
        XCTAssertFalse(m6.isLowRAMDeviceForLargeWhisper)

        let m8 = ModelManager(defaults: defaults8, physicalMemoryBytes: 8 * gib)
        XCTAssertEqual(m8.selectedWhisperPreset, .largeV3Turbo)
        XCTAssertFalse(m8.isLowRAMDeviceForLargeWhisper)
    }

    @MainActor
    func testModelMemoryCoordinatorSerializesConcurrentWhisperAndLLMLoads() async throws {
        let coordinator = ModelMemoryCoordinator()
        var whisperResident = false
        var llmResident = false
        var peakConcurrentModels = 0

        let whisperTask = Task { @MainActor in
            try await coordinator.runExclusiveLoad(
                for: .whisper,
                unloadOther: {
                    if llmResident {
                        try? await Task.sleep(for: .milliseconds(25))
                        llmResident = false
                        coordinator.markUnloaded(.llm)
                    }
                },
                operation: {
                    XCTAssertFalse(llmResident, "LLM must be completely unloaded before Whisper loads")
                    whisperResident = true
                    peakConcurrentModels = max(peakConcurrentModels, (whisperResident ? 1 : 0) + (llmResident ? 1 : 0))
                    try? await Task.sleep(for: .milliseconds(35))
                    return "whisper"
                }
            )
        }

        let llmTask = Task { @MainActor in
            try await coordinator.runExclusiveLoad(
                for: .llm,
                unloadOther: {
                    if whisperResident {
                        try? await Task.sleep(for: .milliseconds(25))
                        whisperResident = false
                        coordinator.markUnloaded(.whisper)
                    }
                },
                operation: {
                    XCTAssertFalse(whisperResident, "Whisper must be completely unloaded before LLM loads")
                    llmResident = true
                    peakConcurrentModels = max(peakConcurrentModels, (whisperResident ? 1 : 0) + (llmResident ? 1 : 0))
                    try? await Task.sleep(for: .milliseconds(35))
                    return "llm"
                }
            )
        }

        let first = try await whisperTask.value
        let second = try await llmTask.value
        XCTAssertEqual(first, "whisper")
        XCTAssertEqual(second, "llm")
        XCTAssertEqual(peakConcurrentModels, 1, "Whisper and Qwen must never be resident simultaneously")
        XCTAssertEqual((whisperResident ? 1 : 0) + (llmResident ? 1 : 0), 1)

        coordinator.markUnloaded(coordinator.activeOwner)
        XCTAssertEqual(coordinator.activeOwner, .none)
    }

    func testWhisperHelpersPadShortClipsSanitizeArtifactsAndKeepPromptSafe() {
        // Short 0.25s clip (4000 samples @ 16kHz) is padded to 20,000 samples (1.25s) with zeros.
        let shortClip = Array(repeating: Float(0.25), count: 4_000)
        let padded = WhisperTranscriptionService.prepareAudioSamplesForWhisper(shortClip)
        XCTAssertEqual(padded.count, 20_000)
        XCTAssertEqual(padded[3_999], 0.25, accuracy: 0.0001)
        XCTAssertEqual(padded[4_000], 0.0, accuracy: 0.0001)

        // Clips >= 20,000 samples are returned unchanged.
        let longClip = Array(repeating: Float(0.1), count: 24_000)
        XCTAssertEqual(WhisperTranscriptionService.prepareAudioSamplesForWhisper(longClip).count, 24_000)

        // Control tokens, bracketed sound tags, and parenthetical audio labels are stripped cleanly.
        let dirty = "<|startoftranscript|> [MUSIC] Incline dumbbell press 30 kg 3 sets 10 reps (clanking) [BLANK_AUDIO] <|endoftext|>"
        XCTAssertEqual(
            WhisperTranscriptionService.cleanTranscript(dirty),
            "Incline dumbbell press 30 kg 3 sets 10 reps"
        )

        // Gym bias prompt prioritizes active exercises, stays compact, and excludes destructive words.
        let prompt = WhisperTranscriptionService.buildGymBiasPrompt(
            recentExercises: ["Cable Lateral Raise", "Bench Press", "bench press"]
        )
        XCTAssertTrue(prompt.contains("Cable Lateral Raise"))
        XCTAssertTrue(prompt.contains("RDL"))
        XCTAssertLessThan(prompt.count, 220, "Bias prompt must remain compact to stay well under WhisperKit's 111-token suffix cap")
        let lowerPrompt = prompt.lowercased()
        XCTAssertFalse(lowerPrompt.contains("delete"))
        XCTAssertFalse(lowerPrompt.contains("finish"))
        XCTAssertFalse(lowerPrompt.contains("end workout"))
    }

    func testWhisperSilenceGuardAndCompactPromptBudget() {
        XCTAssertFalse(WhisperTranscriptionService.hasAudibleSpeech(in: []))
        XCTAssertFalse(WhisperTranscriptionService.hasAudibleSpeech(in: Array(repeating: Float(0), count: 16_000)))
        XCTAssertFalse(WhisperTranscriptionService.hasAudibleSpeech(in: Array(repeating: Float(0.0001), count: 16_000)))

        let speechWave: [Float] = (0..<16_000).map { idx in
            sin(Float(2.0 * Double.pi * 220.0 * Double(idx) / 16_000.0)) * 0.05
        }
        XCTAssertTrue(WhisperTranscriptionService.hasAudibleSpeech(in: speechWave))

        var transientClip = Array(repeating: Float(0), count: 16_000)
        transientClip[8_000] = 0.02
        XCTAssertTrue(WhisperTranscriptionService.hasAudibleSpeech(in: transientClip))

        // Long active exercise list must preserve the first 5 exercises at the front and cap total length.
        let crowdedPrompt = WhisperTranscriptionService.buildGymBiasPrompt(recentExercises: [
            "Bulgarian Split Squat",
            "Seated Cable Row",
            "Overhead Tricep Extension",
            "Incline Smith Machine Press",
            "Preacher Curl",
            "Calf Raise",
            "Face Pull"
        ])
        XCTAssertTrue(crowdedPrompt.contains("Bulgarian Split Squat"))
        XCTAssertTrue(crowdedPrompt.contains("Preacher Curl"))
        XCTAssertFalse(crowdedPrompt.contains("Calf Raise"))
        XCTAssertLessThan(crowdedPrompt.count, 240)
    }

    func testAudioInterleavedStereoExtractionAndRMS() throws {
        // Build a real interleaved 2-channel Float32 AVAudioPCMBuffer:
        // Frame 0: (0.2, 0.6) -> mono 0.4
        // Frame 1: (-0.4, 0.0) -> mono -0.2
        // Frame 2: (0.8, 0.4) -> mono 0.6
        // Frame 3: (-0.2, -0.6) -> mono -0.4
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4

        let interleavedData: [Float] = [0.2, 0.6, -0.4, 0.0, 0.8, 0.4, -0.2, -0.6]
        let floatChannels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<interleavedData.count {
            floatChannels[0][index] = interleavedData[index]
        }

        var output = Array(repeating: Float(0), count: 4)
        output.withUnsafeMutableBufferPointer { dst in
            AudioRecorderService.writeMonoFloatSamples(from: buffer, maxFrames: 4, into: dst.baseAddress!)
        }

        XCTAssertEqual(output[0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(output[1], -0.2, accuracy: 0.0001)
        XCTAssertEqual(output[2], 0.6, accuracy: 0.0001)
        XCTAssertEqual(output[3], -0.4, accuracy: 0.0001)

        // Expected RMS of [0.4, -0.2, 0.6, -0.4] = sqrt((0.16 + 0.04 + 0.36 + 0.16) / 4) = sqrt(0.18)
        let expectedRMS = sqrt(Float(0.18))
        let actualRMS = AudioRecorderService.computeRMSInPlace(from: buffer)
        XCTAssertEqual(actualRMS, expectedRMS, accuracy: 0.0005)
    }

    func testAudioResampleTo16kHzProducesExpectedFrameCount() {
        // Test common iOS hardware sample rates (48 kHz, 44.1 kHz, 24 kHz Bluetooth HFP).
        for sampleRate in [48_000.0, 44_100.0, 24_000.0] {
            let count = Int(sampleRate)
            let input: [Float] = (0..<count).map { idx in
                sin(Float(2.0 * Double.pi * 440.0 * Double(idx) / sampleRate)) * 0.5
            }
            let resampled = AudioRecorderService.resampleTo16kHz(samples: input, fromSampleRate: sampleRate)
            XCTAssertGreaterThan(resampled.count, 15_500, "Sample rate \(sampleRate) produced too few frames")
            XCTAssertLessThan(resampled.count, 16_500, "Sample rate \(sampleRate) produced too many frames")
        }

        // Already 16 kHz passes through untouched.
        let passthrough = AudioRecorderService.resampleTo16kHz(samples: [0.1, -0.2, 0.3], fromSampleRate: 16_000)
        XCTAssertEqual(passthrough, [0.1, -0.2, 0.3])
    }

    func testLocalLLMConfidentRuleParseFastPath() {
        let context = ActiveSessionPromptContext(preferredUnit: .kg)
        let cleanSet = RuleBasedWorkoutParser.parse("Bench press 60 kg 3 sets 10 reps", context: context)
        XCTAssertTrue(LocalLLMService.isConfidentRuleParse(cleanSet))

        let undoCmd = RuleBasedWorkoutParser.parse("undo last set", context: context)
        XCTAssertTrue(LocalLLMService.isConfidentRuleParse(undoCmd))

        let vague = RuleBasedWorkoutParser.parse("my shoulder felt weird today", context: context)
        XCTAssertFalse(LocalLLMService.isConfidentRuleParse(vague))
    }

    func testAudioSessionConfigurationPrefersBuiltInMicWithoutBluetoothHFP() {
        // Default loud-gym profile: iPhone built-in mic + A2DP stereo music (no HFP call downgrade)
        let builtInIsolated = AudioRecorderService.sessionConfiguration(
            for: AudioCaptureOptions(enableVoiceIsolation: true, preferBuiltInMic: true)
        )
        XCTAssertEqual(builtInIsolated.mode, .default)
        XCTAssertTrue(builtInIsolated.options.contains(.allowBluetoothA2DP))
        XCTAssertTrue(builtInIsolated.options.contains(.mixWithOthers))
        XCTAssertFalse(builtInIsolated.options.contains(.allowBluetooth))

        // Bluetooth headset mic opted-in with voice isolation: `.voiceChat` + HFP enabled
        let bluetoothIsolated = AudioRecorderService.sessionConfiguration(
            for: AudioCaptureOptions(enableVoiceIsolation: true, preferBuiltInMic: false)
        )
        XCTAssertEqual(bluetoothIsolated.mode, .voiceChat)
        XCTAssertTrue(bluetoothIsolated.options.contains(.allowBluetooth))
        XCTAssertTrue(bluetoothIsolated.options.contains(.allowBluetoothA2DP))

        // Bluetooth headset mic opted-in without voice isolation: `.default` + HFP enabled
        let bluetoothPlain = AudioRecorderService.sessionConfiguration(
            for: AudioCaptureOptions(enableVoiceIsolation: false, preferBuiltInMic: false)
        )
        XCTAssertEqual(bluetoothPlain.mode, .default)
        XCTAssertTrue(bluetoothPlain.options.contains(.allowBluetooth))
    }

    func testSelectBestGymTranscriptionPrefersWorkoutValidAlternativeOverNoisyHomophone() {
        let context = ActiveSessionPromptContext(preferredUnit: .kg)

        // Alternative hypothesis has clean gym vocabulary vs corrupted top-1 homophones
        let cleaned = AppleSpeechService.selectBestGymTranscription(
            candidates: [
                "bench price 60 kg 3 sex 10 wraps",
                "bench press 60 kg 3 sets 10 reps"
            ],
            context: context
        )
        XCTAssertEqual(cleaned, "bench press 60 kg 3 sets 10 reps")

        // Known catalog exercise beats unknown noisy mishearing
        let knownCatalog = AppleSpeechService.selectBestGymTranscription(
            candidates: [
                "black spot 100 kg 3 sets 8 reps",
                "hack squat 100 kg 3 sets 8 reps"
            ],
            context: context
        )
        XCTAssertEqual(knownCatalog, "hack squat 100 kg 3 sets 8 reps")

        // Active session exercise context breaks ties in favor of the exercise currently being trained
        let sessionContext = ActiveSessionPromptContext(
            preferredUnit: .kg,
            lastExerciseName: "Bench Press",
            recentExercisesInSession: ["Bench Press"],
            isSessionActive: true
        )
        let contextual = AppleSpeechService.selectBestGymTranscription(
            candidates: [
                "leg press 80 kg 10 reps",
                "bench press 80 kg 10 reps"
            ],
            context: sessionContext
        )
        XCTAssertEqual(contextual, "bench press 80 kg 10 reps")

        // Equal-quality candidates preserve Apple's top acoustic match
        let tiePreserved = AppleSpeechService.selectBestGymTranscription(
            candidates: [
                "bench press 80 kg 5 reps",
                "bench press 18 kg 5 reps"
            ],
            context: context
        )
        XCTAssertEqual(tiePreserved, "bench press 80 kg 5 reps")

        // Partial live transcript before numbers arrive prefers known exercise phrase
        let partial = AppleSpeechService.selectBestGymTranscription(
            candidates: ["bench price", "bench press"],
            context: context
        )
        XCTAssertEqual(partial, "bench press")
    }

    func testRuleBasedParserRepairsLoudGymPhoneticMishearings() {
        let context = ActiveSessionPromptContext(preferredUnit: .kg)

        let bench = RuleBasedWorkoutParser.parse("bench price 60 kg 3 sex 10 wraps", context: context)
        XCTAssertEqual(bench.action, .logSets)
        XCTAssertEqual(bench.items.first?.exerciseName, "Bench Press")
        XCTAssertEqual(bench.items.first?.setCount, 3)
        XCTAssertEqual(bench.items.first?.reps, 10)
        XCTAssertEqual(bench.items.first?.weightValue ?? -1, 60, accuracy: 0.01)

        let curl = RuleBasedWorkoutParser.parse("bicep girl 15 kg 3 sets 12 raps", context: context)
        XCTAssertEqual(curl.action, .logSets)
        XCTAssertEqual(curl.items.first?.exerciseName, "Bicep Curl")
        XCTAssertEqual(curl.items.first?.setCount, 3)
        XCTAssertEqual(curl.items.first?.reps, 12)
        XCTAssertEqual(curl.items.first?.weightValue ?? -1, 15, accuracy: 0.01)

        let pulldown = RuleBasedWorkoutParser.parse("let pulldown 55 kg 3 sits 10 reps", context: context)
        XCTAssertEqual(pulldown.action, .logSets)
        XCTAssertEqual(pulldown.items.first?.exerciseName, "Lat Pulldown")
        XCTAssertEqual(pulldown.items.first?.setCount, 3)
        XCTAssertEqual(pulldown.items.first?.reps, 10)
        XCTAssertEqual(pulldown.items.first?.weightValue ?? -1, 55, accuracy: 0.01)

        let raises = RuleBasedWorkoutParser.parse("lateral rays 12 kg 3 sets 15 wraps", context: context)
        XCTAssertEqual(raises.action, .logSets)
        XCTAssertEqual(raises.items.first?.exerciseName, "Lateral Raise")
        XCTAssertEqual(raises.items.first?.setCount, 3)
        XCTAssertEqual(raises.items.first?.reps, 15)
        XCTAssertEqual(raises.items.first?.weightValue ?? -1, 12, accuracy: 0.01)

        let hipThrust = RuleBasedWorkoutParser.parse("hip trust 100 kg 4 sets 8 reps", context: context)
        XCTAssertEqual(hipThrust.action, .logSets)
        XCTAssertEqual(hipThrust.items.first?.exerciseName, "Hip Thrust")
        XCTAssertEqual(hipThrust.items.first?.setCount, 4)
        XCTAssertEqual(hipThrust.items.first?.reps, 8)
        XCTAssertEqual(hipThrust.items.first?.weightValue ?? -1, 100, accuracy: 0.01)
    }

    func testExerciseCatalogIsKnownExerciseDistinguishesCatalogFromRandomWords() {
        XCTAssertTrue(ExerciseCatalog.isKnownExercise("Bench Press"))
        XCTAssertTrue(ExerciseCatalog.isKnownExercise("rdl"))
        XCTAssertTrue(ExerciseCatalog.isKnownExercise("Hack Squat"))
        XCTAssertFalse(ExerciseCatalog.isKnownExercise("Black Spot"))
        XCTAssertFalse(ExerciseCatalog.isKnownExercise("Bench Price"))
    }

    @MainActor
    func testModelManagerPersistsLoudGymVoiceSettings() throws {
        let suiteName = "com.yuvaraja.buddy.tests.gymvoice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ModelManager(defaults: defaults)
        XCTAssertEqual(manager.selectedAppleSpeechMode, .hybridAuto)
        XCTAssertTrue(manager.enableGymNoiseIsolation)
        XCTAssertTrue(manager.preferBuiltInMic)
        XCTAssertEqual(
            manager.audioCaptureOptions,
            AudioCaptureOptions(enableVoiceIsolation: true, preferBuiltInMic: true)
        )

        manager.selectedAppleSpeechMode = .offlineOnly
        manager.enableGymNoiseIsolation = false
        manager.preferBuiltInMic = false

        let reloaded = ModelManager(defaults: defaults)
        XCTAssertEqual(reloaded.selectedAppleSpeechMode, .offlineOnly)
        XCTAssertFalse(reloaded.enableGymNoiseIsolation)
        XCTAssertFalse(reloaded.preferBuiltInMic)
        XCTAssertEqual(
            reloaded.audioCaptureOptions,
            AudioCaptureOptions(enableVoiceIsolation: false, preferBuiltInMic: false)
        )
    }
}
