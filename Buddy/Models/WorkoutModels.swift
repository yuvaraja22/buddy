import Foundation
import SwiftData

public enum MuscleGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case quads = "Quads"
    case hamstrings = "Hamstrings"
    case glutes = "Glutes"
    case calves = "Calves"
    case chest = "Chest"
    case back = "Back"
    case shoulders = "Shoulders"
    case biceps = "Biceps"
    case triceps = "Triceps"
    case core = "Core"
    case cardio = "Cardio"
    case fullBody = "Full Body"
    case other = "Other"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .quads, .hamstrings, .glutes, .calves: return "figure.run"
        case .chest, .shoulders, .triceps: return "figure.strengthtraining.traditional"
        case .back, .biceps: return "dumbbell.fill"
        case .core: return "figure.core.training"
        case .cardio: return "heart.fill"
        case .fullBody, .other: return "bolt.fill"
        }
    }

    public var thumbnailAssetName: String {
        switch self {
        case .quads, .hamstrings, .glutes, .calves:
            return "WorkoutThumbLegs"
        case .chest:
            return "WorkoutThumbChest"
        case .back:
            return "WorkoutThumbBack"
        case .shoulders:
            return "WorkoutThumbShoulders"
        case .biceps, .triceps:
            return "WorkoutThumbArms"
        case .core:
            return "WorkoutThumbCore"
        case .cardio, .fullBody, .other:
            return "WorkoutThumbFullBody"
        }
    }
}

public enum SetTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case warmup
    case dropset
    case failure

    public var id: String { rawValue }

    public var displayLabel: String {
        switch self {
        case .normal: return "Working"
        case .warmup: return "Warmup"
        case .dropset: return "Drop Set"
        case .failure: return "Failure"
        }
    }

    public var shortBadge: String? {
        switch self {
        case .normal: return nil
        case .warmup: return "W"
        case .dropset: return "D"
        case .failure: return "F"
        }
    }
}

@Model
public final class WorkoutSession {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String
    public var notes: String
    public var isActive: Bool

    @Relationship(deleteRule: .cascade, inverse: \ExerciseEntry.session)
    public var entries: [ExerciseEntry]

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        title: String = "Workout",
        notes: String = "",
        isActive: Bool = true,
        entries: [ExerciseEntry] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.notes = notes
        self.isActive = isActive
        self.entries = entries
    }

    public var sortedEntries: [ExerciseEntry] {
        entries.sorted { lhs, rhs in
            if lhs.orderIndex != rhs.orderIndex {
                return lhs.orderIndex < rhs.orderIndex
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    public var durationSeconds: Int {
        let end = endedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }

    public var totalSets: Int {
        entries.reduce(0) { $0 + $1.sets.count }
    }

    public var totalReps: Int {
        entries.reduce(0) { $0 + $1.totalReps }
    }

    public var totalVolumeKg: Double {
        entries.reduce(0) { $0 + $1.totalVolumeKg }
    }

    public var totalTimedSeconds: Int {
        entries.reduce(0) { $0 + $1.totalTimedSeconds }
    }

    public var exerciseCount: Int {
        entries.count
    }

    public var derivedTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title != "Workout" {
            return title
        }
        let groups = Set(entries.map(\.muscleGroup))
        if groups.isEmpty { return "Workout" }
        let lowerGroups: Set<MuscleGroup> = [.quads, .hamstrings, .glutes, .calves]
        let pushGroups: Set<MuscleGroup> = [.chest, .shoulders, .triceps]
        let pullGroups: Set<MuscleGroup> = [.back, .biceps]

        if groups.isSubset(of: lowerGroups) { return "Lower Body" }
        if groups.isSubset(of: pushGroups) { return "Push Session" }
        if groups.isSubset(of: pullGroups) { return "Pull Session" }
        if groups == [.cardio] { return "Cardio" }
        if groups == [.core] { return "Core Session" }
        if groups.count == 1, let only = groups.first { return "\(only.rawValue) Session" }
        if let first = sortedEntries.first {
            return sortedEntries.count > 1 ? "\(first.exerciseName) + \(sortedEntries.count - 1)" : first.exerciseName
        }
        return "Full Body"
    }
}

@Model
public final class ExerciseEntry {
    public var id: UUID
    public var exerciseName: String
    public var canonicalName: String
    public var muscleGroupRaw: String
    public var orderIndex: Int
    public var createdAt: Date

    public var session: WorkoutSession?

    @Relationship(deleteRule: .cascade, inverse: \LoggedSet.entry)
    public var sets: [LoggedSet]

    public init(
        id: UUID = UUID(),
        exerciseName: String,
        canonicalName: String,
        muscleGroup: MuscleGroup = .other,
        orderIndex: Int = 0,
        createdAt: Date = Date(),
        session: WorkoutSession? = nil,
        sets: [LoggedSet] = []
    ) {
        self.id = id
        self.exerciseName = exerciseName
        self.canonicalName = canonicalName
        self.muscleGroupRaw = muscleGroup.rawValue
        self.orderIndex = orderIndex
        self.createdAt = createdAt
        self.session = session
        self.sets = sets
    }

    public var muscleGroup: MuscleGroup {
        get { MuscleGroup(rawValue: muscleGroupRaw) ?? .other }
        set { muscleGroupRaw = newValue.rawValue }
    }

    public var sortedSets: [LoggedSet] {
        sets.sorted { lhs, rhs in
            if lhs.setNumber != rhs.setNumber {
                return lhs.setNumber < rhs.setNumber
            }
            return lhs.loggedAt < rhs.loggedAt
        }
    }

    public var totalReps: Int {
        sets.reduce(0) { $0 + ($1.reps ?? 0) }
    }

    public var totalVolumeKg: Double {
        sets.reduce(0.0) { $0 + $1.volumeKg }
    }

    public var totalTimedSeconds: Int {
        sets.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
    }

    public var maxWeightKg: Double? {
        sets.compactMap(\.weightKg).max()
    }

    public func compactSummary(unit: WeightUnit) -> String {
        let ordered = sortedSets
        guard let first = ordered.first else { return "0 sets" }
        if let reps = first.reps {
            let allSameReps = ordered.allSatisfy { $0.reps == reps }
            let allSameWeight = ordered.allSatisfy { $0.weightKg == first.weightKg }
            if allSameReps && allSameWeight {
                if let weight = first.weightKg, weight > 0 {
                    return "\(ordered.count) × \(reps) · \(unit.formatWeight(kg: weight))"
                }
                return "\(ordered.count) × \(reps)"
            }
            if let top = maxWeightKg, top > 0 {
                return "\(ordered.count) sets · up to \(unit.formatWeight(kg: top))"
            }
            return "\(ordered.count) sets · \(totalReps) reps"
        }
        if totalTimedSeconds > 0 {
            return "\(ordered.count) × \(DurationFormatter.formatCompact(seconds: first.durationSeconds ?? totalTimedSeconds))"
        }
        return "\(ordered.count) sets"
    }
}

@Model
public final class LoggedSet {
    public var id: UUID
    public var setNumber: Int
    public var reps: Int?
    public var weightKg: Double?
    public var durationSeconds: Int?
    public var tagRaw: String
    public var notes: String
    public var rawTranscript: String
    public var loggedAt: Date

    public var entry: ExerciseEntry?

    public init(
        id: UUID = UUID(),
        setNumber: Int,
        reps: Int? = nil,
        weightKg: Double? = nil,
        durationSeconds: Int? = nil,
        tag: SetTag = .normal,
        notes: String = "",
        rawTranscript: String = "",
        loggedAt: Date = Date(),
        entry: ExerciseEntry? = nil
    ) {
        self.id = id
        self.setNumber = setNumber
        self.reps = reps
        self.weightKg = weightKg
        self.durationSeconds = durationSeconds
        self.tagRaw = tag.rawValue
        self.notes = notes
        self.rawTranscript = rawTranscript
        self.loggedAt = loggedAt
        self.entry = entry
    }

    public var tag: SetTag {
        get { SetTag(rawValue: tagRaw) ?? .normal }
        set { tagRaw = newValue.rawValue }
    }

    public var volumeKg: Double {
        guard let reps, let weightKg, reps > 0, weightKg > 0 else { return 0 }
        return Double(reps) * weightKg
    }

    public func formattedDetail(unit: WeightUnit) -> String {
        var parts: [String] = []
        if let weightKg, weightKg > 0 {
            parts.append(unit.formatWeight(kg: weightKg))
        }
        if let reps, reps > 0 {
            parts.append("\(reps) reps")
        }
        if let durationSeconds, durationSeconds > 0 {
            parts.append(DurationFormatter.formatCompact(seconds: durationSeconds))
        }
        return parts.isEmpty ? "Completed" : parts.joined(separator: " · ")
    }
}

@Model
public final class CoachMessage {
    public var id: UUID
    public var roleRaw: String
    public var content: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: CoachRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = createdAt
    }

    public var role: CoachRole {
        get { CoachRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }
}

public enum CoachRole: String, Codable, Sendable {
    case user
    case assistant
}
