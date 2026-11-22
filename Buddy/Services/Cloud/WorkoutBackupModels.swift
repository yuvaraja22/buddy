import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Portable Cloud & Local JSON Backup Schema

public struct BuddyProfileBackup: Codable, Equatable, Sendable {
    public var displayName: String
    public var weeklyGoal: Int
    public var preferredUnit: WeightUnit

    public init(
        displayName: String = "",
        weeklyGoal: Int = 4,
        preferredUnit: WeightUnit = .kg
    ) {
        self.displayName = displayName
        self.weeklyGoal = min(7, max(1, weeklyGoal))
        self.preferredUnit = preferredUnit
    }
}

public struct LoggedSetBackup: Codable, Equatable, Sendable {
    public var id: UUID
    public var setNumber: Int
    public var reps: Int?
    public var weightKg: Double?
    public var durationSeconds: Int?
    public var tag: SetTag
    public var notes: String
    public var rawTranscript: String
    public var loggedAt: Date

    public init(
        id: UUID,
        setNumber: Int,
        reps: Int?,
        weightKg: Double?,
        durationSeconds: Int?,
        tag: SetTag,
        notes: String,
        rawTranscript: String,
        loggedAt: Date
    ) {
        self.id = id
        self.setNumber = setNumber
        self.reps = reps
        self.weightKg = weightKg
        self.durationSeconds = durationSeconds
        self.tag = tag
        self.notes = notes
        self.rawTranscript = rawTranscript
        self.loggedAt = loggedAt
    }
}

public struct ExerciseEntryBackup: Codable, Equatable, Sendable {
    public var id: UUID
    public var exerciseName: String
    public var canonicalName: String
    public var muscleGroup: MuscleGroup
    public var orderIndex: Int
    public var createdAt: Date
    public var sets: [LoggedSetBackup]

    public init(
        id: UUID,
        exerciseName: String,
        canonicalName: String,
        muscleGroup: MuscleGroup,
        orderIndex: Int,
        createdAt: Date,
        sets: [LoggedSetBackup]
    ) {
        self.id = id
        self.exerciseName = exerciseName
        self.canonicalName = canonicalName
        self.muscleGroup = muscleGroup
        self.orderIndex = orderIndex
        self.createdAt = createdAt
        self.sets = sets
    }
}

public struct WorkoutSessionBackup: Codable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String
    public var notes: String
    public var isActive: Bool
    public var isManualCheckIn: Bool
    public var entries: [ExerciseEntryBackup]

    public init(
        id: UUID,
        startedAt: Date,
        endedAt: Date?,
        title: String,
        notes: String,
        isActive: Bool,
        isManualCheckIn: Bool,
        entries: [ExerciseEntryBackup]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.notes = notes
        self.isActive = isActive
        self.isManualCheckIn = isManualCheckIn
        self.entries = entries
    }

    public var totalSetCount: Int {
        entries.reduce(0) { $0 + $1.sets.count }
    }

    public var latestMutationDate: Date {
        let latestSet = entries.flatMap(\.sets).map(\.loggedAt).max()
        let latestEntry = entries.map(\.createdAt).max()
        return [startedAt, endedAt, latestEntry, latestSet].compactMap { $0 }.max() ?? startedAt
    }
}

public struct BuddyCloudBackup: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var updatedAt: Date
    public var profile: BuddyProfileBackup
    public var sessions: [WorkoutSessionBackup]
    public var deletedSessionIDs: [UUID]

    public init(
        schemaVersion: Int = BuddyCloudBackup.currentSchemaVersion,
        updatedAt: Date = Date(),
        profile: BuddyProfileBackup = BuddyProfileBackup(),
        sessions: [WorkoutSessionBackup] = [],
        deletedSessionIDs: [UUID] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.profile = profile
        self.sessions = sessions
        self.deletedSessionIDs = deletedSessionIDs
    }

    public func encodedJSONData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> BuddyCloudBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BuddyCloudBackup.self, from: data)
    }
}

public struct CloudMergeReport: Equatable, Sendable {
    public let importedSessions: Int
    public let updatedSessions: Int
    public let deletedSessions: Int
    public let restoredProfile: Bool
    public let needsPushToCloud: Bool

    public init(
        importedSessions: Int = 0,
        updatedSessions: Int = 0,
        deletedSessions: Int = 0,
        restoredProfile: Bool = false,
        needsPushToCloud: Bool = false
    ) {
        self.importedSessions = importedSessions
        self.updatedSessions = updatedSessions
        self.deletedSessions = deletedSessions
        self.restoredProfile = restoredProfile
        self.needsPushToCloud = needsPushToCloud
    }
}

// MARK: - SwiftUI FileDocument Wrapper for Manual JSON Export

public struct BuddyBackupDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }

    public var jsonData: Data

    public init(backup: BuddyCloudBackup) {
        self.jsonData = (try? backup.encodedJSONData(prettyPrinted: true)) ?? Data("{}".utf8)
    }

    public init(configuration: ReadConfiguration) throws {
        self.jsonData = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: jsonData)
    }
}
