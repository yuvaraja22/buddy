import XCTest
@testable import Buddy

final class RuleBasedWorkoutParserTests: XCTestCase {
    private let defaultContext = ActiveSessionPromptContext(preferredUnit: .kg)

    func testParsesLegExtensionMultipleSetsAndRepsWithoutWeight() {
        let intent = RuleBasedWorkoutParser.parse("leg extension 3 set 15 reps", context: defaultContext)

        XCTAssertEqual(intent.action, .logSets)
        XCTAssertEqual(intent.items.count, 1)
        guard let item = intent.items.first else {
            return XCTFail("Expected a parsed item")
        }
        XCTAssertEqual(item.exerciseName, "Leg Extension")
        XCTAssertEqual(item.setCount, 3)
        XCTAssertEqual(item.reps, 15)
        XCTAssertNil(item.weightValue)
    }

    func testParsesBenchPressWithKgWeightSetsAndReps() {
        let intent = RuleBasedWorkoutParser.parse("bench press 60 kg 3 sets 10 reps", context: defaultContext)

        XCTAssertEqual(intent.action, .logSets)
        XCTAssertEqual(intent.items.count, 1)
        guard let item = intent.items.first else {
            return XCTFail("Expected a parsed item")
        }
        XCTAssertEqual(item.exerciseName, "Bench Press")
        XCTAssertEqual(item.setCount, 3)
        XCTAssertEqual(item.reps, 10)
        XCTAssertEqual(item.weightValue ?? -1, 60, accuracy: 0.01)
        XCTAssertEqual(item.weightUnit, .kg)
        XCTAssertEqual(item.resolvedWeightKg(defaultUnit: .kg) ?? -1, 60, accuracy: 0.01)
    }

    func testParsesInclineDumbbellPressCompactSetsAndPoundsConversion() {
        let intent = RuleBasedWorkoutParser.parse("incline dumbbell press 3x12 at 50 lbs", context: defaultContext)

        XCTAssertEqual(intent.action, .logSets)
        XCTAssertEqual(intent.items.count, 1)
        guard let item = intent.items.first else {
            return XCTFail("Expected a parsed item")
        }
        XCTAssertEqual(item.exerciseName, "Incline Dumbbell Press")
        XCTAssertEqual(item.setCount, 3)
        XCTAssertEqual(item.reps, 12)
        XCTAssertEqual(item.weightValue ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(item.weightUnit, .lbs)

        let expectedKg = WeightUnit.lbs.toKg(50)
        XCTAssertEqual(item.resolvedWeightKg(defaultUnit: .kg) ?? -1, expectedKg, accuracy: 0.01)
    }

    func testParsesTimedExercisesInSecondsAndMinutes() {
        let plankIntent = RuleBasedWorkoutParser.parse("plank 90 seconds", context: defaultContext)
        XCTAssertEqual(plankIntent.action, .logSets)
        XCTAssertEqual(plankIntent.items.first?.durationSeconds, 90)

        let treadmillIntent = RuleBasedWorkoutParser.parse("treadmill 20 minutes", context: defaultContext)
        XCTAssertEqual(treadmillIntent.action, .logSets)
        XCTAssertEqual(treadmillIntent.items.first?.durationSeconds, 1_200)
    }

    func testParsesDropSetInheritingLastExerciseNameFromContext() {
        let context = ActiveSessionPromptContext(
            preferredUnit: .kg,
            lastExerciseName: "Leg Extension",
            recentExercisesInSession: ["Leg Extension"],
            isSessionActive: true
        )
        let intent = RuleBasedWorkoutParser.parse("drop set 30 kg 12 reps", context: context)

        XCTAssertEqual(intent.action, .logSets)
        XCTAssertEqual(intent.items.count, 1)
        guard let item = intent.items.first else {
            return XCTFail("Expected a parsed drop set item")
        }
        XCTAssertEqual(item.exerciseName, "Leg Extension")
        XCTAssertEqual(item.tag, .dropset)
        XCTAssertEqual(item.reps, 12)
        XCTAssertEqual(item.weightValue ?? -1, 30, accuracy: 0.01)
        XCTAssertEqual(item.resolvedWeightKg(defaultUnit: .kg) ?? -1, 30, accuracy: 0.01)
    }

    func testParsesDeleteLastSetCommand() {
        let intent = RuleBasedWorkoutParser.parse("delete last set", context: defaultContext)
        XCTAssertEqual(intent.action, .deleteLastSet)
    }

    func testParsesUpdateLastSetRepsCommand() {
        let intent = RuleBasedWorkoutParser.parse("change last set to 12 reps", context: defaultContext)

        XCTAssertEqual(intent.action, .updateLastSet)
        XCTAssertEqual(intent.items.first?.reps, 12)
    }

    func testParsesFinishWorkoutCommand() {
        let intent = RuleBasedWorkoutParser.parse("finish workout", context: defaultContext)
        XCTAssertEqual(intent.action, .endSession)
    }

    func testExerciseCatalogResolvesRDLAlias() {
        let resolved = ExerciseCatalog.resolve("rdl")
        XCTAssertEqual(resolved.displayName, "Romanian Deadlift")
        XCTAssertEqual(resolved.muscleGroup, .hamstrings)
        XCTAssertFalse(resolved.canonicalName.isEmpty)
    }
}
