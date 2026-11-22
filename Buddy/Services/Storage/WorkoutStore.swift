import Foundation
import Observation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(ActivityKit)
import ActivityKit
#endif

@Observable
@MainActor
public final class WorkoutStore {
    private static let preferredUnitDefaultsKey = "buddy.preferredUnit"

    @ObservationIgnored
    private let modelContext: ModelContext
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let enableSystemSync: Bool
    @ObservationIgnored
    private var liveActivitySyncTask: Task<Void, Never>?

    private var undoStack: [UndoAction] = []

    public var sessions: [WorkoutSession] = []
    public var activeSession: WorkoutSession?
    public var latestBanner: WorkoutMutationBanner?
    public var recentlyEndedSession: WorkoutSession?

    public var preferredUnit: WeightUnit {
        didSet {
            if oldValue != preferredUnit {
                defaults.set(
                    preferredUnit.rawValue,
                    forKey: Self.preferredUnitDefaultsKey
                )
                syncWidgetsAndLiveActivity()
            }
        }
    }

    public init(
        modelContext: ModelContext,
        defaults: UserDefaults = AppGroupResolver.sharedDefaults,
        enableSystemSync: Bool = true
    ) {
        self.modelContext = modelContext
        self.defaults = defaults
        self.enableSystemSync = enableSystemSync
        if let savedRaw = defaults.string(forKey: Self.preferredUnitDefaultsKey),
           let savedUnit = WeightUnit(rawValue: savedRaw) {
            self.preferredUnit = savedUnit
        } else {
            self.preferredUnit = .kg
        }
        reload()
        syncWidgetsAndLiveActivity()
    }

    // MARK: - Persistence & Reload

    public func reload() {
        let descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let fetched = (try? modelContext.fetch(descriptor)) ?? []

        // Enforce at most one active session (newest by startedAt wins).
        let activeMatches = fetched.filter(\.isActive)
        if activeMatches.count > 1 {
            for duplicate in activeMatches.dropFirst() {
                duplicate.isActive = false
                if duplicate.endedAt == nil {
                    duplicate.endedAt = Date()
                }
            }
            saveContext()
        }

        sessions = fetched
        activeSession = activeMatches.first
    }

    // MARK: - Session Lifecycle

    public func startNewSession(title: String = "Workout") -> WorkoutSession {
        createActiveSession(title: title, sync: true)
    }

    @discardableResult
    public func endActiveSession() -> WorkoutSession? {
        guard let session = activeSession else { return nil }
        session.isActive = false
        session.endedAt = Date()
        activeSession = nil
        recentlyEndedSession = session
        undoStack.removeAll()
        latestBanner = nil

        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
        return session
    }

    // MARK: - Voice / AI Command Execution

    @discardableResult
    public func apply(_ intent: WorkoutCommandIntent) -> WorkoutMutationBanner? {
        switch intent.action {
        case .unknown:
            return nil

        case .endSession:
            guard let ended = endActiveSession() else { return nil }
            let detail = "\(ended.totalSets) \(ended.totalSets == 1 ? "set" : "sets") · \(preferredUnit.formatVolume(kg: ended.totalVolumeKg))"
            return WorkoutMutationBanner(
                title: "Workout Finished",
                detail: detail,
                rawTranscript: intent.rawTranscript,
                parserSource: intent.parserSource,
                editableSetID: nil,
                editableEntryID: nil,
                canUndo: false
            )

        case .logSets:
            return applyLogSets(intent)

        case .updateLastSet:
            return applyUpdateLastSet(intent)

        case .deleteLastSet:
            return applyDeleteLastSet(intent)

        case .deleteLastExercise:
            return applyDeleteLastExercise(intent)
        }
    }

    public func undoLastMutation() {
        guard let action = undoStack.popLast() else {
            latestBanner = nil
            return
        }

        switch action {
        case let .loggedSets(sessionID, createdSession, createdEntryIDs, createdSetIDs):
            let setIDSet = Set(createdSetIDs)
            var affectedEntryIDs = Set<UUID>()

            if let session = findSession(id: sessionID) {
                for entry in session.entries {
                    let matchingSets = entry.sets.filter { setIDSet.contains($0.id) }
                    if !matchingSets.isEmpty {
                        affectedEntryIDs.insert(entry.id)
                        for set in matchingSets {
                            entry.sets.removeAll(where: { $0.id == set.id })
                            set.entry = nil
                            modelContext.delete(set)
                        }
                    }
                }

                for entryID in createdEntryIDs {
                    if let entry = session.entries.first(where: { $0.id == entryID }),
                       entry.sets.isEmpty {
                        session.entries.removeAll(where: { $0.id == entry.id })
                        entry.session = nil
                        modelContext.delete(entry)
                        affectedEntryIDs.remove(entryID)
                    }
                }

                for entryID in affectedEntryIDs {
                    if let entry = session.entries.first(where: { $0.id == entryID }) {
                        renumberSets(in: entry)
                    }
                }

                if createdSession && session.entries.isEmpty {
                    if activeSession?.id == session.id {
                        activeSession = nil
                    }
                    modelContext.delete(session)
                }
            }

        case let .updatedSet(setID, previous):
            if let set = findSet(id: setID) {
                set.reps = previous.reps
                set.weightKg = previous.weightKg
                set.durationSeconds = previous.durationSeconds
                set.tag = previous.tag
                set.notes = previous.notes
                set.rawTranscript = previous.rawTranscript
                set.loggedAt = previous.loggedAt
            }

        case let .deletedSet(sessionID, entrySnapshot, entryWasDeleted, deletedSet):
            guard let session = findSession(id: sessionID) else { break }
            let targetEntry: ExerciseEntry
            if entryWasDeleted {
                let recreated = ExerciseEntry(
                    id: entrySnapshot.id,
                    exerciseName: entrySnapshot.exerciseName,
                    canonicalName: entrySnapshot.canonicalName,
                    muscleGroup: entrySnapshot.muscleGroup,
                    orderIndex: entrySnapshot.orderIndex,
                    createdAt: entrySnapshot.createdAt,
                    session: nil
                )
                modelContext.insert(recreated)
                recreated.session = session
                if !session.entries.contains(where: { $0.id == recreated.id }) {
                    session.entries.append(recreated)
                }
                targetEntry = recreated
            } else if let existing = session.entries.first(where: { $0.id == entrySnapshot.id }) {
                targetEntry = existing
            } else {
                break
            }

            let restoredSet = LoggedSet(
                id: deletedSet.id,
                setNumber: deletedSet.setNumber,
                reps: deletedSet.reps,
                weightKg: deletedSet.weightKg,
                durationSeconds: deletedSet.durationSeconds,
                tag: deletedSet.tag,
                notes: deletedSet.notes,
                rawTranscript: deletedSet.rawTranscript,
                loggedAt: deletedSet.loggedAt,
                entry: nil
            )
            modelContext.insert(restoredSet)
            restoredSet.entry = targetEntry
            if !targetEntry.sets.contains(where: { $0.id == restoredSet.id }) {
                targetEntry.sets.append(restoredSet)
            }
            renumberSets(in: targetEntry)

        case let .deletedExercise(sessionID, entrySnapshot):
            guard let session = findSession(id: sessionID) else { break }
            let restoredEntry = ExerciseEntry(
                id: entrySnapshot.id,
                exerciseName: entrySnapshot.exerciseName,
                canonicalName: entrySnapshot.canonicalName,
                muscleGroup: entrySnapshot.muscleGroup,
                orderIndex: entrySnapshot.orderIndex,
                createdAt: entrySnapshot.createdAt,
                session: nil
            )
            modelContext.insert(restoredEntry)
            restoredEntry.session = session
            if !session.entries.contains(where: { $0.id == restoredEntry.id }) {
                session.entries.append(restoredEntry)
            }

            for setSnap in entrySnapshot.sets {
                let restoredSet = LoggedSet(
                    id: setSnap.id,
                    setNumber: setSnap.setNumber,
                    reps: setSnap.reps,
                    weightKg: setSnap.weightKg,
                    durationSeconds: setSnap.durationSeconds,
                    tag: setSnap.tag,
                    notes: setSnap.notes,
                    rawTranscript: setSnap.rawTranscript,
                    loggedAt: setSnap.loggedAt,
                    entry: nil
                )
                modelContext.insert(restoredSet)
                restoredSet.entry = restoredEntry
                if !restoredEntry.sets.contains(where: { $0.id == restoredSet.id }) {
                    restoredEntry.sets.append(restoredSet)
                }
            }
            renumberSets(in: restoredEntry)
        }

        latestBanner = nil
        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
    }

    public func dismissBanner() {
        latestBanner = nil
    }

    // MARK: - Manual CRUD

    @discardableResult
    public func addSet(
        to entry: ExerciseEntry,
        reps: Int? = nil,
        weightKg: Double? = nil,
        durationSeconds: Int? = nil,
        tag: SetTag = .normal,
        notes: String = ""
    ) -> LoggedSet {
        let nextNumber = entry.sets.count + 1
        let loggedAt = monotonicTimestamp(in: entry.session, fallbackEntry: entry)
        let newSet = LoggedSet(
            setNumber: nextNumber,
            reps: reps,
            weightKg: weightKg,
            durationSeconds: durationSeconds,
            tag: tag,
            notes: notes,
            rawTranscript: "",
            loggedAt: loggedAt,
            entry: nil
        )
        modelContext.insert(newSet)
        newSet.entry = entry
        if !entry.sets.contains(where: { $0.id == newSet.id }) {
            entry.sets.append(newSet)
        }

        if entry.session?.id == activeSession?.id {
            undoStack.removeAll()
        }
        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
        return newSet
    }

    public func addManualExercise(
        name: String,
        sets: Int,
        reps: Int?,
        weightKg: Double?,
        durationSeconds: Int?,
        tag: SetTag = .normal
    ) {
        let session = activeSession ?? createActiveSession(title: "Workout", sync: false)
        let resolved = ExerciseCatalog.resolve(name)
        let baseTime = monotonicTimestamp(in: session)
        let entry: ExerciseEntry

        if let existing = session.entries.first(where: {
            $0.canonicalName.caseInsensitiveCompare(resolved.canonicalName) == .orderedSame
        }) {
            entry = existing
        } else {
            let nextOrder = (session.entries.map(\.orderIndex).max() ?? -1) + 1
            let created = ExerciseEntry(
                exerciseName: resolved.displayName,
                canonicalName: resolved.canonicalName,
                muscleGroup: resolved.muscleGroup,
                orderIndex: nextOrder,
                createdAt: baseTime,
                session: nil
            )
            modelContext.insert(created)
            created.session = session
            if !session.entries.contains(where: { $0.id == created.id }) {
                session.entries.append(created)
            }
            entry = created
        }

        let count = max(1, sets)
        let existingCount = entry.sets.count
        for offset in 0..<count {
            let newSet = LoggedSet(
                setNumber: existingCount + offset + 1,
                reps: reps,
                weightKg: weightKg,
                durationSeconds: durationSeconds,
                tag: tag,
                notes: "",
                rawTranscript: "",
                loggedAt: baseTime.addingTimeInterval(Double(offset) * 0.001),
                entry: nil
            )
            modelContext.insert(newSet)
            newSet.entry = entry
            if !entry.sets.contains(where: { $0.id == newSet.id }) {
                entry.sets.append(newSet)
            }
        }

        undoStack.removeAll()
        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
    }

    public func updateSet(
        _ set: LoggedSet,
        reps: Int?,
        weightKg: Double?,
        durationSeconds: Int?,
        tag: SetTag,
        notes: String
    ) {
        set.reps = reps
        set.weightKg = weightKg
        set.durationSeconds = durationSeconds
        set.tag = tag
        set.notes = notes

        if set.entry?.session?.id == activeSession?.id {
            undoStack.removeAll()
        }
        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
    }

    public func deleteSet(_ set: LoggedSet) {
        let affectsActive = set.entry?.session?.id == activeSession?.id
        if let entry = set.entry {
            entry.sets.removeAll(where: { $0.id == set.id })
            set.entry = nil
            modelContext.delete(set)

            if entry.sets.isEmpty {
                if let session = entry.session {
                    session.entries.removeAll(where: { $0.id == entry.id })
                    entry.session = nil
                }
                modelContext.delete(entry)
            } else {
                renumberSets(in: entry)
            }
        } else {
            modelContext.delete(set)
        }

        if affectsActive {
            undoStack.removeAll()
        }
        if latestBanner?.editableSetID == set.id {
            latestBanner = nil
        }

        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
    }

    public func deleteEntry(_ entry: ExerciseEntry) {
        let affectsActive = entry.session?.id == activeSession?.id
        if let session = entry.session {
            session.entries.removeAll(where: { $0.id == entry.id })
            entry.session = nil
        }
        modelContext.delete(entry)

        if affectsActive {
            undoStack.removeAll()
        }
        if latestBanner?.editableEntryID == entry.id {
            latestBanner = nil
        }

        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
    }

    public func deleteSession(_ session: WorkoutSession) {
        let wasActive = activeSession?.id == session.id
        if recentlyEndedSession?.id == session.id {
            recentlyEndedSession = nil
        }
        if wasActive {
            activeSession = nil
            undoStack.removeAll()
            latestBanner = nil
        }

        modelContext.delete(session)
        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
    }

    // MARK: - Queries & Prompt Context

    public func findSet(id: UUID) -> LoggedSet? {
        if let active = activeSession {
            for entry in active.entries {
                if let found = entry.sets.first(where: { $0.id == id }) {
                    return found
                }
            }
        }
        for session in sessions {
            for entry in session.entries {
                if let found = entry.sets.first(where: { $0.id == id }) {
                    return found
                }
            }
        }
        return nil
    }

    public func promptContext() -> ActiveSessionPromptContext {
        guard let session = activeSession else {
            return ActiveSessionPromptContext(
                preferredUnit: preferredUnit,
                lastExerciseName: nil,
                recentExercisesInSession: [],
                isSessionActive: false
            )
        }
        let recentNames = session.sortedEntries.map(\.exerciseName)
        let lastExercise = mostRecentSet(in: session)?.entry.exerciseName ?? session.sortedEntries.last?.exerciseName
        return ActiveSessionPromptContext(
            preferredUnit: preferredUnit,
            lastExerciseName: lastExercise,
            recentExercisesInSession: recentNames,
            isSessionActive: true
        )
    }

    // MARK: - WidgetKit & ActivityKit Sync

    public func syncWidgetsAndLiveActivity() {
        guard enableSystemSync else { return }

        let snapshot = StatsCalculator.buildWidgetSnapshot(
            sessions: sessions,
            preferredUnit: preferredUnit
        )
        WidgetSnapshot.save(snapshot)

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif

        #if canImport(ActivityKit)
        syncLiveActivity()
        #endif
    }

    // MARK: - Private Command Handlers

    private func applyLogSets(_ intent: WorkoutCommandIntent) -> WorkoutMutationBanner? {
        guard !intent.items.isEmpty else { return nil }

        let createdSession = activeSession == nil
        let session = activeSession ?? createActiveSession(title: "Workout", sync: false)

        var createdEntryIDs: [UUID] = []
        var createdSetIDs: [UUID] = []
        var lastEntry: ExerciseEntry?
        var lastSet: LoggedSet?

        let baseTime = monotonicTimestamp(in: session)
        var sequenceOffset = 0

        for item in intent.items {
            let resolved = ExerciseCatalog.resolve(item.exerciseName)
            let entry: ExerciseEntry

            if let existing = session.entries.first(where: {
                $0.canonicalName.caseInsensitiveCompare(resolved.canonicalName) == .orderedSame
            }) {
                entry = existing
            } else {
                let nextOrder = (session.entries.map(\.orderIndex).max() ?? -1) + 1
                let newEntry = ExerciseEntry(
                    exerciseName: resolved.displayName,
                    canonicalName: resolved.canonicalName,
                    muscleGroup: resolved.muscleGroup,
                    orderIndex: nextOrder,
                    createdAt: baseTime.addingTimeInterval(Double(sequenceOffset) * 0.001),
                    session: nil
                )
                modelContext.insert(newEntry)
                newEntry.session = session
                if !session.entries.contains(where: { $0.id == newEntry.id }) {
                    session.entries.append(newEntry)
                }
                createdEntryIDs.append(newEntry.id)
                entry = newEntry
            }

            let weightKg = item.resolvedWeightKg(defaultUnit: preferredUnit)
            let existingCount = entry.sets.count
            let count = max(1, item.setCount)

            for offset in 0..<count {
                let set = LoggedSet(
                    setNumber: existingCount + offset + 1,
                    reps: item.reps,
                    weightKg: weightKg,
                    durationSeconds: item.durationSeconds,
                    tag: item.tag,
                    notes: item.note,
                    rawTranscript: intent.rawTranscript,
                    loggedAt: baseTime.addingTimeInterval(Double(sequenceOffset) * 0.001),
                    entry: nil
                )
                sequenceOffset += 1
                modelContext.insert(set)
                set.entry = entry
                if !entry.sets.contains(where: { $0.id == set.id }) {
                    entry.sets.append(set)
                }
                createdSetIDs.append(set.id)
                lastSet = set
            }

            lastEntry = entry
        }

        undoStack.append(
            .loggedSets(
                sessionID: session.id,
                createdSession: createdSession,
                createdEntryIDs: createdEntryIDs,
                createdSetIDs: createdSetIDs
            )
        )

        let title: String
        if intent.items.count == 1, let entry = lastEntry {
            title = "Logged \(entry.exerciseName)"
        } else {
            title = "Logged \(intent.items.count) Exercises"
        }

        let detail: String
        if !intent.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail = intent.summary
        } else if let entry = lastEntry {
            detail = entry.compactSummary(unit: preferredUnit)
        } else {
            detail = "\(createdSetIDs.count) sets added"
        }

        let banner = WorkoutMutationBanner(
            title: title,
            detail: detail,
            rawTranscript: intent.rawTranscript,
            parserSource: intent.parserSource,
            editableSetID: lastSet?.id,
            editableEntryID: lastEntry?.id,
            canUndo: true
        )
        latestBanner = banner

        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
        return banner
    }

    private func applyUpdateLastSet(_ intent: WorkoutCommandIntent) -> WorkoutMutationBanner? {
        guard let session = activeSession,
              let target = mostRecentSet(in: session),
              let item = intent.items.first else {
            return nil
        }

        let set = target.set
        let entry = target.entry
        let previous = snapshot(of: set)
        var didMutate = false

        if let reps = item.reps, set.reps != reps {
            set.reps = reps
            didMutate = true
        }
        if let weightKg = item.resolvedWeightKg(defaultUnit: preferredUnit) {
            let changed = set.weightKg.map { abs($0 - weightKg) > 0.0001 } ?? true
            if changed {
                set.weightKg = weightKg
                didMutate = true
            }
        }
        if let duration = item.durationSeconds, set.durationSeconds != duration {
            set.durationSeconds = duration
            didMutate = true
        }
        if item.hasExplicitTag, set.tag != item.tag {
            set.tag = item.tag
            didMutate = true
        }
        let cleanedNote = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedNote.isEmpty, set.notes != cleanedNote {
            set.notes = cleanedNote
            didMutate = true
        }

        guard didMutate else {
            return nil
        }

        undoStack.append(.updatedSet(setID: set.id, previous: previous))

        let banner = WorkoutMutationBanner(
            title: "Updated \(entry.exerciseName)",
            detail: "Set \(set.setNumber) · \(set.formattedDetail(unit: preferredUnit))",
            rawTranscript: intent.rawTranscript,
            parserSource: intent.parserSource,
            editableSetID: set.id,
            editableEntryID: entry.id,
            canUndo: true
        )
        latestBanner = banner

        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
        return banner
    }

    private func applyDeleteLastSet(_ intent: WorkoutCommandIntent) -> WorkoutMutationBanner? {
        guard let session = activeSession,
              let target = mostRecentSet(in: session) else {
            return nil
        }

        let entry = target.entry
        let set = target.set
        let entrySnap = snapshot(of: entry)
        let setSnap = snapshot(of: set)

        entry.sets.removeAll(where: { $0.id == set.id })
        set.entry = nil
        modelContext.delete(set)

        let entryWasDeleted: Bool
        if entry.sets.isEmpty {
            session.entries.removeAll(where: { $0.id == entry.id })
            entry.session = nil
            modelContext.delete(entry)
            entryWasDeleted = true
        } else {
            renumberSets(in: entry)
            entryWasDeleted = false
        }

        undoStack.append(
            .deletedSet(
                sessionID: session.id,
                entrySnapshot: entrySnap,
                entryWasDeleted: entryWasDeleted,
                deletedSet: setSnap
            )
        )

        let banner = WorkoutMutationBanner(
            title: "Deleted Last Set",
            detail: "\(entrySnap.exerciseName) · Set \(setSnap.setNumber)",
            rawTranscript: intent.rawTranscript,
            parserSource: intent.parserSource,
            editableSetID: nil,
            editableEntryID: entryWasDeleted ? nil : entry.id,
            canUndo: true
        )
        latestBanner = banner

        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
        return banner
    }

    private func applyDeleteLastExercise(_ intent: WorkoutCommandIntent) -> WorkoutMutationBanner? {
        guard let session = activeSession,
              let lastEntry = mostRecentEntry(in: session) else {
            return nil
        }

        let entrySnap = snapshot(of: lastEntry)
        session.entries.removeAll(where: { $0.id == lastEntry.id })
        lastEntry.session = nil
        modelContext.delete(lastEntry)

        undoStack.append(
            .deletedExercise(
                sessionID: session.id,
                entrySnapshot: entrySnap
            )
        )

        let setCount = entrySnap.sets.count
        let banner = WorkoutMutationBanner(
            title: "Deleted \(entrySnap.exerciseName)",
            detail: "\(setCount) \(setCount == 1 ? "set" : "sets") removed",
            rawTranscript: intent.rawTranscript,
            parserSource: intent.parserSource,
            editableSetID: nil,
            editableEntryID: nil,
            canUndo: true
        )
        latestBanner = banner

        saveContext()
        reload()
        syncWidgetsAndLiveActivity()
        return banner
    }

    // MARK: - Internal Helpers

    private func createActiveSession(title: String, sync: Bool) -> WorkoutSession {
        if let existing = activeSession {
            existing.isActive = false
            existing.endedAt = Date()
        }

        let session = WorkoutSession(
            startedAt: Date(),
            title: title,
            isActive: true
        )
        modelContext.insert(session)
        activeSession = session
        recentlyEndedSession = nil
        undoStack.removeAll()
        latestBanner = nil

        saveContext()
        reload()
        if sync {
            syncWidgetsAndLiveActivity()
        }
        return session
    }

    private func saveContext() {
        try? modelContext.save()
    }

    private func findSession(id: UUID) -> WorkoutSession? {
        if activeSession?.id == id {
            return activeSession
        }
        return sessions.first(where: { $0.id == id })
    }

    private func monotonicTimestamp(
        in session: WorkoutSession?,
        fallbackEntry: ExerciseEntry? = nil,
        now: Date = Date()
    ) -> Date {
        var latestExisting: Date?
        if let session {
            for entry in session.entries {
                latestExisting = latestExisting.map { max($0, entry.createdAt) } ?? entry.createdAt
                for set in entry.sets {
                    latestExisting = latestExisting.map { max($0, set.loggedAt) } ?? set.loggedAt
                }
            }
        } else if let fallbackEntry {
            latestExisting = fallbackEntry.sets.map(\.loggedAt).max() ?? fallbackEntry.createdAt
        }

        if let latestExisting, now <= latestExisting {
            return latestExisting.addingTimeInterval(0.001)
        }
        return now
    }

    private func mostRecentSet(in session: WorkoutSession) -> (entry: ExerciseEntry, set: LoggedSet)? {
        var best: (entry: ExerciseEntry, set: LoggedSet)?
        for entry in session.entries {
            for set in entry.sets {
                guard let currentBest = best else {
                    best = (entry, set)
                    continue
                }
                if set.loggedAt > currentBest.set.loggedAt {
                    best = (entry, set)
                } else if set.loggedAt == currentBest.set.loggedAt {
                    if entry.orderIndex > currentBest.entry.orderIndex ||
                        (entry.orderIndex == currentBest.entry.orderIndex && set.setNumber > currentBest.set.setNumber) {
                        best = (entry, set)
                    }
                }
            }
        }
        return best
    }

    private func mostRecentEntry(in session: WorkoutSession) -> ExerciseEntry? {
        if let recent = mostRecentSet(in: session) {
            return recent.entry
        }
        return session.sortedEntries.last
    }

    private func renumberSets(in entry: ExerciseEntry) {
        let ordered = entry.sortedSets
        for (index, set) in ordered.enumerated() {
            set.setNumber = index + 1
        }
    }

    private func snapshot(of set: LoggedSet) -> SetSnapshot {
        SetSnapshot(
            id: set.id,
            setNumber: set.setNumber,
            reps: set.reps,
            weightKg: set.weightKg,
            durationSeconds: set.durationSeconds,
            tag: set.tag,
            notes: set.notes,
            rawTranscript: set.rawTranscript,
            loggedAt: set.loggedAt
        )
    }

    private func snapshot(of entry: ExerciseEntry) -> EntrySnapshot {
        EntrySnapshot(
            id: entry.id,
            exerciseName: entry.exerciseName,
            canonicalName: entry.canonicalName,
            muscleGroup: entry.muscleGroup,
            orderIndex: entry.orderIndex,
            createdAt: entry.createdAt,
            sets: entry.sortedSets.map { snapshot(of: $0) }
        )
    }

    // MARK: - Undo Snapshot Models

    private struct SetSnapshot {
        let id: UUID
        let setNumber: Int
        let reps: Int?
        let weightKg: Double?
        let durationSeconds: Int?
        let tag: SetTag
        let notes: String
        let rawTranscript: String
        let loggedAt: Date
    }

    private struct EntrySnapshot {
        let id: UUID
        let exerciseName: String
        let canonicalName: String
        let muscleGroup: MuscleGroup
        let orderIndex: Int
        let createdAt: Date
        let sets: [SetSnapshot]
    }

    private enum UndoAction {
        case loggedSets(
            sessionID: UUID,
            createdSession: Bool,
            createdEntryIDs: [UUID],
            createdSetIDs: [UUID]
        )
        case updatedSet(
            setID: UUID,
            previous: SetSnapshot
        )
        case deletedSet(
            sessionID: UUID,
            entrySnapshot: EntrySnapshot,
            entryWasDeleted: Bool,
            deletedSet: SetSnapshot
        )
        case deletedExercise(
            sessionID: UUID,
            entrySnapshot: EntrySnapshot
        )
    }
}

#if canImport(ActivityKit)
extension WorkoutStore {
    private func syncLiveActivity() {
        guard let session = activeSession else {
            endAllLiveActivities()
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let recent = mostRecentSet(in: session)
        let lastExerciseName = recent?.entry.exerciseName
            ?? session.sortedEntries.last?.exerciseName
            ?? "Ready to log"
        let lastSetDetail = recent?.set.formattedDetail(unit: preferredUnit)
            ?? "Tap mic to log a set"

        let state = WorkoutLiveActivityAttributes.ContentState(
            sessionTitle: session.derivedTitle,
            totalSets: session.totalSets,
            totalReps: session.totalReps,
            totalVolumeKg: session.totalVolumeKg,
            exerciseCount: session.exerciseCount,
            lastExerciseName: lastExerciseName,
            lastSetDetail: lastSetDetail,
            preferredUnit: preferredUnit
        )
        let content = ActivityContent(state: state, staleDate: nil)
        let sessionID = session.id.uuidString
        let startedAt = session.startedAt

        let previousTask = liveActivitySyncTask
        liveActivitySyncTask = Task {
            await previousTask?.value

            let allActivities = Activity<WorkoutLiveActivityAttributes>.activities
            for stale in allActivities where stale.attributes.sessionID != sessionID {
                let finalContent = ActivityContent(state: stale.content.state, staleDate: nil)
                await stale.end(finalContent, dismissalPolicy: .immediate)
            }

            if let existing = Activity<WorkoutLiveActivityAttributes>.activities.first(where: {
                $0.attributes.sessionID == sessionID
            }) {
                await existing.update(content)
            } else {
                let attributes = WorkoutLiveActivityAttributes(
                    sessionID: sessionID,
                    sessionStartedAt: startedAt
                )
                _ = try? Activity<WorkoutLiveActivityAttributes>.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            }
        }
    }

    private func endAllLiveActivities() {
        let previousTask = liveActivitySyncTask
        liveActivitySyncTask = Task {
            await previousTask?.value
            let activities = Activity<WorkoutLiveActivityAttributes>.activities
            for activity in activities {
                let finalContent = ActivityContent(state: activity.content.state, staleDate: nil)
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
        }
    }
}
#endif

