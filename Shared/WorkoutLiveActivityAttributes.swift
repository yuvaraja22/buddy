import Foundation
#if canImport(ActivityKit)
import ActivityKit

public struct WorkoutLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var sessionTitle: String
        public var totalSets: Int
        public var totalReps: Int
        public var totalVolumeKg: Double
        public var exerciseCount: Int
        public var lastExerciseName: String
        public var lastSetDetail: String
        public var preferredUnit: WeightUnit

        public init(
            sessionTitle: String,
            totalSets: Int,
            totalReps: Int,
            totalVolumeKg: Double,
            exerciseCount: Int,
            lastExerciseName: String,
            lastSetDetail: String,
            preferredUnit: WeightUnit = .kg
        ) {
            self.sessionTitle = sessionTitle
            self.totalSets = totalSets
            self.totalReps = totalReps
            self.totalVolumeKg = totalVolumeKg
            self.exerciseCount = exerciseCount
            self.lastExerciseName = lastExerciseName
            self.lastSetDetail = lastSetDetail
            self.preferredUnit = preferredUnit
        }
    }

    public var sessionID: String
    public var sessionStartedAt: Date

    public init(sessionID: String, sessionStartedAt: Date) {
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
    }
}
#endif
