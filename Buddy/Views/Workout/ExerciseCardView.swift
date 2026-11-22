import SwiftUI

/// YouTube-inspired split exercise card:
/// - Left: 16:9 dark studio workout artwork thumbnail with crisp bottom-right set badge & optional top-left "New" tag.
/// - Right: Bold sans-serif exercise title, muted muscle/volume metadata, directly tappable monochrome set chips, and "+ Set".
/// - Tap card to expand/collapse detailed set rows for quick review & editing.
struct ExerciseCardView: View {
    let entry: ExerciseEntry
    let unit: WeightUnit
    let isLatest: Bool
    let onAddSet: () -> Void
    let onSelectSet: (LoggedSet) -> Void
    let onDeleteSet: (LoggedSet) -> Void
    let onDeleteEntry: () -> Void

    @State private var isExpanded: Bool = false

    var body: some View {
        let orderedSets = entry.sortedSets
        let setCountText = "\(orderedSets.count) \(orderedSets.count == 1 ? "set" : "sets")"

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    BuddyHaptics.selection()
                    withAnimation(.snappy(duration: 0.22)) {
                        isExpanded.toggle()
                    }
                } label: {
                    WorkoutThumbnailView(
                        assetName: entry.muscleGroup.thumbnailAssetName,
                        bottomRightBadge: setCountText,
                        topLeftTag: isLatest ? "New" : nil,
                        width: 132,
                        height: 80
                    )
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 6) {
                        Button {
                            BuddyHaptics.selection()
                            withAnimation(.snappy(duration: 0.22)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Text(entry.exerciseName)
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Menu {
                            Button {
                                onAddSet()
                            } label: {
                                Label("Add Set", systemImage: "plus")
                            }

                            Button {
                                withAnimation(.snappy(duration: 0.22)) {
                                    isExpanded.toggle()
                                }
                            } label: {
                                Label(isExpanded ? "Collapse Sets" : "Show All Sets", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            }

                            Divider()

                            Button(role: .destructive) {
                                onDeleteEntry()
                            } label: {
                                Label("Delete Exercise", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(BuddyTheme.mutedText)
                                .frame(width: 26, height: 22)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Exercise options")
                    }

                    Text("\(entry.muscleGroup.rawValue) · \(entry.compactSummary(unit: unit))")
                        .font(.system(size: 12, weight: .medium))
                        .buddyNumeric()
                        .foregroundStyle(BuddyTheme.mutedText)
                        .lineLimit(1)

                    // Compact inline set chips + "+ Set" action right beside the thumbnail
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(orderedSets, id: \.id) { set in
                                Button {
                                    onSelectSet(set)
                                } label: {
                                    inlineSetChip(set)
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

                            Button {
                                onAddSet()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("Set")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(BuddyTheme.inkInverse)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(BuddyTheme.inkPrimary)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add set to \(entry.exerciseName)")
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)

            if isExpanded {
                Divider()
                    .overlay(BuddyTheme.hairlineBorder)
                    .padding(.horizontal, 12)

                VStack(spacing: 6) {
                    if orderedSets.isEmpty {
                        Text("No sets logged yet")
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(orderedSets, id: \.id) { set in
                            expandedSetRow(set)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
        }
    }

    private func inlineSetChip(_ set: LoggedSet) -> some View {
        HStack(spacing: 4) {
            if let badge = set.tag.shortBadge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(BuddyTheme.tagTint(for: set.tag))
            }

            Text(compactChipLabel(for: set))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7.5)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(BuddyTheme.chipSurface)
        )
    }

    private func expandedSetRow(_ set: LoggedSet) -> some View {
        Button {
            onSelectSet(set)
        } label: {
            HStack(spacing: 10) {
                Text(String(format: "%02d", set.setNumber))
                    .font(.system(size: 11.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(BuddyTheme.mutedText)
                    .frame(width: 24, alignment: .leading)

                if let badge = set.tag.shortBadge {
                    let tint = BuddyTheme.tagTint(for: set.tag)
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(tint.opacity(0.16))
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        if let weightKg = set.weightKg, weightKg > 0 {
                            Text(unit.formatWeight(kg: weightKg))
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }

                        if let reps = set.reps, reps > 0 {
                            if (set.weightKg ?? 0) > 0 {
                                Text("×")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(BuddyTheme.mutedText)
                            }
                            Text("\(reps) reps")
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }

                        if let duration = set.durationSeconds, duration > 0 {
                            if (set.reps ?? 0) > 0 || (set.weightKg ?? 0) > 0 {
                                Text("·")
                                    .foregroundStyle(BuddyTheme.mutedText)
                            }
                            Text(DurationFormatter.formatCompact(seconds: duration))
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }

                        if (set.weightKg ?? 0) <= 0 && (set.reps ?? 0) <= 0 && (set.durationSeconds ?? 0) <= 0 {
                            Text("Completed")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(BuddyTheme.mutedText)
                        }
                    }

                    if !set.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(set.notes)
                            .font(.caption2)
                            .foregroundStyle(BuddyTheme.mutedText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BuddyTheme.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(BuddyTheme.elevatedSurface)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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

    private func compactChipLabel(for set: LoggedSet) -> String {
        if let weightKg = set.weightKg, weightKg > 0, let reps = set.reps, reps > 0 {
            return "\(unit.formatWeightNumber(kg: weightKg))×\(reps)"
        }
        if let reps = set.reps, reps > 0 {
            return "\(reps)r"
        }
        if let duration = set.durationSeconds, duration > 0 {
            return DurationFormatter.formatCompact(seconds: duration)
        }
        if let weightKg = set.weightKg, weightKg > 0 {
            return unit.formatWeight(kg: weightKg)
        }
        return "Done"
    }
}
