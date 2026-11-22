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

    func testBuddyAppearanceColorSchemeMapping() {
        XCTAssertEqual(BuddyAppearance.dark.colorScheme, .dark)
        XCTAssertEqual(BuddyAppearance.light.colorScheme, .light)
        XCTAssertNil(BuddyAppearance.system.colorScheme)
    }

    @MainActor
    func testModelManagerPersistsAppleSpeechLocaleAndPurgesLegacyWhisperDefaults() throws {
        let suiteName = "com.yuvaraja.buddy.tests.speech.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Seed legacy WhisperKit defaults to verify automatic cleanup on initialization.
        defaults.set("whisperkit", forKey: "buddy.models.speechEngine")
        defaults.set("openai_whisper-base.en", forKey: "buddy.models.selectedWhisperPreset")
        defaults.set(["openai_whisper-base.en": "legacy"], forKey: "buddy.models.whisperRelativePaths")

        let manager = ModelManager(defaults: defaults)
        XCTAssertEqual(manager.selectedAppleSpeechLocale, .auto)
        XCTAssertFalse(manager.isAllReady(appleSpeechReady: false))
        XCTAssertNil(defaults.object(forKey: "buddy.models.speechEngine"))
        XCTAssertNil(defaults.object(forKey: "buddy.models.selectedWhisperPreset"))
        XCTAssertNil(defaults.object(forKey: "buddy.models.whisperRelativePaths"))

        manager.selectedAppleSpeechLocale = .enIN
        let reloaded = ModelManager(defaults: defaults)
        XCTAssertEqual(reloaded.selectedAppleSpeechLocale, .enIN)
    }
}
