import SwiftUI
import SwiftData

struct SessionSummarySheet: View {
    @Environment(\.modelContext) private var modelContext

    let session: WorkoutSession
    let unit: WeightUnit
    let onDismiss: () -> Void

    private let initialDerivedTitle: String
    @State private var editableTitle: String
    @State private var hasCommittedTitle: Bool = false

    init(session: WorkoutSession, unit: WeightUnit, onDismiss: @escaping () -> Void) {
        self.session = session
        self.unit = unit
        self.onDismiss = onDismiss
        let derived = session.derivedTitle
        self.initialDerivedTitle = derived
        _editableTitle = State(initialValue: derived)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    celebrationHeader

                    summaryMetricGrid

                    if !session.sortedEntries.isEmpty {
                        exerciseBreakdownCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                doneBar
            }
            .navigationTitle("Workout Complete")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                commitTitleIfEdited()
            }
        }
    }

    private var celebrationHeader: some View {
        NativeCard(padding: 18, cornerRadius: 22, tint: BuddyTheme.cobalt) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [BuddyTheme.cobalt, BuddyTheme.cobaltDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                        .shadow(color: BuddyTheme.cobalt.opacity(0.32), radius: 12, x: 0, y: 5)

                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("Workout Title", text: $editableTitle)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)

                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                    )

                    HStack(spacing: 8) {
                        Label(
                            DurationFormatter.formatCompact(seconds: session.durationSeconds),
                            systemImage: "clock"
                        )
                        Text("·")
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption.weight(.medium))
                    .buddyNumeric()
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var summaryMetricGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]

        return LazyVGrid(columns: columns, spacing: 10) {
            StatMetricTile(
                title: "Total Volume",
                value: session.totalVolumeKg > 0 ? unit.formatVolume(kg: session.totalVolumeKg) : "—",
                icon: "scalemass.fill",
                tint: BuddyTheme.cobalt
            )
            StatMetricTile(
                title: "Total Sets",
                value: "\(session.totalSets)",
                icon: "square.stack.3d.up.fill",
                tint: BuddyTheme.emeraldLive
            )
            StatMetricTile(
                title: "Total Reps",
                value: "\(session.totalReps)",
                icon: "repeat",
                tint: BuddyTheme.amberStreak
            )
            StatMetricTile(
                title: "Exercises",
                value: "\(session.exerciseCount)",
                icon: "figure.strengthtraining.traditional",
                tint: BuddyTheme.cobalt
            )
        }
    }

    private var exerciseBreakdownCard: some View {
        NativeCard(padding: 16, cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Exercise Breakdown")
                    .font(.headline)
                    .foregroundStyle(.primary)

                VStack(spacing: 10) {
                    ForEach(session.sortedEntries, id: \.id) { entry in
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: entry.muscleGroup.symbolName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BuddyTheme.cobalt)
                                .frame(width: 30, height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(BuddyTheme.cobaltSoft)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.exerciseName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(entry.muscleGroup.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            Text(entry.compactSummary(unit: unit))
                                .font(.caption.weight(.semibold))
                                .buddyNumeric()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var doneBar: some View {
        Button {
            commitTitleIfEdited()
            BuddyHaptics.success()
            onDismiss()
        } label: {
            Text("Done")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(BuddyTheme.cobalt)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func commitTitleIfEdited() {
        guard !hasCommittedTitle else { return }
        hasCommittedTitle = true

        let trimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialTrimmed = initialDerivedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != initialTrimmed else { return }

        session.title = trimmed.isEmpty ? "Workout" : trimmed
        try? modelContext.save()
    }
}
