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

    func testParsesUnitlessWeightsAndUpdateCommands() {
        let at80 = RuleBasedWorkoutParser.parse("bench press 3x10 at 80", context: defaultContext)
        XCTAssertEqual(at80.action, .logSets)
        XCTAssertEqual(at80.items.first?.exerciseName, "Bench Press")
        XCTAssertEqual(at80.items.first?.setCount, 3)
        XCTAssertEqual(at80.items.first?.reps, 10)
        XCTAssertEqual(at80.items.first?.weightValue ?? -1, 80, accuracy: 0.01)
        XCTAssertNil(at80.items.first?.weightUnit)

        let bareWeight = RuleBasedWorkoutParser.parse("bench press 135 3x8", context: defaultContext)
        XCTAssertEqual(bareWeight.action, .logSets)
        XCTAssertEqual(bareWeight.items.first?.exerciseName, "Bench Press")
        XCTAssertEqual(bareWeight.items.first?.setCount, 3)
        XCTAssertEqual(bareWeight.items.first?.reps, 8)
        XCTAssertEqual(bareWeight.items.first?.weightValue ?? -1, 135, accuracy: 0.01)

        let activeCtx = ActiveSessionPromptContext(preferredUnit: .kg, lastExerciseName: "Bench Press", isSessionActive: true)

        let makeThat50 = RuleBasedWorkoutParser.parse("make that 50", context: activeCtx)
        XCTAssertEqual(makeThat50.action, .updateLastSet)
        XCTAssertEqual(makeThat50.items.first?.weightValue ?? -1, 50, accuracy: 0.01)

        let actuallyReps = RuleBasedWorkoutParser.parse("actually 12 reps", context: activeCtx)
        XCTAssertEqual(actuallyReps.action, .updateLastSet)
        XCTAssertEqual(actuallyReps.items.first?.reps, 12)

        let markWarmup = RuleBasedWorkoutParser.parse("mark as warmup", context: activeCtx)
        XCTAssertEqual(markWarmup.action, .updateLastSet)
        XCTAssertEqual(markWarmup.items.first?.tag, .warmup)
    }

    func testSplitsChainedAndClausesWithoutBreakingCompoundExerciseNames() {
        let chained = RuleBasedWorkoutParser.parse(
            "bench press 3x10 at 80 kg and lateral raise 3x15 at 12 kg",
            context: defaultContext
        )
        XCTAssertEqual(chained.action, .logSets)
        XCTAssertEqual(chained.items.count, 2)
        XCTAssertEqual(chained.items[0].exerciseName, "Bench Press")
        XCTAssertEqual(chained.items[0].weightValue ?? -1, 80, accuracy: 0.01)
        XCTAssertEqual(chained.items[1].exerciseName, "Lateral Raise")
        XCTAssertEqual(chained.items[1].weightValue ?? -1, 12, accuracy: 0.01)

        let compound = RuleBasedWorkoutParser.parse("clean and jerk 3x5 at 60 kg", context: defaultContext)
        XCTAssertEqual(compound.action, .logSets)
        XCTAssertEqual(compound.items.count, 1)
        XCTAssertEqual(compound.items[0].setCount, 3)
        XCTAssertEqual(compound.items[0].reps, 5)
        XCTAssertEqual(compound.items[0].weightValue ?? -1, 60, accuracy: 0.01)
    }

    func testParsesColloquialThreeDigitWeightsWithoutBreakingSetRepPairs() {
        let lbsContext = ActiveSessionPromptContext(preferredUnit: .lbs)

        let bench135 = RuleBasedWorkoutParser.parse("bench press one thirty five for eight", context: lbsContext)
        XCTAssertEqual(bench135.action, .logSets)
        XCTAssertEqual(bench135.items.first?.exerciseName, "Bench Press")
        XCTAssertEqual(bench135.items.first?.weightValue ?? -1, 135, accuracy: 0.01)
        XCTAssertEqual(bench135.items.first?.reps, 8)

        let squat225 = RuleBasedWorkoutParser.parse("squat two twenty five for five", context: lbsContext)
        XCTAssertEqual(squat225.action, .logSets)
        XCTAssertEqual(squat225.items.first?.exerciseName, "Squat")
        XCTAssertEqual(squat225.items.first?.weightValue ?? -1, 225, accuracy: 0.01)
        XCTAssertEqual(squat225.items.first?.reps, 5)

        let deadlift405 = RuleBasedWorkoutParser.parse("deadlift four oh five for three", context: lbsContext)
        XCTAssertEqual(deadlift405.action, .logSets)
        XCTAssertEqual(deadlift405.items.first?.exerciseName, "Deadlift")
        XCTAssertEqual(deadlift405.items.first?.weightValue ?? -1, 405, accuracy: 0.01)
        XCTAssertEqual(deadlift405.items.first?.reps, 3)

        let deadlift315 = RuleBasedWorkoutParser.parse("deadlift three fifteen for five", context: lbsContext)
        XCTAssertEqual(deadlift315.action, .logSets)
        XCTAssertEqual(deadlift315.items.first?.exerciseName, "Deadlift")
        XCTAssertEqual(deadlift315.items.first?.weightValue ?? -1, 315, accuracy: 0.01)
        XCTAssertEqual(deadlift315.items.first?.reps, 5)

        // Bare "three fifteen" without weight/rep connectors still parses as 3 sets x 15 reps.
        let bareSetReps = RuleBasedWorkoutParser.parse("leg extension three fifteen", context: defaultContext)
        XCTAssertEqual(bareSetReps.action, .logSets)
        XCTAssertEqual(bareSetReps.items.first?.exerciseName, "Leg Extension")
        XCTAssertEqual(bareSetReps.items.first?.setCount, 3)
        XCTAssertEqual(bareSetReps.items.first?.reps, 15)
        XCTAssertNil(bareSetReps.items.first?.weightValue)
    }

    func testParsesCountedSpacedWarmUpsWithoutLeakingCountIntoExerciseName() {
        let intent = RuleBasedWorkoutParser.parse("bench press two warm ups 60 kg 10 reps", context: defaultContext)

        XCTAssertEqual(intent.action, .logSets)
        XCTAssertEqual(intent.items.count, 1)
        guard let item = intent.items.first else {
            return XCTFail("Expected a parsed warmup item")
        }
        XCTAssertEqual(item.exerciseName, "Bench Press")
        XCTAssertEqual(item.setCount, 2)
        XCTAssertEqual(item.tag, .warmup)
        XCTAssertTrue(item.hasExplicitTag)
        XCTAssertEqual(item.weightValue ?? -1, 60, accuracy: 0.01)
        XCTAssertEqual(item.reps, 10)
    }

    func testRuleBasedWorkingTagResetUsesExplicitTagFlagInsteadOfNoteSentinel() {
        let activeCtx = ActiveSessionPromptContext(preferredUnit: .kg, lastExerciseName: "Bench Press", isSessionActive: true)
        let intent = RuleBasedWorkoutParser.parse("mark last set as working", context: activeCtx)

        XCTAssertEqual(intent.action, .updateLastSet)
        XCTAssertEqual(intent.items.first?.tag, .normal)
        XCTAssertEqual(intent.items.first?.hasExplicitTag, true)
        XCTAssertEqual(intent.items.first?.note, "")
    }
}
