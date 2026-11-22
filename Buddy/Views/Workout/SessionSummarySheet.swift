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
                VStack(spacing: 16) {
                    celebrationHeader
                    summaryMetricGrid

                    if !session.sortedEntries.isEmpty {
                        exerciseBreakdownCard
                    }
                }
                .padding(.horizontal, 16)
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
        NativeCard(padding: 18, cornerRadius: 16) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(BuddyTheme.inkPrimary)
                        .frame(width: 54, height: 54)

                    Image(systemName: "checkmark")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(BuddyTheme.inkInverse)
                }

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("Workout Title", text: $editableTitle)
                            .font(.system(size: 20, weight: .bold))
                            .multilineTextAlignment(.center)

                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                    .foregroundStyle(BuddyTheme.mutedText)
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
                tint: BuddyTheme.inkPrimary
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
                tint: BuddyTheme.inkPrimary
            )
            StatMetricTile(
                title: "Exercises",
                value: "\(session.exerciseCount)",
                icon: "figure.strengthtraining.traditional",
                tint: BuddyTheme.inkPrimary
            )
        }
    }

    private var exerciseBreakdownCard: some View {
        NativeCard(padding: 14, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Exercise Breakdown")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                VStack(spacing: 10) {
                    ForEach(session.sortedEntries, id: \.id) { entry in
                        HStack(alignment: .center, spacing: 10) {
                            WorkoutThumbnailView(
                                assetName: entry.muscleGroup.thumbnailAssetName,
                                bottomRightBadge: "\(entry.sets.count)s",
                                width: 68,
                                height: 42
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.exerciseName)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.primary)
                                Text(entry.muscleGroup.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(BuddyTheme.mutedText)
                            }

                            Spacer(minLength: 8)

                            Text(entry.compactSummary(unit: unit))
                                .font(.caption.weight(.semibold))
                                .buddyNumeric()
                                .foregroundStyle(BuddyTheme.mutedText)
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
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(BuddyTheme.inkInverse)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(BuddyTheme.inkPrimary)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(BuddyTheme.canvasBackground)
        .overlay(alignment: .top) {
            Divider().overlay(BuddyTheme.hairlineBorder)
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
