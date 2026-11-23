import SwiftUI

public enum WorkoutSplitFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case upper = "Upper"
    case lower = "Lower"
    case other = "Full / Other"

    public var id: String { rawValue }

    /// Classifies a workout session into exactly one split bucket based on its muscle-group
    /// composition (or title when empty):
    /// - Upper-only (even with accessory core/cardio like a finisher plank) -> `.upper`
    /// - Lower-only (even with accessory core/cardio) -> `.lower`
    /// - Combined Upper + Lower (true Full Body) or Core/Cardio/Other-only -> `.other`
    public static func classify(muscleGroups: [MuscleGroup], title: String) -> WorkoutSplitFilter {
        let upperGroups: Set<MuscleGroup> = [.chest, .back, .shoulders, .biceps, .triceps]
        let lowerGroups: Set<MuscleGroup> = [.quads, .hamstrings, .glutes, .calves]

        let hasUpper = muscleGroups.contains { upperGroups.contains($0) }
        let hasLower = muscleGroups.contains { lowerGroups.contains($0) }

        if hasUpper && !hasLower {
            return .upper
        }
        if hasLower && !hasUpper {
            return .lower
        }
        if hasUpper && hasLower {
            return .other
        }

        if muscleGroups.isEmpty {
            let lowerTitle = title.lowercased()
            let titleUpper = lowerTitle.contains("push") || lowerTitle.contains("pull") || lowerTitle.contains("upper")
            let titleLower = lowerTitle.contains("leg") || lowerTitle.contains("lower")
            if titleUpper && !titleLower { return .upper }
            if titleLower && !titleUpper { return .lower }
        }

        return .other
    }
}

struct WorkoutHomeView: View {
    let store: WorkoutStore
    let pipeline: VoicePipelineCoordinator
    let modelManager: ModelManager
    let appleSpeechService: AppleSpeechService
    let llmService: LocalLLMService
    let cloudSync: FirebaseSyncService
    var isTabActive: Bool = true
    var dockClearance: CGFloat = 78
    var dismissSheetsToken: Int = 0
    var onStartFullSessionRecap: () -> Void = {}

    @State private var showSettings: Bool = false
    @State private var showManualAdd: Bool = false
    @State private var editingSet: LoggedSet?
    @State private var showEndSessionDialog: Bool = false
    @State private var quickCommandText: String = ""
    @State private var selectedRecentFilter: WorkoutSplitFilter = .all
    @FocusState private var isCommandBarFocused: Bool

    private let examplePhrases: [(chip: String, command: String)] = [
        ("Bench 60 kg 3×10", "Bench press 60 kg 3 sets 10 reps"),
        ("Full Push recap", "Bench press 60 kg 3 sets 10 reps, incline dumbbell press 20 kg 3 sets 12 reps, cable fly 15 kg 3 sets 15 reps"),
        ("Leg ext 3×15", "Leg extension 3 sets 15 reps"),
        ("Plank 60s", "Plank 60 seconds")
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 16) {
                        compactTopHeader
                        uberCommandBar

                        if let session = store.activeSession {
                            activeSessionContent(session)
                        } else {
                            idleHomeContent
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, max(BuddyTheme.floatingBarClearance, dockClearance + 24))
                }
                .scrollDismissesKeyboard(.interactively)
                .background(BuddyTheme.canvasBackground.ignoresSafeArea())

                if let banner = store.latestBanner {
                    autoSaveToast(banner)
                        .padding(.horizontal, 16)
                        .padding(.bottom, dockClearance + 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: banner.id) {
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            guard !Task.isCancelled else { return }
                            if store.latestBanner?.id == banner.id {
                                store.dismissBanner()
                            }
                        }
                }
            }
            .animation(.snappy(duration: 0.25), value: store.latestBanner?.id)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: dismissSheetsToken) { _, _ in
                showSettings = false
                showManualAdd = false
                editingSet = nil
                showEndSessionDialog = false
                store.recentlyEndedSession = nil
            }
            .confirmationDialog(
                (store.activeSession?.totalSets ?? 0) == 0 ? "Discard empty workout?" : "End current workout?",
                isPresented: $showEndSessionDialog,
                titleVisibility: .visible
            ) {
                if let active = store.activeSession, active.totalSets == 0 {
                    Button("Discard Empty Workout", role: .destructive) {
                        BuddyHaptics.lightImpact()
                        store.deleteSession(active)
                        WidgetRefreshHelper.sync(store: store)
                    }
                } else {
                    Button("End & Save Workout") {
                        BuddyHaptics.success()
                        _ = store.endActiveSession()
                        WidgetRefreshHelper.sync(store: store)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if (store.activeSession?.totalSets ?? 0) == 0 {
                    Text("No sets were logged in this session. Discarding keeps your history clean.")
                } else {
                    Text("Your workout summary will be saved to Trends and synced with widgets.")
                }
            }
            .sheet(item: $editingSet) { set in
                SetEditorSheet(set: set, store: store)
                    .buddyAppearance()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(
                item: Binding(
                    get: { store.recentlyEndedSession },
                    set: { store.recentlyEndedSession = $0 }
                )
            ) { endedSession in
                SessionSummarySheet(
                    session: endedSession,
                    unit: store.preferredUnit,
                    onDismiss: {
                        store.recentlyEndedSession = nil
                    }
                )
                .buddyAppearance()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showManualAdd) {
                ManualAddExerciseSheet(store: store)
                    .buddyAppearance()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    store: store,
                    modelManager: modelManager,
                    appleSpeechService: appleSpeechService,
                    llmService: llmService,
                    cloudSync: cloudSync
                )
                .buddyAppearance()
            }
        }
    }

    // MARK: - Compact Uber-Style Top Header

    private var compactTopHeader: some View {
        let consistency = StatsCalculator.consistency(
            sessions: store.sessions,
            referenceDate: Date(),
            weeklyGoal: store.weeklyGoal
        )
        let firstName = store.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)

        return HStack(spacing: 10) {
            if let session = store.activeSession {
                HStack(spacing: 8) {
                    PulsingLiveDot(color: BuddyTheme.emeraldLive, size: 7)

                    Text("LIVE")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(BuddyTheme.emeraldLive)

                    if isTabActive {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = max(0, Int(context.date.timeIntervalSince(session.startedAt)))
                            Text(DurationFormatter.formatClock(seconds: elapsed))
                                .font(.system(size: 14, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                    } else {
                        Text(DurationFormatter.formatClock(seconds: session.durationSeconds))
                            .font(.system(size: 14, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Circle()
                        .fill(consistency.currentStreakDays > 0 ? BuddyTheme.emeraldLive : BuddyTheme.mutedText)
                        .frame(width: 7, height: 7)

                    Text(firstName ?? "Buddy")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(BuddyTheme.mutedText)

                    Text("\(consistency.currentStreakDays)d streak · \(consistency.workoutsThisWeek)/\(consistency.weeklyGoal) wk")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(BuddyTheme.mutedText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if store.activeSession != nil {
                Button {
                    BuddyHaptics.mediumImpact()
                    showEndSessionDialog = true
                } label: {
                    Text("End")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(BuddyTheme.inkInverse)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(BuddyTheme.inkPrimary)
                        )
                }
                .buttonStyle(.plain)
            }

            Button {
                BuddyHaptics.lightImpact()
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(BuddyTheme.cardSurface)
                    )
                    .overlay {
                        Circle()
                            .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 2)
    }

    // MARK: - Uber-Style "Where to?" Command Bar

    private var uberCommandBar: some View {
        let trimmed = quickCommandText.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 4)

            TextField("Log a set or exercise…", text: $quickCommandText)
                .font(.system(size: 15, weight: .medium))
                .focused($isCommandBarFocused)
                .submitLabel(.send)
                .onSubmit {
                    submitQuickCommand()
                }

            if !trimmed.isEmpty {
                Button {
                    submitQuickCommand()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                        Text("Log")
                            .font(.system(size: 12.5, weight: .bold))
                    }
                    .foregroundStyle(BuddyTheme.inkInverse)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(BuddyTheme.inkPrimary)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log typed workout command")
            } else {
                Button {
                    BuddyHaptics.lightImpact()
                    isCommandBarFocused = false
                    showManualAdd = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Manual")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add exercise manually")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Capsule(style: .continuous)
                .fill(BuddyTheme.cardSurface)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    isCommandBarFocused ? BuddyTheme.inkPrimary.opacity(0.45) : BuddyTheme.glassBorder,
                    lineWidth: 1.0
                )
        }
    }

    private func submitQuickCommand() {
        let trimmed = quickCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        BuddyHaptics.mediumImpact()
        quickCommandText = ""
        isCommandBarFocused = false
        pipeline.processTypedInput(trimmed, into: store)
    }

    // MARK: - Active Session Layout

    @ViewBuilder
    private func activeSessionContent(_ session: WorkoutSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.derivedTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text("\(session.totalSets) \(session.totalSets == 1 ? "set" : "sets")")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(BuddyTheme.mutedText)
            }

            flatSessionMetricStrip(session)

            let activeEntries = session.recentlyActiveEntries
            if activeEntries.isEmpty {
                emptyActiveSessionCard
            } else {
                let latestEntryID = activeEntries.first?.id
                LazyVStack(spacing: 12) {
                    ForEach(activeEntries, id: \.id) { entry in
                        ExerciseCardView(
                            entry: entry,
                            unit: store.preferredUnit,
                            isLatest: entry.id == latestEntryID,
                            onAddSet: {
                                addQuickSet(to: entry)
                            },
                            onSelectSet: { set in
                                BuddyHaptics.selection()
                                editingSet = set
                            },
                            onDeleteSet: { set in
                                BuddyHaptics.warning()
                                store.deleteSet(set)
                            },
                            onDeleteEntry: {
                                BuddyHaptics.warning()
                                store.deleteEntry(entry)
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                .animation(.snappy(duration: 0.28), value: activeEntries.map(\.id))
            }
        }
    }

    private func flatSessionMetricStrip(_ session: WorkoutSession) -> some View {
        HStack(spacing: 0) {
            stripMetricCell(title: "EXERCISES", value: "\(session.exerciseCount)")
            stripDivider
            stripMetricCell(title: "SETS", value: "\(session.totalSets)")
            stripDivider
            stripMetricCell(title: "REPS", value: "\(session.totalReps)")
            stripDivider
            if isTabActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(session.startedAt)))
                    stripMetricCell(title: "DURATION", value: DurationFormatter.formatCompact(seconds: elapsed))
                }
            } else {
                stripMetricCell(title: "DURATION", value: DurationFormatter.formatCompact(seconds: session.durationSeconds))
            }
        }
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
        }
    }

    private func stripMetricCell(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(BuddyTheme.mutedText)
        }
        .frame(maxWidth: .infinity)
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(BuddyTheme.hairlineBorder)
            .frame(width: 0.75, height: 26)
    }

    private var emptyActiveSessionCard: some View {
        NativeCard(padding: 16, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session active")
                        .font(.system(size: 16, weight: .bold))
                    Text("Tap or hold the mic button below and speak one set or your entire workout in one go.")
                        .font(.subheadline)
                        .foregroundStyle(BuddyTheme.mutedText)
                }

                quickTryChipStrip
            }
        }
    }

    // MARK: - Idle Home Layout (Uber Quick Tiles + YouTube Recent Feed)

    private var idleHomeContent: some View {
        let consistency = StatsCalculator.consistency(
            sessions: store.sessions,
            referenceDate: Date(),
            weeklyGoal: store.weeklyGoal
        )
        let completedSessions = store.sessions
            .filter { !$0.isActive && $0.countsAsWorkout }
            .sorted { $0.startedAt > $1.startedAt }

        let filteredRecent = completedSessions.filter { matchesRecentFilter($0) }

        return VStack(alignment: .leading, spacing: 20) {
            weeklyGoalBanner(consistency: consistency)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Quick start")
                        .font(BuddyTheme.sectionTitleFont)
                        .foregroundStyle(.primary)
                    Spacer()
                }

                HStack(spacing: 12) {
                    uberQuickTile(
                        title: "Push",
                        symbol: "figure.strengthtraining.traditional",
                        badge: nil
                    ) {
                        startSplitSession(title: "Push Day")
                    }

                    uberQuickTile(
                        title: "Pull",
                        symbol: "dumbbell.fill",
                        badge: nil
                    ) {
                        startSplitSession(title: "Pull Day")
                    }

                    uberQuickTile(
                        title: "Legs",
                        symbol: "figure.run",
                        badge: nil
                    ) {
                        startSplitSession(title: "Leg Day")
                    }

                    uberQuickTile(
                        title: "Recap",
                        symbol: "waveform.badge.plus",
                        badge: nil
                    ) {
                        onStartFullSessionRecap()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Try saying or tapping")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BuddyTheme.mutedText)

                quickTryChipStrip
            }

            if !completedSessions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent workouts")
                            .font(BuddyTheme.sectionTitleFont)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(completedSessions.count) total")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(BuddyTheme.mutedText)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(WorkoutSplitFilter.allCases) { filter in
                                FilterChip(
                                    title: filter.rawValue,
                                    isSelected: selectedRecentFilter == filter
                                ) {
                                    selectedRecentFilter = filter
                                }
                            }
                        }
                    }

                    if filteredRecent.isEmpty {
                        Text("No \(selectedRecentFilter.rawValue.lowercased()) sessions logged yet.")
                            .font(.subheadline)
                            .foregroundStyle(BuddyTheme.mutedText)
                            .padding(.vertical, 12)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(Array(filteredRecent.prefix(6)), id: \.id) { session in
                                NavigationLink {
                                    SessionDetailView(session: session, store: store)
                                } label: {
                                    youtubeSessionRow(session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func weeklyGoalBanner(consistency: ConsistencyStats) -> some View {
        let progress = consistency.weeklyGoal > 0
            ? min(1.0, Double(consistency.workoutsThisWeek) / Double(consistency.weeklyGoal))
            : 0.0

        return NativeCard(padding: 14, cornerRadius: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(BuddyTheme.elevatedSurface)
                        .frame(width: 42, height: 42)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(consistency.currentStreakDays > 0 ? BuddyTheme.amberStreak : BuddyTheme.mutedText)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Weekly goal · \(consistency.workoutsThisWeek) of \(consistency.weeklyGoal)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(consistency.currentStreakDays)d streak")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(BuddyTheme.mutedText)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(BuddyTheme.elevatedSurface)
                            Capsule(style: .continuous)
                                .fill(BuddyTheme.inkPrimary)
                                .frame(width: max(progress > 0 ? 10 : 0, proxy.size.width * progress))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
    }

    private func uberQuickTile(
        title: String,
        symbol: String,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            BuddyHaptics.lightImpact()
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .top) {
                    Circle()
                        .fill(BuddyTheme.cardSurface)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Circle()
                                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
                        }
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.primary)
                        }

                    if let badge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(BuddyTheme.destructive))
                            .offset(y: -6)
                    }
                }

                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var quickTryChipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(examplePhrases, id: \.command) { item in
                    Button {
                        BuddyHaptics.lightImpact()
                        pipeline.processTypedInput(item.command, into: store)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(BuddyTheme.mutedText)
                            Text("“\(item.chip)”")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(BuddyTheme.chipSurface)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func youtubeSessionRow(_ session: WorkoutSession) -> some View {
        let isCheckInOnly = (session.totalSets == 0 && session.isManualCheckInDay)
        let badgeText = isCheckInOnly
            ? "Check-in"
            : DurationFormatter.formatClock(seconds: max(1, session.durationSeconds))

        return HStack(alignment: .top, spacing: 12) {
            WorkoutThumbnailView(
                assetName: session.primaryMuscleGroup.thumbnailAssetName,
                bottomRightBadge: badgeText,
                topLeftTag: Calendar.current.isDateInToday(session.startedAt) ? "Today" : nil,
                width: 132,
                height: 76
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(session.derivedTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(
                    isCheckInOnly
                        ? session.startedAt.formatted(date: .abbreviated, time: .omitted)
                        : session.startedAt.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BuddyTheme.mutedText)
                .lineLimit(1)

                if isCheckInOnly {
                    Text(session.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Marked as trained" : session.notes)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BuddyTheme.emeraldLive)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        Text("\(session.exerciseCount) \(session.exerciseCount == 1 ? "lift" : "lifts")")
                            .monospacedDigit()
                        Text("·")
                        Text("\(session.totalSets) \(session.totalSets == 1 ? "set" : "sets")")
                            .monospacedDigit()
                        if session.totalReps > 0 {
                            Text("·")
                            Text("\(session.totalReps) reps")
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BuddyTheme.mutedText)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Monochrome Auto-Save Undo Toast

    private func autoSaveToast(_ banner: WorkoutMutationBanner) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(BuddyTheme.emeraldLive)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(banner.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(banner.parserSource.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BuddyTheme.mutedText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )
                    }

                    Text(banner.detail)
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.mutedText)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                Button {
                    store.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(BuddyTheme.mutedText)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                if let setID = banner.editableSetID, let foundSet = store.findSet(id: setID) {
                    Button {
                        BuddyHaptics.lightImpact()
                        editingSet = foundSet
                        store.dismissBanner()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(BuddyTheme.inkInverse)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(BuddyTheme.inkPrimary))
                    }
                    .buttonStyle(.plain)
                }

                if banner.canUndo {
                    Button {
                        BuddyHaptics.warning()
                        store.undoLastMutation()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(BuddyTheme.elevatedSurface))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(BuddyTheme.floatingBarSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(BuddyTheme.glassBorder, lineWidth: 0.9)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    // MARK: - Helpers

    private func startSplitSession(title: String) {
        _ = store.startNewSession(title: title)
    }

    private func matchesRecentFilter(_ session: WorkoutSession) -> Bool {
        guard selectedRecentFilter != .all else { return true }
        let category = WorkoutSplitFilter.classify(
            muscleGroups: session.entries.map(\.muscleGroup),
            title: session.derivedTitle
        )
        return category == selectedRecentFilter
    }

    private func addQuickSet(to entry: ExerciseEntry) {
        BuddyHaptics.lightImpact()
        let template = entry.sortedSets.last
        _ = store.addSet(
            to: entry,
            reps: template?.reps ?? (template?.durationSeconds == nil ? 10 : nil),
            weightKg: template?.weightKg,
            durationSeconds: template?.durationSeconds,
            tag: .normal,
            notes: ""
        )
    }
}
