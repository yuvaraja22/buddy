import Foundation

public enum WorkoutIntentAction: String, Codable, Equatable, Sendable {
    case logSets
    case updateLastSet
    case deleteLastSet
    case deleteLastExercise
    case endSession
    case unknown
}

public enum ParserSource: String, Codable, Equatable, Sendable {
    case localLLM = "Qwen2.5-1.5B"
    case ruleBased = "Instant Parser"
}

public struct ParsedSetGroupIntent: Codable, Equatable, Sendable {
    public let exerciseName: String
    public let setCount: Int
    public let reps: Int?
    public let weightValue: Double?
    public let weightUnit: WeightUnit?
    public let durationSeconds: Int?
    public let tag: SetTag
    public let hasExplicitTag: Bool
    public let note: String

    public init(
        exerciseName: String,
        setCount: Int = 1,
        reps: Int? = nil,
        weightValue: Double? = nil,
        weightUnit: WeightUnit? = nil,
        durationSeconds: Int? = nil,
        tag: SetTag = .normal,
        hasExplicitTag: Bool? = nil,
        note: String = ""
    ) {
        self.exerciseName = exerciseName
        self.setCount = max(1, setCount)
        self.reps = reps
        self.weightValue = weightValue
        self.weightUnit = weightUnit
        self.durationSeconds = durationSeconds
        self.tag = tag
        self.hasExplicitTag = hasExplicitTag ?? (tag != .normal)
        self.note = note
    }

    public func resolvedWeightKg(defaultUnit: WeightUnit) -> Double? {
        guard let weightValue, weightValue > 0 else { return nil }
        let unit = weightUnit ?? defaultUnit
        return unit.toKg(weightValue)
    }
}

public struct WorkoutCommandIntent: Codable, Equatable, Sendable {
    public let action: WorkoutIntentAction
    public let items: [ParsedSetGroupIntent]
    public let summary: String
    public let rawTranscript: String
    public let parserSource: ParserSource

    public init(
        action: WorkoutIntentAction,
        items: [ParsedSetGroupIntent] = [],
        summary: String = "",
        rawTranscript: String = "",
        parserSource: ParserSource = .localLLM
    ) {
        self.action = action
        self.items = items
        self.summary = summary
        self.rawTranscript = rawTranscript
        self.parserSource = parserSource
    }

    /// Number of distinct canonical exercises represented in `items`.
    public var distinctExerciseCount: Int {
        Set(items.map { ExerciseCatalog.resolve($0.exerciseName).canonicalName.lowercased() }).count
    }

    /// Auto-derived monochrome session title from the parsed exercise muscle groups.
    public var suggestedSessionTitle: String {
        let groups = Set(items.map { ExerciseCatalog.resolve($0.exerciseName).muscleGroup })
        guard !groups.isEmpty else { return "Workout" }
        let lowerGroups: Set<MuscleGroup> = [.quads, .hamstrings, .glutes, .calves]
        let pushGroups: Set<MuscleGroup> = [.chest, .shoulders, .triceps]
        let pullGroups: Set<MuscleGroup> = [.back, .biceps]

        if groups.isSubset(of: lowerGroups) { return "Leg Day" }
        if groups.isSubset(of: pushGroups) { return "Push Day" }
        if groups.isSubset(of: pullGroups) { return "Pull Day" }
        if groups == [.cardio] { return "Cardio" }
        if groups == [.core] { return "Core Session" }
        if groups.count == 1, let only = groups.first { return "\(only.rawValue) Day" }
        let upperGroups: Set<MuscleGroup> = [.chest, .back, .shoulders, .biceps, .triceps]
        if groups.isSubset(of: upperGroups.union([.core])) { return "Upper Body" }
        return "Full Body"
    }
}

public struct PendingSessionRecap: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var items: [ParsedSetGroupIntent]
    public var rawTranscript: String
    public var parserSource: ParserSource
    public var targetDate: Date
    public var suggestedTitle: String
    public var defaultFinishImmediately: Bool

    public init(
        id: UUID = UUID(),
        items: [ParsedSetGroupIntent],
        rawTranscript: String,
        parserSource: ParserSource,
        targetDate: Date = Date(),
        suggestedTitle: String = "Workout",
        defaultFinishImmediately: Bool = true
    ) {
        self.id = id
        self.items = items
        self.rawTranscript = rawTranscript
        self.parserSource = parserSource
        self.targetDate = targetDate
        self.suggestedTitle = suggestedTitle
        self.defaultFinishImmediately = defaultFinishImmediately
    }
}

public struct WorkoutMutationBanner: Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let rawTranscript: String
    public let parserSource: ParserSource
    public let editableSetID: UUID?
    public let editableEntryID: UUID?
    public let canUndo: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        rawTranscript: String = "",
        parserSource: ParserSource = .localLLM,
        editableSetID: UUID? = nil,
        editableEntryID: UUID? = nil,
        canUndo: Bool = true
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.rawTranscript = rawTranscript
        self.parserSource = parserSource
        self.editableSetID = editableSetID
        self.editableEntryID = editableEntryID
        self.canUndo = canUndo
    }
}

public struct ActiveSessionPromptContext: Equatable, Sendable {
    public let preferredUnit: WeightUnit
    public let lastExerciseName: String?
    public let recentExercisesInSession: [String]
    public let isSessionActive: Bool

    public init(
        preferredUnit: WeightUnit = .kg,
        lastExerciseName: String? = nil,
        recentExercisesInSession: [String] = [],
        isSessionActive: Bool = false
    ) {
        self.preferredUnit = preferredUnit
        self.lastExerciseName = lastExerciseName
        self.recentExercisesInSession = recentExercisesInSession
        self.isSessionActive = isSessionActive
    }
}
