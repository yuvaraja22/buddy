import SwiftUI

struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let session: WorkoutSession
    let store: WorkoutStore

    @State private var editingSet: LoggedSet?
    @State private var showDeleteConfirmation: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                sessionHeaderCard
                metricsGrid
                exercisesSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .background(BuddyTheme.canvasBackground.ignoresSafeArea())
        .navigationTitle(session.derivedTitle)
        .navigationBarTitleDisplayMode(.inline)
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
                }
            }
        }
        .alert("Delete Workout Session?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                BuddyHaptics.warning()
                store.deleteSession(session)
                WidgetRefreshHelper.sync(store: store)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the session and all of its logged sets from your history.")
        }
        .sheet(item: $editingSet) { set in
            SetEditorSheet(set: set, store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var sessionHeaderCard: some View {
        NativeCard(padding: 16, cornerRadius: 20, tint: session.isActive ? BuddyTheme.emeraldLive : nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if session.isActive {
                        StatusPill(text: "ACTIVE SESSION", tint: BuddyTheme.emeraldLive, isPulsing: true)
                    } else {
                        StatusPill(
                            text: DurationFormatter.formatCompact(seconds: session.durationSeconds),
                            icon: "clock",
                            tint: BuddyTheme.cobalt
                        )
                    }
                    Spacer()
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(session.derivedTitle)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                if !session.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(session.notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var exercisesSection: some View {
        let entries = session.sortedEntries
        if entries.isEmpty {
            NativeCard(padding: 18, cornerRadius: 18) {
                Text("No exercises were recorded in this session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        NativeCard(padding: 15, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.exerciseName)
                                .font(.headline)
                            Text(entry.muscleGroup.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(BuddyTheme.cobalt)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(BuddyTheme.cobaltSoft))
                        }

                        Text(entry.compactSummary(unit: store.preferredUnit))
                            .font(.caption)
                            .buddyNumeric()
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

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
                        Label("Set", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BuddyTheme.cobalt)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(BuddyTheme.cobaltSoft))
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

                VStack(spacing: 6) {
                    ForEach(entry.sortedSets, id: \.id) { set in
                        Button {
                            BuddyHaptics.selection()
                            editingSet = set
                        } label: {
                            HStack {
                                Text("\(set.setNumber)")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .leading)

                                Text(set.weightKg.flatMap { $0 > 0 ? store.preferredUnit.formatWeight(kg: $0) : nil } ?? "BW")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(repsOrTimeLabel(for: set))
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack(spacing: 4) {
                                    if let badge = set.tag.shortBadge {
                                        let tint = BuddyTheme.tagTint(for: set.tag)
                                        Text(badge)
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(tint)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(tint.opacity(0.16)))
                                    } else {
                                        Text("—")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(width: 54, alignment: .trailing)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface.opacity(0.65))
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
