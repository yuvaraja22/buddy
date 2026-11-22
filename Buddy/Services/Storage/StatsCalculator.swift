import Foundation

public enum TrendTimeframe: String, CaseIterable, Identifiable, Sendable {
    case week = "1W"
    case month = "1M"
    case threeMonths = "3M"

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .threeMonths: return 90
        }
    }
}

public struct VolumePoint: Identifiable, Equatable, Sendable {
    public let id: Date
    public let date: Date
    public let label: String
    public let volumeKg: Double
    public let setCount: Int
    public let repCount: Int

    public init(
        id: Date,
        date: Date,
        label: String,
        volumeKg: Double,
        setCount: Int,
        repCount: Int
    ) {
        self.id = id
        self.date = date
        self.label = label
        self.volumeKg = volumeKg
        self.setCount = setCount
        self.repCount = repCount
    }
}

public struct ExerciseProgressPoint: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let maxWeightKg: Double
    public let totalVolumeKg: Double
    public let totalReps: Int
    public let setCount: Int

    public init(
        id: UUID = UUID(),
        date: Date,
        maxWeightKg: Double,
        totalVolumeKg: Double,
        totalReps: Int,
        setCount: Int
    ) {
        self.id = id
        self.date = date
        self.maxWeightKg = maxWeightKg
        self.totalVolumeKg = totalVolumeKg
        self.totalReps = totalReps
        self.setCount = setCount
    }
}

public struct HeatmapDay: Identifiable, Equatable, Sendable {
    public let id: Date
    public let date: Date
    public let setCount: Int
    public let volumeKg: Double
    public let intensity: Int

    public init(
        id: Date,
        date: Date,
        setCount: Int,
        volumeKg: Double,
        intensity: Int
    ) {
        self.id = id
        self.date = date
        self.setCount = setCount
        self.volumeKg = volumeKg
        self.intensity = min(4, max(0, intensity))
    }
}

public struct ConsistencyStats: Equatable, Sendable {
    public let currentStreakDays: Int
    public let longestStreakDays: Int
    public let workoutsThisWeek: Int
    public let totalWorkouts: Int
    public let weeklyGoal: Int

    public init(
        currentStreakDays: Int,
        longestStreakDays: Int,
        workoutsThisWeek: Int,
        totalWorkouts: Int,
        weeklyGoal: Int
    ) {
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.workoutsThisWeek = workoutsThisWeek
        self.totalWorkouts = totalWorkouts
        self.weeklyGoal = weeklyGoal
    }
}

public enum StatsCalculator {
    private struct DayTotals {
        var setCount: Int = 0
        var repCount: Int = 0
        var volumeKg: Double = 0
        var hasCheckIn: Bool = false
    }

    // MARK: - Consistency & Streaks

    public static func consistency(
        sessions: [WorkoutSession],
        referenceDate: Date = Date(),
        weeklyGoal: Int = 4
    ) -> ConsistencyStats {
        let goal = max(1, weeklyGoal)
        let calendar = Calendar.current
        let loggedSessions = sessions.filter { $0.countsAsWorkout }

        guard !loggedSessions.isEmpty else {
            return ConsistencyStats(
                currentStreakDays: 0,
                longestStreakDays: 0,
                workoutsThisWeek: 0,
                totalWorkouts: 0,
                weeklyGoal: goal
            )
        }

        let today = calendar.startOfDay(for: referenceDate)
        let workoutDays = Set(loggedSessions.map { calendar.startOfDay(for: $0.startedAt) })

        // Current streak: counts backwards from today, or from yesterday if user hasn't trained yet today
        var currentStreak = 0
        var cursor: Date?
        if workoutDays.contains(today) {
            cursor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  workoutDays.contains(yesterday) {
            cursor = yesterday
        }

        while let day = cursor, workoutDays.contains(day) {
            currentStreak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }

        // Longest streak across all recorded workout days
        let sortedDays = workoutDays.sorted()
        var longestStreak = 0
        var activeRun = 0
        var previousDay: Date?

        for day in sortedDays {
            if let prev = previousDay,
               let expectedNext = calendar.date(byAdding: .day, value: 1, to: prev),
               calendar.isDate(expectedNext, inSameDayAs: day) {
                activeRun += 1
            } else {
                activeRun = 1
            }
            if activeRun > longestStreak {
                longestStreak = activeRun
            }
            previousDay = day
        }
        longestStreak = max(longestStreak, currentStreak)

        // Workouts in the current calendar week
        let workoutsThisWeek: Int
        if let weekInterval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) {
            workoutsThisWeek = loggedSessions.filter { weekInterval.contains($0.startedAt) }.count
        } else if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today) {
            workoutsThisWeek = loggedSessions.filter {
                $0.startedAt >= weekAgo && $0.startedAt <= referenceDate
            }.count
        } else {
            workoutsThisWeek = 0
        }

        return ConsistencyStats(
            currentStreakDays: currentStreak,
            longestStreakDays: longestStreak,
            workoutsThisWeek: workoutsThisWeek,
            totalWorkouts: loggedSessions.count,
            weeklyGoal: goal
        )
    }

    // MARK: - Heatmap

    public static func heatmapDays(
        sessions: [WorkoutSession],
        weeks: Int = 12,
        referenceDate: Date = Date()
    ) -> [HeatmapDay] {
        let calendar = Calendar.current
        let totalDays = max(1, weeks) * 7
        let today = calendar.startOfDay(for: referenceDate)
        let totalsByDay = aggregateByDay(sessions: sessions, calendar: calendar)

        return (0..<totalDays).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let totals = totalsByDay[day] ?? DayTotals()
            let intensity = totals.setCount > 0
                ? intensityLevel(forSetCount: totals.setCount)
                : (totals.hasCheckIn ? 1 : 0)
            return HeatmapDay(
                id: day,
                date: day,
                setCount: totals.setCount,
                volumeKg: totals.volumeKg,
                intensity: intensity
            )
        }
    }

    private static func intensityLevel(forSetCount setCount: Int) -> Int {
        switch setCount {
        case ...0: return 0
        case 1...4: return 1
        case 5...9: return 2
        case 10...15: return 3
        default: return 4
        }
    }

    // MARK: - Volume Trend Series

    public static func volumeSeries(
        sessions: [WorkoutSession],
        timeframe: TrendTimeframe,
        referenceDate: Date = Date()
    ) -> [VolumePoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let totalsByDay = aggregateByDay(sessions: sessions, calendar: calendar)

        switch timeframe {
        case .week:
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return (0..<7).reversed().compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                    return nil
                }
                let totals = totalsByDay[day] ?? DayTotals()
                return VolumePoint(
                    id: day,
                    date: day,
                    label: formatter.string(from: day),
                    volumeKg: totals.volumeKg,
                    setCount: totals.setCount,
                    repCount: totals.repCount
                )
            }

        case .month:
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return (0..<30).reversed().compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                    return nil
                }
                let totals = totalsByDay[day] ?? DayTotals()
                return VolumePoint(
                    id: day,
                    date: day,
                    label: formatter.string(from: day),
                    volumeKg: totals.volumeKg,
                    setCount: totals.setCount,
                    repCount: totals.repCount
                )
            }

        case .threeMonths:
            // 13 weekly buckets covering the 90-day window ending on `today`
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            let bucketCount = 13
            var points: [VolumePoint] = []
            points.reserveCapacity(bucketCount)

            for bucketIndex in 0..<bucketCount {
                let startOffset = -((bucketCount - 1 - bucketIndex) * 7 + 6)
                guard let bucketStart = calendar.date(byAdding: .day, value: startOffset, to: today) else {
                    continue
                }
                var sumVolume = 0.0
                var sumSets = 0
                var sumReps = 0

                for dayOffset in 0..<7 {
                    guard let day = calendar.date(byAdding: .day, value: dayOffset, to: bucketStart) else {
                        continue
                    }
                    if let totals = totalsByDay[day] {
                        sumVolume += totals.volumeKg
                        sumSets += totals.setCount
                        sumReps += totals.repCount
                    }
                }

                points.append(
                    VolumePoint(
                        id: bucketStart,
                        date: bucketStart,
                        label: formatter.string(from: bucketStart),
                        volumeKg: sumVolume,
                        setCount: sumSets,
                        repCount: sumReps
                    )
                )
            }
            return points
        }
    }

    // MARK: - Exercise Analytics

    public static func loggedExerciseNames(sessions: [WorkoutSession]) -> [String] {
        struct ExerciseMeta {
            var displayName: String
            var entryCount: Int
            var lastLoggedAt: Date
        }

        var map: [String: ExerciseMeta] = [:]

        for session in sessions {
            for entry in session.entries where !entry.sets.isEmpty {
                let key = entry.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty else { continue }

                let latestSetDate = entry.sets.map(\.loggedAt).max() ?? entry.createdAt
                if var existing = map[key] {
                    existing.entryCount += 1
                    if latestSetDate > existing.lastLoggedAt {
                        existing.lastLoggedAt = latestSetDate
                        existing.displayName = entry.canonicalName
                    }
                    map[key] = existing
                } else {
                    map[key] = ExerciseMeta(
                        displayName: entry.canonicalName,
                        entryCount: 1,
                        lastLoggedAt: latestSetDate
                    )
                }
            }
        }

        return map.values
            .sorted { lhs, rhs in
                if lhs.entryCount != rhs.entryCount {
                    return lhs.entryCount > rhs.entryCount
                }
                if lhs.lastLoggedAt != rhs.lastLoggedAt {
                    return lhs.lastLoggedAt > rhs.lastLoggedAt
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .map(\.displayName)
    }

    public static func exerciseProgression(
        canonicalName: String,
        sessions: [WorkoutSession]
    ) -> [ExerciseProgressPoint] {
        let target = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return [] }

        var points: [ExerciseProgressPoint] = []

        for session in sessions {
            let matchingEntries = session.entries.filter { entry in
                !entry.sets.isEmpty && (
                    entry.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target ||
                    entry.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
                )
            }
            guard !matchingEntries.isEmpty else { continue }

            let allSets = matchingEntries.flatMap(\.sets)
            let maxWeight = allSets.compactMap(\.weightKg).max() ?? 0
            let totalVolume = allSets.reduce(0.0) { $0 + $1.volumeKg }
            let totalReps = allSets.reduce(0) { $0 + ($1.reps ?? 0) }

            points.append(
                ExerciseProgressPoint(
                    id: session.id,
                    date: session.startedAt,
                    maxWeightKg: maxWeight,
                    totalVolumeKg: totalVolume,
                    totalReps: totalReps,
                    setCount: allSets.count
                )
            )
        }

        return points.sorted { $0.date < $1.date }
    }

    // MARK: - Widget Snapshot

    public static func buildWidgetSnapshot(
        sessions: [WorkoutSession],
        preferredUnit: WeightUnit,
        referenceDate: Date = Date(),
        weeklyGoal: Int = 4
    ) -> WidgetSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let stats = consistency(sessions: sessions, referenceDate: referenceDate, weeklyGoal: weeklyGoal)

        // Active session snapshot (deterministically pick newest if multiple exist)
        let activeSnapshot: ActiveSessionSnapshot?
        if let active = sessions.filter(\.isActive).sorted(by: { $0.startedAt > $1.startedAt }).first {
            let lastEntry = mostRecentlyUpdatedEntry(in: active)
            activeSnapshot = ActiveSessionSnapshot(
                sessionID: active.id.uuidString,
                title: active.derivedTitle,
                startedAt: active.startedAt,
                totalSets: active.totalSets,
                totalReps: active.totalReps,
                totalVolumeKg: active.totalVolumeKg,
                exerciseCount: active.exerciseCount,
                lastExerciseName: lastEntry?.exerciseName,
                lastSetSummary: lastEntry?.compactSummary(unit: preferredUnit)
            )
        } else {
            activeSnapshot = nil
        }

        // Today's totals and exercise summaries
        let todaySessions = sessions
            .filter { calendar.isDate($0.startedAt, inSameDayAs: referenceDate) || $0.isActive }
            .sorted(by: { $0.startedAt > $1.startedAt })
        let todaySets = todaySessions.reduce(0) { $0 + $1.totalSets }
        let todayReps = todaySessions.reduce(0) { $0 + $1.totalReps }
        let todayVolumeKg = todaySessions.reduce(0.0) { $0 + $1.totalVolumeKg }

        var seenEntryIDs = Set<UUID>()
        var todayExercises: [ExerciseSummarySnapshot] = []
        for session in todaySessions {
            for entry in session.sortedEntries where !entry.sets.isEmpty {
                guard seenEntryIDs.insert(entry.id).inserted else { continue }
                todayExercises.append(
                    ExerciseSummarySnapshot(
                        id: entry.id.uuidString,
                        name: entry.exerciseName,
                        setCount: entry.sets.count,
                        summary: entry.compactSummary(unit: preferredUnit)
                    )
                )
                if todayExercises.count >= 6 { break }
            }
            if todayExercises.count >= 6 { break }
        }

        // Most recently logged exercise across all of today's sessions (by latest set timestamp)
        let mostRecentTodayEntry: ExerciseEntry? = todaySessions
            .compactMap { mostRecentlyUpdatedEntry(in: $0) }
            .max { lhs, rhs in
                let lDate = lhs.sets.map(\.loggedAt).max() ?? lhs.createdAt
                let rDate = rhs.sets.map(\.loggedAt).max() ?? rhs.createdAt
                return lDate < rDate
            }

        // Last 7 days activity bars
        let totalsByDay = aggregateByDay(sessions: sessions, calendar: calendar)
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEEE"
        let isoFormatter = ISO8601DateFormatter()

        let weeklyDays: [DayActivitySnapshot] = (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let totals = totalsByDay[day] ?? DayTotals()
            return DayActivitySnapshot(
                id: isoFormatter.string(from: day),
                weekdayLabel: weekdayFormatter.string(from: day),
                date: day,
                setCount: totals.setCount > 0 ? totals.setCount : (totals.hasCheckIn ? 1 : 0),
                volumeKg: totals.volumeKg,
                isToday: offset == 0
            )
        }

        return WidgetSnapshot(
            updatedAt: referenceDate,
            preferredUnit: preferredUnit,
            activeSession: activeSnapshot,
            todaySets: todaySets,
            todayReps: todayReps,
            todayVolumeKg: todayVolumeKg,
            todayExercises: todayExercises,
            lastTodayExerciseName: mostRecentTodayEntry?.exerciseName,
            lastTodaySetSummary: mostRecentTodayEntry?.compactSummary(unit: preferredUnit),
            currentStreakDays: stats.currentStreakDays,
            workoutsThisWeek: stats.workoutsThisWeek,
            weeklyGoal: stats.weeklyGoal,
            weeklyDays: weeklyDays
        )
    }

    // MARK: - Local AI Coach Context (~250-300 tokens)

    public static func buildCoachContext(
        sessions: [WorkoutSession],
        preferredUnit: WeightUnit,
        weeklyGoal: Int = 4
    ) -> String {
        let loggedSessions = sessions
            .filter { $0.countsAsWorkout }
            .sorted { $0.startedAt > $1.startedAt }

        guard !loggedSessions.isEmpty || sessions.contains(where: { $0.isActive }) else {
            return "User unit: \(preferredUnit.rawValue). Weekly goal: \(max(1, weeklyGoal)) days. No workouts logged yet. Streak: 0d."
        }

        let stats = consistency(sessions: sessions, weeklyGoal: weeklyGoal)
        var lines: [String] = []
        lines.append(
            "User unit: \(preferredUnit.rawValue). Total workouts: \(stats.totalWorkouts). " +
            "Streak: \(stats.currentStreakDays)d (best \(stats.longestStreakDays)d). " +
            "This week: \(stats.workoutsThisWeek)/\(stats.weeklyGoal)."
        )

        if let active = sessions.first(where: { $0.isActive }) {
            let exSummaries = active.sortedEntries.prefix(5).map {
                "\($0.exerciseName) (\($0.compactSummary(unit: preferredUnit)))"
            }.joined(separator: "; ")
            let exText = exSummaries.isEmpty ? "no sets yet" : exSummaries
            lines.append(
                "Active session: \(active.derivedTitle) — \(active.totalSets) sets, " +
                "\(preferredUnit.formatVolume(kg: active.totalVolumeKg)) [\(exText)]."
            )
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"

        let recentWorkouts = loggedSessions.filter { !$0.isActive }.prefix(5)
        if !recentWorkouts.isEmpty {
            lines.append("Recent workouts:")
            for session in recentWorkouts {
                let dateLabel = dateFormatter.string(from: session.startedAt)
                if session.totalSets == 0 && session.isManualCheckInDay {
                    let noteSuffix = session.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? ""
                        : " — \(session.notes.trimmingCharacters(in: .whitespacesAndNewlines))"
                    lines.append("- \(dateLabel) \(session.derivedTitle): manual check-in\(noteSuffix)")
                } else {
                    let topExercises = session.sortedEntries.prefix(3).map {
                        "\($0.exerciseName) \($0.compactSummary(unit: preferredUnit))"
                    }.joined(separator: ", ")
                    lines.append(
                        "- \(dateLabel) \(session.derivedTitle): \(session.totalSets) sets, " +
                        "\(preferredUnit.formatVolume(kg: session.totalVolumeKg)) (\(topExercises))"
                    )
                }
            }
        }

        let topExerciseNames = loggedExerciseNames(sessions: loggedSessions).prefix(6)
        if !topExerciseNames.isEmpty {
            lines.append("Top exercises:")
            for name in topExerciseNames {
                let history = exerciseProgression(canonicalName: name, sessions: loggedSessions)
                guard !history.isEmpty else { continue }
                let bestWeight = history.map(\.maxWeightKg).max() ?? 0
                let bestVolume = history.map(\.totalVolumeKg).max() ?? 0
                let totalSets = history.reduce(0) { $0 + $1.setCount }

                var metricParts: [String] = []
                if bestWeight > 0 {
                    metricParts.append("max \(preferredUnit.formatWeight(kg: bestWeight))")
                }
                if bestVolume > 0 {
                    metricParts.append("best vol \(preferredUnit.formatVolume(kg: bestVolume))")
                }
                metricParts.append("\(totalSets) sets/\(history.count)x")
                lines.append("- \(name): \(metricParts.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private static func aggregateByDay(
        sessions: [WorkoutSession],
        calendar: Calendar
    ) -> [Date: DayTotals] {
        var map: [Date: DayTotals] = [:]
        for session in sessions where session.countsAsWorkout {
            let day = calendar.startOfDay(for: session.startedAt)
            var totals = map[day] ?? DayTotals()
            totals.setCount += session.totalSets
            totals.repCount += session.totalReps
            totals.volumeKg += session.totalVolumeKg
            if session.isManualCheckInDay {
                totals.hasCheckIn = true
            }
            map[day] = totals
        }
        return map
    }

    private static func mostRecentlyUpdatedEntry(in session: WorkoutSession) -> ExerciseEntry? {
        var bestEntry: ExerciseEntry?
        var bestDate = Date.distantPast
        var bestOrder = Int.min

        for entry in session.entries {
            let latestDate = entry.sets.map(\.loggedAt).max() ?? entry.createdAt
            if latestDate > bestDate || (latestDate == bestDate && entry.orderIndex > bestOrder) {
                bestDate = latestDate
                bestOrder = entry.orderIndex
                bestEntry = entry
            }
        }
        return bestEntry ?? session.sortedEntries.last
    }
}
