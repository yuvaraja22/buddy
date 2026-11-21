import Foundation

public struct ActiveSessionSnapshot: Codable, Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let startedAt: Date
    public let totalSets: Int
    public let totalReps: Int
    public let totalVolumeKg: Double
    public let exerciseCount: Int
    public let lastExerciseName: String?
    public let lastSetSummary: String?

    public init(
        sessionID: String,
        title: String,
        startedAt: Date,
        totalSets: Int,
        totalReps: Int,
        totalVolumeKg: Double,
        exerciseCount: Int,
        lastExerciseName: String?,
        lastSetSummary: String?
    ) {
        self.sessionID = sessionID
        self.title = title
        self.startedAt = startedAt
        self.totalSets = totalSets
        self.totalReps = totalReps
        self.totalVolumeKg = totalVolumeKg
        self.exerciseCount = exerciseCount
        self.lastExerciseName = lastExerciseName
        self.lastSetSummary = lastSetSummary
    }
}

public struct ExerciseSummarySnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let setCount: Int
    public let summary: String

    public init(id: String, name: String, setCount: Int, summary: String) {
        self.id = id
        self.name = name
        self.setCount = setCount
        self.summary = summary
    }
}

public struct DayActivitySnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let weekdayLabel: String
    public let date: Date
    public let setCount: Int
    public let volumeKg: Double
    public let isToday: Bool

    public init(
        id: String,
        weekdayLabel: String,
        date: Date,
        setCount: Int,
        volumeKg: Double,
        isToday: Bool
    ) {
        self.id = id
        self.weekdayLabel = weekdayLabel
        self.date = date
        self.setCount = setCount
        self.volumeKg = volumeKg
        self.isToday = isToday
    }
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let updatedAt: Date
    public let preferredUnit: WeightUnit
    public let activeSession: ActiveSessionSnapshot?
    public let todaySets: Int
    public let todayReps: Int
    public let todayVolumeKg: Double
    public let todayExercises: [ExerciseSummarySnapshot]
    public let lastTodayExerciseName: String?
    public let lastTodaySetSummary: String?
    public let currentStreakDays: Int
    public let workoutsThisWeek: Int
    public let weeklyGoal: Int
    public let weeklyDays: [DayActivitySnapshot]

    public init(
        updatedAt: Date = Date(),
        preferredUnit: WeightUnit = .kg,
        activeSession: ActiveSessionSnapshot? = nil,
        todaySets: Int = 0,
        todayReps: Int = 0,
        todayVolumeKg: Double = 0,
        todayExercises: [ExerciseSummarySnapshot] = [],
        lastTodayExerciseName: String? = nil,
        lastTodaySetSummary: String? = nil,
        currentStreakDays: Int = 0,
        workoutsThisWeek: Int = 0,
        weeklyGoal: Int = 4,
        weeklyDays: [DayActivitySnapshot] = []
    ) {
        self.updatedAt = updatedAt
        self.preferredUnit = preferredUnit
        self.activeSession = activeSession
        self.todaySets = todaySets
        self.todayReps = todayReps
        self.todayVolumeKg = todayVolumeKg
        self.todayExercises = todayExercises
        self.lastTodayExerciseName = lastTodayExerciseName
        self.lastTodaySetSummary = lastTodaySetSummary
        self.currentStreakDays = currentStreakDays
        self.workoutsThisWeek = workoutsThisWeek
        self.weeklyGoal = weeklyGoal
        self.weeklyDays = weeklyDays
    }

    /// Normalizes a persisted snapshot across midnight / multi-day rollovers so widgets
    /// never display yesterday's completed sets as "Today's Workout" or stale `isToday` bars.
    public func normalized(for referenceDate: Date = Date(), calendar: Calendar = .current) -> WidgetSnapshot {
        guard !calendar.isDate(updatedAt, inSameDayAs: referenceDate) else {
            return self
        }

        let today = calendar.startOfDay(for: referenceDate)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "EEEEE"
        let iso = ISO8601DateFormatter()

        var byDay: [Date: DayActivitySnapshot] = [:]
        for item in weeklyDays {
            byDay[calendar.startOfDay(for: item.date)] = item
        }

        let shiftedDays: [DayActivitySnapshot] = (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let existing = byDay[day]
            return DayActivitySnapshot(
                id: existing?.id ?? iso.string(from: day),
                weekdayLabel: formatter.string(from: day),
                date: day,
                setCount: existing?.setCount ?? 0,
                volumeKg: existing?.volumeKg ?? 0,
                isToday: offset == 0
            )
        }

        // Preserve streak only if yesterday (or today via active session) had activity.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let hadActivityYesterday = yesterday.flatMap { byDay[$0] }.map { $0.setCount > 0 || $0.volumeKg > 0 } ?? false
        let updatedDayDiff = calendar.dateComponents([.day], from: calendar.startOfDay(for: updatedAt), to: today).day ?? 2
        let adjustedStreak: Int
        if activeSession != nil {
            adjustedStreak = currentStreakDays
        } else if updatedDayDiff == 1 && (hadActivityYesterday || todaySets > 0) {
            adjustedStreak = currentStreakDays
        } else {
            adjustedStreak = 0
        }

        let activeDaysThisWeek = shiftedDays.filter { $0.setCount > 0 || $0.volumeKg > 0 }.count

        return WidgetSnapshot(
            updatedAt: referenceDate,
            preferredUnit: preferredUnit,
            activeSession: activeSession,
            todaySets: activeSession?.totalSets ?? 0,
            todayReps: activeSession?.totalReps ?? 0,
            todayVolumeKg: activeSession?.totalVolumeKg ?? 0,
            todayExercises: activeSession == nil ? [] : todayExercises,
            lastTodayExerciseName: activeSession?.lastExerciseName,
            lastTodaySetSummary: activeSession?.lastSetSummary,
            currentStreakDays: adjustedStreak,
            workoutsThisWeek: activeDaysThisWeek,
            weeklyGoal: weeklyGoal,
            weeklyDays: shiftedDays
        )
    }

    public static var empty: WidgetSnapshot {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        let days: [DayActivitySnapshot] = (0..<7).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayActivitySnapshot(
                id: ISO8601DateFormatter().string(from: day),
                weekdayLabel: formatter.string(from: day),
                date: day,
                setCount: 0,
                volumeKg: 0,
                isToday: offset == 0
            )
        }
        return WidgetSnapshot(weeklyDays: days)
    }

    public static var placeholder: WidgetSnapshot {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        let sampleSets = [12, 0, 15, 10, 0, 14, 9]
        let sampleVols: [Double] = [4200, 0, 5800, 3900, 0, 5100, 3450]
        let days: [DayActivitySnapshot] = (0..<7).reversed().enumerated().compactMap { idx, offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayActivitySnapshot(
                id: "sample-\(idx)",
                weekdayLabel: formatter.string(from: day),
                date: day,
                setCount: sampleSets[idx],
                volumeKg: sampleVols[idx],
                isToday: offset == 0
            )
        }
        return WidgetSnapshot(
            updatedAt: Date(),
            preferredUnit: .kg,
            activeSession: ActiveSessionSnapshot(
                sessionID: "preview",
                title: "Lower Body",
                startedAt: Date().addingTimeInterval(-1420),
                totalSets: 9,
                totalReps: 115,
                totalVolumeKg: 3450,
                exerciseCount: 3,
                lastExerciseName: "Leg Extension",
                lastSetSummary: "3 × 15 · 45 kg"
            ),
            todaySets: 9,
            todayReps: 115,
            todayVolumeKg: 3450,
            todayExercises: [
                ExerciseSummarySnapshot(id: "1", name: "Leg Extension", setCount: 3, summary: "3 × 15 · 45 kg"),
                ExerciseSummarySnapshot(id: "2", name: "Romanian Deadlift", setCount: 3, summary: "3 × 10 · 70 kg"),
                ExerciseSummarySnapshot(id: "3", name: "Leg Press", setCount: 3, summary: "3 × 12 · 120 kg")
            ],
            lastTodayExerciseName: "Leg Extension",
            lastTodaySetSummary: "3 × 15 · 45 kg",
            currentStreakDays: 4,
            workoutsThisWeek: 4,
            weeklyGoal: 4,
            weeklyDays: days
        )
    }

    public static func save(_ snapshot: WidgetSnapshot, to url: URL = AppGroupResolver.widgetSnapshotURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL = AppGroupResolver.widgetSnapshotURL) -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WidgetSnapshot.self, from: data)) ?? .empty
    }
}
