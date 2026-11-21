import Foundation
import LLM

@Generatable
public enum LLMWorkoutAction: Sendable {
    case logSets
    case updateLastSet
    case deleteLastSet
    case deleteLastExercise
    case endSession
    case unknown
}

@Generatable
public enum LLMSetTag: Sendable {
    case normal
    case warmup
    case dropset
    case failure
}

@Generatable
public struct LLMParsedExerciseGroup: Sendable {
    public let exercise: String
    public let sets: Int
    public let reps: Int?
    public let weight: Double?
    public let unit: String?
    public let durationSeconds: Int?
    public let tag: LLMSetTag?
    public let note: String?

    public init(
        exercise: String,
        sets: Int,
        reps: Int? = nil,
        weight: Double? = nil,
        unit: String? = nil,
        durationSeconds: Int? = nil,
        tag: LLMSetTag? = nil,
        note: String? = nil
    ) {
        self.exercise = exercise
        self.sets = sets
        self.reps = reps
        self.weight = weight
        self.unit = unit
        self.durationSeconds = durationSeconds
        self.tag = tag
        self.note = note
    }
}

@Generatable
public struct LLMParsedVoiceCommand: Sendable {
    public let action: LLMWorkoutAction
    public let items: [LLMParsedExerciseGroup]
    public let summary: String

    public init(
        action: LLMWorkoutAction,
        items: [LLMParsedExerciseGroup],
        summary: String
    ) {
        self.action = action
        self.items = items
        self.summary = summary
    }
}

public extension LLMParsedVoiceCommand {
    func toDomainIntent(rawTranscript: String) -> WorkoutCommandIntent {
        let domainAction: WorkoutIntentAction
        switch action {
        case .logSets: domainAction = .logSets
        case .updateLastSet: domainAction = .updateLastSet
        case .deleteLastSet: domainAction = .deleteLastSet
        case .deleteLastExercise: domainAction = .deleteLastExercise
        case .endSession: domainAction = .endSession
        case .unknown: domainAction = .unknown
        }

        let mappedItems: [ParsedSetGroupIntent] = items.compactMap { group in
            let cleanedExercise = group.exercise.trimmingCharacters(in: .whitespacesAndNewlines)
            if domainAction == .logSets && cleanedExercise.isEmpty {
                return nil
            }

            let clampedSets = max(1, min(30, group.sets))
            let cleanedReps = group.reps.flatMap { $0 > 0 ? $0 : nil }
            let cleanedWeight = group.weight.flatMap { $0 > 0 ? $0 : nil }
            let cleanedDuration = group.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
            let cleanedUnit = Self.parseWeightUnit(group.unit)
            let mappedTag = Self.mapSetTag(group.tag)
            let cleanedNote = (group.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            return ParsedSetGroupIntent(
                exerciseName: cleanedExercise,
                setCount: clampedSets,
                reps: cleanedReps,
                weightValue: cleanedWeight,
                weightUnit: cleanedUnit,
                durationSeconds: cleanedDuration,
                tag: mappedTag,
                note: cleanedNote
            )
        }

        return WorkoutCommandIntent(
            action: domainAction,
            items: mappedItems,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            rawTranscript: rawTranscript,
            parserSource: .localLLM
        )
    }

    private static func mapSetTag(_ tag: LLMSetTag?) -> SetTag {
        switch tag {
        case .normal, .none: return .normal
        case .warmup: return .warmup
        case .dropset: return .dropset
        case .failure: return .failure
        }
    }

    private static func parseWeightUnit(_ raw: String?) -> WeightUnit? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "kg", "kgs", "kilo", "kilos", "kilogram", "kilograms":
            return .kg
        case "lb", "lbs", "pound", "pounds":
            return .lbs
        default:
            return nil
        }
    }
}
