import SwiftUI

struct WorkoutHomeView: View {
    let store: WorkoutStore
    let pipeline: VoicePipelineCoordinator
    let modelManager: ModelManager
    let appleSpeechService: AppleSpeechService
    let whisperService: WhisperTranscriptionService
    let llmService: LocalLLMService
    var dismissSheetsToken: Int = 0

    @State private var showSettings: Bool = false
    @State private var showManualAdd: Bool = false
    @State private var editingSet: LoggedSet?
    @State private var showEndSessionDialog: Bool = false

    private let examplePhrases: [String] = [
        "Leg extension 3 sets 15 reps",
        "Bench press 60 kg 3 sets 10 reps",
        "Plank 60 seconds"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let session = store.activeSession {
                        activeSessionContent(session)
                    } else {
                        idleHomeContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .navigationTitle("Buddy")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        BuddyHaptics.lightImpact()
                        showManualAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Add exercise manually")

                    Button {
                        BuddyHaptics.lightImpact()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.body.weight(.medium))
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomOverlay
            }
            .onChange(of: dismissSheetsToken) { _, _ in
                showSettings = false
                showManualAdd = false
                editingSet = nil
                showEndSessionDialog = false
                store.recentlyEndedSession = nil
            }
            .confirmationDialog(
                "End current workout?",
                isPresented: $showEndSessionDialog,
                titleVisibility: .visible
            ) {
                Button("End & Save Workout") {
                    BuddyHaptics.success()
                    _ = store.endActiveSession()
                    WidgetRefreshHelper.sync(store: store)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your workout summary will be saved to Trends and synced with widgets.")
            }
            .sheet(item: $editingSet) { set in
                SetEditorSheet(set: set, store: store)
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
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showManualAdd) {
                ManualAddExerciseSheet(store: store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    store: store,
                    modelManager: modelManager,
                    appleSpeechService: appleSpeechService,
                    whisperService: whisperService,
                    llmService: llmService
                )
            }
        }
    }

    // MARK: - Active Session Layout

    @ViewBuilder
    private func activeSessionContent(_ session: WorkoutSession) -> some View {
        liveSessionBanner(session)

        perSessionStatStrip(session)

        let entries = session.sortedEntries
        if entries.isEmpty {
            emptyActiveSessionCard
        } else {
            LazyVStack(spacing: 12) {
                ForEach(entries, id: \.id) { entry in
                    ExerciseCardView(
                        entry: entry,
                        unit: store.preferredUnit,
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
            .animation(.snappy(duration: 0.28), value: entries.map(\.id))
        }
    }

    private func liveSessionBanner(_ session: WorkoutSession) -> some View {
        NativeCard(padding: 16, cornerRadius: 20, tint: BuddyTheme.emeraldLive) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusPill(
                            text: "LIVE",
                            tint: BuddyTheme.emeraldLive,
                            isPulsing: true
                        )

                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = max(0, Int(context.date.timeIntervalSince(session.startedAt)))
                            Text(DurationFormatter.formatClock(seconds: elapsed))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(session.derivedTitle)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    BuddyHaptics.mediumImpact()
                    showEndSessionDialog = true
                } label: {
                    Text("End")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(BuddyTheme.cobalt)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func perSessionStatStrip(_ session: WorkoutSession) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            StatMetricTile(
                title: "Volume",
                value: compactVolumeString(kg: session.totalVolumeKg),
                tint: BuddyTheme.cobalt,
                compact: true
            )
            StatMetricTile(
                title: "Sets",
                value: "\(session.totalSets)",
                tint: BuddyTheme.cobalt,
                compact: true
            )
            StatMetricTile(
                title: "Reps",
                value: "\(session.totalReps)",
                tint: BuddyTheme.cobalt,
                compact: true
            )
            StatMetricTile(
                title: "Exercises",
                value: "\(session.exerciseCount)",
                tint: BuddyTheme.cobalt,
                compact: true
            )
        }
    }

    private var emptyActiveSessionCard: some View {
        NativeCard(padding: 18, cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session Started")
                        .font(.headline)
                    Text("Tap or hold the mic below to log your first set, or tap an example phrase to try it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                examplePhraseList
            }
        }
    }

    // MARK: - Idle Home Layout

    private var idleHomeContent: some View {
        let consistency = StatsCalculator.consistency(
            sessions: store.sessions,
            referenceDate: Date(),
            weeklyGoal: 4
        )
        let recentSessions = Array(
            store.sessions
                .filter { !$0.isActive }
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(3)
        )

        return VStack(spacing: 16) {
            readyToTrainHeroCard(consistency: consistency)

            if !recentSessions.isEmpty {
                recentSessionsSection(recentSessions)
            }
        }
    }

    private func readyToTrainHeroCard(consistency: ConsistencyStats) -> some View {
        let progress = consistency.weeklyGoal > 0
            ? min(1.0, Double(consistency.workoutsThisWeek) / Double(consistency.weeklyGoal))
            : 0.0

        return NativeCard(padding: 18, cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    StatusPill(
                        text: "\(consistency.currentStreakDays)d streak",
                        icon: "flame.fill",
                        tint: consistency.currentStreakDays > 0 ? BuddyTheme.amberStreak : .secondary
                    )

                    StatusPill(
                        text: "\(consistency.workoutsThisWeek) / \(consistency.weeklyGoal) this week",
                        icon: "calendar",
                        tint: BuddyTheme.cobalt
                    )

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Ready to Train")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("Speak naturally after a set and Buddy starts your session and logs everything automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(BuddyTheme.cobaltSoft)
                            Capsule(style: .continuous)
                                .fill(BuddyTheme.cobalt)
                                .frame(width: max(progress > 0 ? 12 : 0, proxy.size.width * progress))
                        }
                    }
                    .frame(height: 7)

                    HStack {
                        Text("Weekly goal")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(consistency.totalWorkouts) total \(consistency.totalWorkouts == 1 ? "workout" : "workouts")")
                            .font(.caption2.weight(.semibold))
                            .buddyNumeric()
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("TRY SAYING OR TAPPING")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    examplePhraseList
                }

                Button {
                    BuddyHaptics.lightImpact()
                    _ = store.startNewSession(title: "Workout")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                        Text("Start Empty Session")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(BuddyTheme.cobalt)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(BuddyTheme.cobaltSoft)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var examplePhraseList: some View {
        VStack(spacing: 8) {
            ForEach(examplePhrases, id: \.self) { phrase in
                Button {
                    BuddyHaptics.lightImpact()
                    pipeline.processTypedInput(phrase, into: store)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BuddyTheme.cobalt)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(BuddyTheme.cobaltSoft))

                        Text("“\(phrase)”")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 4)

                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func recentSessionsSection(_ sessions: [WorkoutSession]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Sessions")
                    .font(BuddyTheme.sectionTitleFont)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 10) {
                ForEach(sessions, id: \.id) { session in
                    NavigationLink {
                        SessionDetailView(session: session, store: store)
                    } label: {
                        NativeCard(padding: 14, cornerRadius: 16) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(BuddyTheme.cobaltSoft)
                                        .frame(width: 42, height: 42)
                                    Image(systemName: session.sortedEntries.first?.muscleGroup.symbolName ?? "figure.strengthtraining.traditional")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(BuddyTheme.cobalt)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.derivedTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(DurationFormatter.formatCompact(seconds: session.durationSeconds))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(session.totalSets) sets")
                                        .font(.caption.weight(.bold))
                                        .buddyNumeric()
                                        .foregroundStyle(.primary)

                                    if session.totalVolumeKg > 0 {
                                        Text(store.preferredUnit.formatVolume(kg: session.totalVolumeKg))
                                            .font(.caption2.weight(.medium))
                                            .buddyNumeric()
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Bottom Overlay (Confirmation Toast + Floating Voice Dock)

    private var bottomOverlay: some View {
        VStack(spacing: 10) {
            if let banner = store.latestBanner {
                autoSaveToast(banner)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        guard !Task.isCancelled else { return }
                        if store.latestBanner?.id == banner.id {
                            store.dismissBanner()
                        }
                    }
            }

            VoiceRecordDock(pipeline: pipeline, store: store)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.25), value: store.latestBanner?.id)
    }

    private func autoSaveToast(_ banner: WorkoutMutationBanner) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BuddyTheme.emeraldLive)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(banner.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(banner.parserSource.rawValue)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(BuddyTheme.cobalt)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(BuddyTheme.cobaltSoft))
                    }

                    Text(banner.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                Button {
                    store.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
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
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BuddyTheme.cobalt)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(BuddyTheme.cobaltSoft))
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
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(BuddyTheme.glassBorder, lineWidth: 0.85)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 6)
    }

    // MARK: - Helpers

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

    private func compactVolumeString(kg: Double) -> String {
        if kg <= 0 { return "0 \(store.preferredUnit.label)" }
        return store.preferredUnit.formatVolume(kg: kg)
    }
}

// MARK: - Quick Manual Add Exercise Sheet

private struct ManualAddExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: WorkoutStore

    @State private var exerciseName: String = ""
    @State private var setsCount: Int = 3
    @State private var repsCount: Int = 10
    @State private var includeReps: Bool = true
    @State private var weightText: String = ""
    @State private var durationText: String = ""
    @State private var tag: SetTag = .normal

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("e.g. Bench Press, Leg Extension, Plank", text: $exerciseName)
                        .autocorrectionDisabled(false)
                }

                Section("Prescription") {
                    Stepper(value: $setsCount, in: 1...20) {
                        HStack {
                            Text("Sets")
                            Spacer()
                            Text("\(setsCount)")
                                .buddyNumeric()
                                .fontWeight(.semibold)
                                .foregroundStyle(BuddyTheme.cobalt)
                        }
                    }

                    Toggle("Track Reps", isOn: $includeReps)

                    if includeReps {
                        Stepper(value: $repsCount, in: 1...200) {
                            HStack {
                                Text("Reps")
                                Spacer()
                                Text("\(repsCount)")
                                    .buddyNumeric()
                                    .fontWeight(.semibold)
                                    .foregroundStyle(BuddyTheme.cobalt)
                            }
                        }
                    }

                    HStack {
                        Text("Weight (\(store.preferredUnit.label))")
                        Spacer()
                        TextField("Bodyweight", text: $weightText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .buddyNumeric()
                    }

                    HStack {
                        Text("Duration (sec)")
                        Spacer()
                        TextField("Optional", text: $durationText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .buddyNumeric()
                    }
                }

                Section("Set Type") {
                    Picker("Type", selection: $tag) {
                        ForEach(SetTag.allCases) { item in
                            Text(item.displayLabel).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saveExercise()
                    }
                    .fontWeight(.semibold)
                    .disabled(exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveExercise() {
        let trimmedName = exerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let parsedWeight = Double(weightText.replacingOccurrences(of: ",", with: "."))
        let weightKg = parsedWeight.flatMap { $0 > 0 ? store.preferredUnit.toKg($0) : nil }
        let parsedDuration = Int(durationText).flatMap { $0 > 0 ? $0 : nil }
        let finalReps = includeReps ? repsCount : nil

        store.addManualExercise(
            name: trimmedName,
            sets: setsCount,
            reps: finalReps,
            weightKg: weightKg,
            durationSeconds: parsedDuration,
            tag: tag
        )
        BuddyHaptics.success()
        dismiss()
    }
}
