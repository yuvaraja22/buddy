import SwiftUI

struct ExerciseCardView: View {
    let entry: ExerciseEntry
    let unit: WeightUnit
    let onAddSet: () -> Void
    let onSelectSet: (LoggedSet) -> Void
    let onDeleteSet: (LoggedSet) -> Void
    let onDeleteEntry: () -> Void

    var body: some View {
        NativeCard(padding: 15, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow

                Divider()
                    .overlay(BuddyTheme.hairlineBorder)

                let orderedSets = entry.sortedSets
                if orderedSets.isEmpty {
                    Text("No sets logged yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 6) {
                        ForEach(orderedSets, id: \.id) { set in
                            setRow(set)
                        }
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.exerciseName)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    muscleBadge
                }

                Text(entry.compactSummary(unit: unit))
                    .font(.caption.weight(.medium))
                    .buddyNumeric()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    onAddSet()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Set")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(BuddyTheme.cobalt)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(BuddyTheme.cobaltSoft)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add set to \(entry.exerciseName)")

                Menu {
                    Button(role: .destructive) {
                        onDeleteEntry()
                    } label: {
                        Label("Delete Exercise", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Exercise options")
            }
        }
    }

    private var muscleBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: entry.muscleGroup.symbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(entry.muscleGroup.rawValue)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(BuddyTheme.cobalt)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(BuddyTheme.cobaltSoft)
        )
    }

    private func setRow(_ set: LoggedSet) -> some View {
        Button {
            onSelectSet(set)
        } label: {
            HStack(spacing: 10) {
                Text("\(set.setNumber)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(BuddyTheme.elevatedSurface)
                    )

                if let badge = set.tag.shortBadge {
                    let tint = BuddyTheme.tagTint(for: set.tag)
                    Text(badge)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tint.opacity(0.16))
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if let weightKg = set.weightKg, weightKg > 0 {
                            Text(unit.formatWeight(kg: weightKg))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }

                        if let reps = set.reps, reps > 0 {
                            if set.weightKg != nil && (set.weightKg ?? 0) > 0 {
                                Text("×")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text("\(reps) reps")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }

                        if let duration = set.durationSeconds, duration > 0 {
                            if (set.reps ?? 0) > 0 || (set.weightKg ?? 0) > 0 {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                            }
                            Text(DurationFormatter.formatCompact(seconds: duration))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }

                        if (set.weightKg ?? 0) <= 0 && (set.reps ?? 0) <= 0 && (set.durationSeconds ?? 0) <= 0 {
                            Text("Completed")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !set.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(set.notes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(BuddyTheme.elevatedSurface.opacity(0.65))
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onSelectSet(set)
            } label: {
                Label("Edit Set", systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDeleteSet(set)
            } label: {
                Label("Delete Set", systemImage: "trash")
            }
        }
    }
}
