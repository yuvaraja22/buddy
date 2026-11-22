import SwiftData
import XCTest
@testable import Buddy

@MainActor
final class WorkoutStoreAndStatsTests: XCTestCase {
    private var modelContainer: ModelContainer?
    private var testDefaultsSuiteName: String?

    override func tearDown() {
        modelContainer = nil
        if let suiteName = testDefaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            testDefaultsSuiteName = nil
        }
        super.tearDown()
    }

    private func makeInMemoryStore() throws -> WorkoutStore {
        let schema = Schema([
            WorkoutSession.self,
            ExerciseEntry.self,
            LoggedSet.self,
            CoachMessage.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        self.modelContainer = container

        let suiteName = "com.yuvaraja.buddy.tests.\(UUID().uuidString)"
        self.testDefaultsSuiteName = suiteName
        let isolatedDefaults = UserDefaults(suiteName: suiteName) ?? .standard

        let store = WorkoutStore(
            modelContext: container.mainContext,
            defaults: isolatedDefaults,
            enableSystemSync: false
        )
        store.preferredUnit = .kg
        return store
    }

    func testAutoStartsSessionAndExpandsMultiSetCommandIntoIndividualNumberedSets() throws {
        let store = try makeInMemoryStore()
        XCTAssertNil(store.activeSession)

        let intent = RuleBasedWorkoutParser.parse(
            "leg extension 3 sets 15 reps",
            context: ActiveSessionPromptContext(preferredUnit: .kg)
        )
        _ = store.apply(intent)

        guard let session = store.activeSession else {
            return XCTFail("Expected active session to auto-start on first logSets command")
        }
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.sortedEntries.count, 1)

        guard let entry = session.sortedEntries.first else {
            return XCTFail("Expected one ExerciseEntry for Leg Extension")
        }
        XCTAssertEqual(entry.exerciseName, "Leg Extension")
        XCTAssertEqual(entry.sortedSets.count, 3)
        XCTAssertEqual(entry.sortedSets.map(\.setNumber), [1, 2, 3])
        XCTAssertTrue(entry.sortedSets.allSatisfy { $0.reps == 15 })
        XCTAssertNotNil(store.latestBanner)
    }

    func testLoggingAdditionalSetAppendsToSameExerciseEntryWithoutDuplicatingCard() throws {
        let store = try makeInMemoryStore()

        let firstIntent = RuleBasedWorkoutParser.parse(
            "leg extension 3 sets 15 reps",
            context: ActiveSessionPromptContext(preferredUnit: .kg)
        )
        _ = store.apply(firstIntent)

        let secondIntent = RuleBasedWorkoutParser.parse(
            "leg extension 45 kg 12 reps",
            context: ActiveSessionPromptContext(
                preferredUnit: .kg,
                lastExerciseName: "Leg Extension",
                recentExercisesInSession: ["Leg Extension"],
                isSessionActive: true
            )
        )
        _ = store.apply(secondIntent)

        guard let session = store.activeSession else {
            return XCTFail("Expected active session")
        }
        XCTAssertEqual(session.sortedEntries.count, 1, "Appending to same exercise should not duplicate the ExerciseEntry card")

        guard let entry = session.sortedEntries.first else {
            return XCTFail("Expected Leg Extension entry")
        }
        XCTAssertEqual(entry.sortedSets.count, 4)
        XCTAssertEqual(entry.sortedSets.map(\.setNumber), [1, 2, 3, 4])
        XCTAssertEqual(entry.sortedSets[3].reps, 12)
        XCTAssertEqual(entry.sortedSets[3].weightKg ?? -1, 45, accuracy: 0.01)
    }

    func testUpdateLastSetMutatesSetFourAndUndoCleanlyRevertsIt() throws {
        let store = try makeInMemoryStore()

        _ = store.apply(RuleBasedWorkoutParser.parse(
            "leg extension 3 sets 15 reps",
            context: ActiveSessionPromptContext(preferredUnit: .kg)
        ))
        _ = store.apply(RuleBasedWorkoutParser.parse(
            "leg extension 45 kg 12 reps",
            context: ActiveSessionPromptContext(
                preferredUnit: .kg,
                lastExerciseName: "Leg Extension",
                recentExercisesInSession: ["Leg Extension"],
                isSessionActive: true
            )
        ))

        let updateIntent = WorkoutCommandIntent(
            action: .updateLastSet,
            items: [
                ParsedSetGroupIntent(
                    exerciseName: "Leg Extension",
                    setCount: 1,
                    reps: 10,
                    weightValue: 50,
                    weightUnit: .kg
                )
            ],
            summary: "Update last set",
            rawTranscript: "change last set to 50 kg 10 reps",
            parserSource: .ruleBased
        )
        _ = store.apply(updateIntent)

        guard let set4AfterUpdate = store.activeSession?.sortedEntries.first?.sortedSets.last else {
            return XCTFail("Expected set #4 after update")
        }
        XCTAssertEqual(set4AfterUpdate.setNumber, 4)
        XCTAssertEqual(set4AfterUpdate.reps, 10)
        XCTAssertEqual(set4AfterUpdate.weightKg ?? -1, 50, accuracy: 0.01)

        store.undoLastMutation()

        guard let set4AfterUndo = store.activeSession?.sortedEntries.first?.sortedSets.last else {
            return XCTFail("Expected set #4 after undo")
        }
        XCTAssertEqual(set4AfterUndo.setNumber, 4)
        XCTAssertEqual(set4AfterUndo.reps, 12)
        XCTAssertEqual(set4AfterUndo.weightKg ?? -1, 45, accuracy: 0.01)
    }

    func testUndoLastMutationAfterLogSetsRemovesNewlyAddedSets() throws {
        let store = try makeInMemoryStore()

        _ = store.apply(RuleBasedWorkoutParser.parse(
            "leg extension 3 sets 15 reps",
            context: ActiveSessionPromptContext(preferredUnit: .kg)
        ))
        XCTAssertEqual(store.activeSession?.sortedEntries.first?.sortedSets.count, 3)

        _ = store.apply(RuleBasedWorkoutParser.parse(
            "leg extension 2 sets 12 reps 40 kg",
            context: ActiveSessionPromptContext(
                preferredUnit: .kg,
                lastExerciseName: "Leg Extension",
                recentExercisesInSession: ["Leg Extension"],
                isSessionActive: true
            )
        ))
        XCTAssertEqual(store.activeSession?.sortedEntries.first?.sortedSets.count, 5)

        store.undoLastMutation()

        guard let entry = store.activeSession?.sortedEntries.first else {
            return XCTFail("Expected Leg Extension entry to remain with original 3 sets")
        }
        XCTAssertEqual(entry.sortedSets.count, 3)
        XCTAssertEqual(entry.sortedSets.map(\.setNumber), [1, 2, 3])
    }

    func testDirectSetEditDeleteFindAndEndActiveSession() throws {
        let store = try makeInMemoryStore()

        _ = store.apply(RuleBasedWorkoutParser.parse(
            "bench press 60 kg 2 sets 10 reps",
            context: ActiveSessionPromptContext(preferredUnit: .kg)
        ))

        guard let firstSet = store.activeSession?.sortedEntries.first?.sortedSets.first else {
            return XCTFail("Expected first logged set")
        }
        XCTAssertNotNil(store.findSet(id: firstSet.id))

        store.updateSet(
            firstSet,
            reps: 12,
            weightKg: 65,
            durationSeconds: nil,
            tag: .warmup,
            notes: "Controlled tempo"
        )
        XCTAssertEqual(firstSet.reps, 12)
        XCTAssertEqual(firstSet.weightKg ?? -1, 65, accuracy: 0.01)
        XCTAssertEqual(firstSet.tag, .warmup)
        XCTAssertEqual(firstSet.notes, "Controlled tempo")

        store.deleteSet(firstSet)
        XCTAssertEqual(store.activeSession?.totalSets, 1)

        _ = store.endActiveSession()
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.isActive, false)
        XCTAssertNotNil(store.sessions.first?.endedAt)
    }

    func testStatsCalculatorAcrossMultiDaySessions() throws {
        let store = try makeInMemoryStore()
        let context = try XCTUnwrap(modelContainer?.mainContext)
        _ = store

        let calendar = Calendar.current
        // Wednesday April 15, 2026: Mon/Tue/Wed fall inside the same week in both Sun-start and Mon-start locales.
        let referenceDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 12, minute: 0))
        )
        let dayMinus1 = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: referenceDate))
        let dayMinus2 = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: referenceDate))
        let dayMinus10 = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: referenceDate))

        let s1 = makeSession(
            in: context,
            startedAt: dayMinus10,
            exerciseName: "Bench Press",
            canonicalName: "Bench Press",
            muscleGroup: .chest,
            setCount: 3,
            reps: 8,
            weightKg: 60
        ) // 1,440 kg
        let s2 = makeSession(
            in: context,
            startedAt: dayMinus2,
            exerciseName: "Bench Press",
            canonicalName: "Bench Press",
            muscleGroup: .chest,
            setCount: 3,
            reps: 10,
            weightKg: 65
        ) // 1,950 kg
        let s3 = makeSession(
            in: context,
            startedAt: dayMinus1,
            exerciseName: "Leg Extension",
            canonicalName: "Leg Extension",
            muscleGroup: .quads,
            setCount: 3,
            reps: 15,
            weightKg: 45
        ) // 2,025 kg
        let s4 = makeSession(
            in: context,
            startedAt: referenceDate,
            exerciseName: "Bench Press",
            canonicalName: "Bench Press",
            muscleGroup: .chest,
            setCount: 3,
            reps: 10,
            weightKg: 70
        ) // 2,100 kg

        let sessions = [s1, s2, s3, s4]

        // 1. Consistency & streak accuracy
        let consistency = StatsCalculator.consistency(
            sessions: sessions,
            referenceDate: referenceDate,
            weeklyGoal: 4
        )
        XCTAssertEqual(consistency.currentStreakDays, 3)
        XCTAssertEqual(consistency.longestStreakDays, 3)
        XCTAssertEqual(consistency.workoutsThisWeek, 3)
        XCTAssertEqual(consistency.weeklyGoal, 4)
        XCTAssertEqual(consistency.totalWorkouts, 4)

        // 2. Heatmap days accuracy
        let heatmap = StatsCalculator.heatmapDays(
            sessions: sessions,
            weeks: 4,
            referenceDate: referenceDate
        )
        XCTAssertGreaterThanOrEqual(heatmap.count, 28)
        let activeHeatmapDays = heatmap.filter { $0.setCount > 0 }
        XCTAssertEqual(activeHeatmapDays.count, 4)
        XCTAssertTrue(activeHeatmapDays.allSatisfy { $0.setCount == 3 && $0.intensity > 0 })

        // 3. Volume series accuracy (1W vs 1M)
        let weekSeries = StatsCalculator.volumeSeries(
            sessions: sessions,
            timeframe: .week,
            referenceDate: referenceDate
        )
        let weekVolume = weekSeries.reduce(0.0) { $0 + $1.volumeKg }
        let weekSets = weekSeries.reduce(0) { $0 + $1.setCount }
        XCTAssertEqual(weekVolume, 6_075, accuracy: 0.01)
        XCTAssertEqual(weekSets, 9)

        let monthSeries = StatsCalculator.volumeSeries(
            sessions: sessions,
            timeframe: .month,
            referenceDate: referenceDate
        )
        let monthVolume = monthSeries.reduce(0.0) { $0 + $1.volumeKg }
        let monthSets = monthSeries.reduce(0) { $0 + $1.setCount }
        XCTAssertEqual(monthVolume, 7_515, accuracy: 0.01)
        XCTAssertEqual(monthSets, 12)

        // 4. Logged exercise names & per-exercise progression
        let loggedNames = StatsCalculator.loggedExerciseNames(sessions: sessions)
        XCTAssertTrue(loggedNames.contains { $0.caseInsensitiveCompare("Bench Press") == .orderedSame })
        XCTAssertTrue(loggedNames.contains { $0.caseInsensitiveCompare("Leg Extension") == .orderedSame })

        let benchProgression = StatsCalculator.exerciseProgression(
            canonicalName: "Bench Press",
            sessions: sessions
        )
        XCTAssertEqual(benchProgression.count, 3)
        XCTAssertEqual(benchProgression[0].maxWeightKg, 60, accuracy: 0.01)
        XCTAssertEqual(benchProgression[1].maxWeightKg, 65, accuracy: 0.01)
        XCTAssertEqual(benchProgression[2].maxWeightKg, 70, accuracy: 0.01)
        XCTAssertEqual(benchProgression[0].totalVolumeKg, 1_440, accuracy: 0.01)
        XCTAssertEqual(benchProgression[1].totalVolumeKg, 1_950, accuracy: 0.01)
        XCTAssertEqual(benchProgression[2].totalVolumeKg, 2_100, accuracy: 0.01)
        XCTAssertEqual(benchProgression[2].totalReps, 30)

        // 5. Widget snapshot builder accuracy
        let snapshot = StatsCalculator.buildWidgetSnapshot(
            sessions: sessions,
            preferredUnit: .kg,
            referenceDate: referenceDate
        )
        XCTAssertEqual(snapshot.todaySets, 3)
        XCTAssertEqual(snapshot.todayVolumeKg, 2_100, accuracy: 0.01)
        XCTAssertEqual(snapshot.lastTodayExerciseName, "Bench Press")
        XCTAssertEqual(snapshot.currentStreakDays, 3)
        XCTAssertEqual(snapshot.workoutsThisWeek, 3)
        XCTAssertEqual(snapshot.weeklyDays.count, 7)
    }

    func testReloadDeduplicatesMultipleActiveSessionsKeepingNewest() throws {
        let store = try makeInMemoryStore()
        let context = try XCTUnwrap(modelContainer?.mainContext)

        let older = WorkoutSession(
            startedAt: Date().addingTimeInterval(-7_200),
            title: "Morning",
            isActive: true
        )
        let newer = WorkoutSession(
            startedAt: Date().addingTimeInterval(-600),
            title: "Evening",
            isActive: true
        )
        context.insert(older)
        context.insert(newer)
        try context.save()

        store.reload()

        XCTAssertEqual(store.activeSession?.id, newer.id)
        XCTAssertTrue(newer.isActive)
        XCTAssertFalse(older.isActive)
        XCTAssertNotNil(older.endedAt)
    }

    func testUndoRestoresVoiceDeletedSetAndDeletedExercise() throws {
        let store = try makeInMemoryStore()

        _ = store.apply(RuleBasedWorkoutParser.parse(
            "leg extension 2 sets 15 reps 40 kg",
            context: ActiveSessionPromptContext(preferredUnit: .kg)
        ))
        XCTAssertEqual(store.activeSession?.totalSets, 2)

        _ = store.apply(RuleBasedWorkoutParser.parse("delete last set", context: store.promptContext()))
        XCTAssertEqual(store.activeSession?.totalSets, 1)

        store.undoLastMutation()
        XCTAssertEqual(store.activeSession?.totalSets, 2)

        _ = store.apply(RuleBasedWorkoutParser.parse("delete last exercise", context: store.promptContext()))
        XCTAssertEqual(store.activeSession?.entries.count, 0)

        store.undoLastMutation()
        XCTAssertEqual(store.activeSession?.entries.count, 1)
        XCTAssertEqual(store.activeSession?.totalSets, 2)
    }

    func testWidgetSnapshotPicksMostRecentSessionExerciseOnTwoSessionDay() throws {
        _ = try makeInMemoryStore()
        let context = try XCTUnwrap(modelContainer?.mainContext)

        let calendar = Calendar.current
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 8)))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 19)))

        let sMorning = makeSession(
            in: context,
            startedAt: morning,
            exerciseName: "Bench Press",
            canonicalName: "Bench Press",
            muscleGroup: .chest,
            setCount: 3,
            reps: 10,
            weightKg: 60
        )
        let sEvening = makeSession(
            in: context,
            startedAt: evening,
            exerciseName: "Leg Extension",
            canonicalName: "Leg Extension",
            muscleGroup: .quads,
            setCount: 3,
            reps: 15,
            weightKg: 45
        )

        let snapshot = StatsCalculator.buildWidgetSnapshot(
            sessions: [sMorning, sEvening],
            preferredUnit: .kg,
            referenceDate: evening.addingTimeInterval(3_600)
        )
        XCTAssertEqual(snapshot.lastTodayExerciseName, "Leg Extension")
        XCTAssertEqual(snapshot.todaySets, 6)
    }

    func testLLMUpdateLastSetResetsWarmupTagToNormalAndSkipsNoOpUpdates() throws {
        let store = try makeInMemoryStore()

        _ = store.apply(RuleBasedWorkoutParser.parse(
            "bench press 1 warmup set 40 kg 10 reps",
            context: ActiveSessionPromptContext(preferredUnit: .kg)
        ))
        XCTAssertEqual(store.activeSession?.sortedEntries.first?.sortedSets.first?.tag, .warmup)

        // 1. Qwen outputs explicit tag: .normal to reset warmup -> working set.
        let llmResetCommand = LLMParsedVoiceCommand(
            action: .updateLastSet,
            items: [
                LLMParsedExerciseGroup(
                    exercise: "Bench Press",
                    sets: 1,
                    tag: .normal
                )
            ],
            summary: "Mark last set as working"
        )
        let resetIntent = llmResetCommand.toDomainIntent(rawTranscript: "mark last set as working")
        XCTAssertEqual(resetIntent.items.first?.hasExplicitTag, true)

        let resetBanner = store.apply(resetIntent)
        XCTAssertNotNil(resetBanner)
        XCTAssertEqual(store.activeSession?.sortedEntries.first?.sortedSets.first?.tag, .normal)

        // 2. A no-op update (no fields changed) must return nil and NOT push to undoStack.
        let noOpCommand = LLMParsedVoiceCommand(
            action: .updateLastSet,
            items: [
                LLMParsedExerciseGroup(
                    exercise: "Bench Press",
                    sets: 1
                )
            ],
            summary: "No changes"
        )
        let noOpIntent = noOpCommand.toDomainIntent(rawTranscript: "update last set")
        XCTAssertEqual(noOpIntent.items.first?.hasExplicitTag, false)
        XCTAssertNil(store.apply(noOpIntent))

        // Undo should immediately revert the warmup -> normal reset (not a phantom no-op entry).
        store.undoLastMutation()
        XCTAssertEqual(store.activeSession?.sortedEntries.first?.sortedSets.first?.tag, .warmup)
    }

    // MARK: - Fixture Helper

    private func makeSession(
        in context: ModelContext,
        startedAt: Date,
        exerciseName: String,
        canonicalName: String,
        muscleGroup: MuscleGroup,
        setCount: Int,
        reps: Int,
        weightKg: Double
    ) -> WorkoutSession {
        let session = WorkoutSession(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(2_400),
            title: "Workout",
            isActive: false
        )
        context.insert(session)

        let entry = ExerciseEntry(
            exerciseName: exerciseName,
            canonicalName: canonicalName,
            muscleGroup: muscleGroup,
            orderIndex: 0,
            createdAt: startedAt,
            session: nil
        )
        context.insert(entry)
        entry.session = session
        if !session.entries.contains(where: { $0.id == entry.id }) {
            session.entries.append(entry)
        }

        for idx in 1...setCount {
            let set = LoggedSet(
                setNumber: idx,
                reps: reps,
                weightKg: weightKg,
                loggedAt: startedAt.addingTimeInterval(TimeInterval(idx * 120)),
                entry: nil
            )
            context.insert(set)
            set.entry = entry
            if !entry.sets.contains(where: { $0.id == set.id }) {
                entry.sets.append(set)
            }
        }

        return session
    }
}
