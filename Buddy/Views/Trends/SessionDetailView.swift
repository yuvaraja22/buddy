import SwiftUI

struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let session: WorkoutSession
    let store: WorkoutStore

    @State private var editingSet: LoggedSet?
    @State private var showDeleteConfirmation: Bool = false
    @State private var isDeletingSession: Bool = false
    @State private var titleSnapshot: String = ""

    var body: some View {
        Group {
            if isDeletingSession {
                BuddyTheme.canvasBackground.ignoresSafeArea()
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        sessionHeaderCard
                        metricsGrid
                        exercisesSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, BuddyTheme.floatingBarClearance)
                }
                .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            }
        }
        .navigationTitle(isDeletingSession ? titleSnapshot : session.derivedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            titleSnapshot = session.derivedTitle
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.primary)
                }
            }
        }
        .alert("Delete Workout Session?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                BuddyHaptics.warning()
                titleSnapshot = session.derivedTitle
                isDeletingSession = true
                dismiss()
                let targetSession = session
                Task { @MainActor in
                    store.deleteSession(targetSession)
                    WidgetRefreshHelper.sync(store: store)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the session and all of its logged sets from your history.")
        }
        .sheet(item: $editingSet) { set in
            SetEditorSheet(set: set, store: store)
                .buddyAppearance()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var sessionHeaderCard: some View {
        NativeCard(padding: 15, cornerRadius: 14, tint: session.isActive ? BuddyTheme.emeraldLive : nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if session.isActive {
                        StatusPill(text: "LIVE", tint: BuddyTheme.emeraldLive, isPulsing: true)
                    } else {
                        StatusPill(
                            text: DurationFormatter.formatCompact(seconds: session.durationSeconds),
                            icon: "clock",
                            tint: BuddyTheme.inkPrimary
                        )
                    }
                    Spacer()
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(BuddyTheme.mutedText)
                }

                Text(session.derivedTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)

                if !session.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(session.notes)
                        .font(.subheadline)
                        .foregroundStyle(BuddyTheme.mutedText)
                }
            }
        }
    }

    private var metricsGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            StatMetricTile(
                title: "Volume",
                value: session.totalVolumeKg > 0 ? store.preferredUnit.formatVolume(kg: session.totalVolumeKg) : "—",
                compact: true
            )
            StatMetricTile(
                title: "Sets",
                value: "\(session.totalSets)",
                compact: true
            )
            StatMetricTile(
                title: "Reps",
                value: "\(session.totalReps)",
                compact: true
            )
            StatMetricTile(
                title: "Lifts",
                value: "\(session.exerciseCount)",
                compact: true
            )
        }
    }

    @ViewBuilder
    private var exercisesSection: some View {
        let entries = session.sortedEntries
        if entries.isEmpty {
            NativeCard(padding: 16, cornerRadius: 14) {
                Text("No exercises were recorded in this session.")
                    .font(.subheadline)
                    .foregroundStyle(BuddyTheme.mutedText)
            }
        } else {
            VStack(spacing: 12) {
                ForEach(entries, id: \.id) { entry in
                    exerciseTableCard(entry)
                }
            }
        }
    }

    private func exerciseTableCard(_ entry: ExerciseEntry) -> some View {
        let setCountBadge = "\(entry.sets.count) \(entry.sets.count == 1 ? "set" : "sets")"
        return NativeCard(padding: 13, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    WorkoutThumbnailView(
                        assetName: entry.muscleGroup.thumbnailAssetName,
                        bottomRightBadge: setCountBadge,
                        width: 76,
                        height: 46
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.exerciseName)
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("\(entry.muscleGroup.rawValue) · \(entry.compactSummary(unit: store.preferredUnit))")
                            .font(.caption.weight(.medium))
                            .buddyNumeric()
                            .foregroundStyle(BuddyTheme.mutedText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Button {
                        BuddyHaptics.lightImpact()
                        let last = entry.sortedSets.last
                        _ = store.addSet(
                            to: entry,
                            reps: last?.reps ?? (last?.durationSeconds == nil ? 10 : nil),
                            weightKg: last?.weightKg,
                            durationSeconds: last?.durationSeconds,
                            tag: .normal,
                            notes: ""
                        )
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text("Set")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(BuddyTheme.inkInverse)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(BuddyTheme.inkPrimary)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .overlay(BuddyTheme.hairlineBorder)

                HStack {
                    Text("SET")
                        .frame(width: 34, alignment: .leading)
                    Text("LOAD")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("REPS / TIME")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("TAG")
                        .frame(width: 54, alignment: .trailing)
                }
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(BuddyTheme.mutedText)
                .padding(.horizontal, 6)

                VStack(spacing: 6) {
                    ForEach(entry.sortedSets, id: \.id) { set in
                        Button {
                            BuddyHaptics.selection()
                            editingSet = set
                        } label: {
                            HStack {
                                Text(String(format: "%02d", set.setNumber))
                                    .font(.system(size: 12, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(BuddyTheme.mutedText)
                                    .frame(width: 34, alignment: .leading)

                                Text(set.weightKg.flatMap { $0 > 0 ? store.preferredUnit.formatWeight(kg: $0) : nil } ?? "BW")
                                    .font(.system(size: 14, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(repsOrTimeLabel(for: set))
                                    .font(.system(size: 14, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack(spacing: 4) {
                                    if let badge = set.tag.shortBadge {
                                        let tint = BuddyTheme.tagTint(for: set.tag)
                                        Text(badge)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(tint)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                    .fill(tint.opacity(0.16))
                                            )
                                    } else {
                                        Text("—")
                                            .font(.caption)
                                            .foregroundStyle(BuddyTheme.mutedText)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(BuddyTheme.mutedText)
                                }
                                .frame(width: 54, alignment: .trailing)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editingSet = set
                            } label: {
                                Label("Edit Set", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                BuddyHaptics.warning()
                                store.deleteSet(set)
                            } label: {
                                Label("Delete Set", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func repsOrTimeLabel(for set: LoggedSet) -> String {
        if let reps = set.reps, reps > 0, let duration = set.durationSeconds, duration > 0 {
            return "\(reps) · \(DurationFormatter.formatCompact(seconds: duration))"
        }
        if let reps = set.reps, reps > 0 {
            return "\(reps) reps"
        }
        if let duration = set.durationSeconds, duration > 0 {
            return DurationFormatter.formatCompact(seconds: duration)
        }
        return "Done"
    }
}
