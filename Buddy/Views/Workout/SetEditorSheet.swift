import SwiftUI

/// Pure OLED monochrome set editor matching Buddy's YouTube/Uber card & pill style.
struct SetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let set: LoggedSet
    let store: WorkoutStore

    // Value snapshots captured on init so animated sheet dismissal never touches
    // a deleted SwiftData backing object, and untouched weight avoids unit rounding drift.
    private let exerciseNameSnapshot: String
    private let setNumberSnapshot: Int
    private let rawTranscriptSnapshot: String
    private let initialWeightText: String
    private let initialWeightKg: Double?

    @State private var weightValue: Double
    @State private var weightText: String
    @State private var hasReps: Bool
    @State private var reps: Int
    @State private var durationText: String
    @State private var tag: SetTag
    @State private var notes: String

    init(set: LoggedSet, store: WorkoutStore) {
        self.set = set
        self.store = store
        self.exerciseNameSnapshot = set.entry?.exerciseName ?? "Edit Set"
        self.setNumberSnapshot = set.setNumber
        self.rawTranscriptSnapshot = set.rawTranscript
        self.initialWeightKg = set.weightKg

        let convertedWeight = set.weightKg.map { store.preferredUnit.fromKg($0) } ?? 0
        let roundedWeight = (convertedWeight * 10).rounded() / 10
        let formattedInitial = roundedWeight > 0 ? Self.formatNumeric(roundedWeight) : ""
        self.initialWeightText = formattedInitial

        _weightValue = State(initialValue: roundedWeight)
        _weightText = State(initialValue: formattedInitial)
        _hasReps = State(initialValue: set.reps != nil || set.durationSeconds == nil)
        _reps = State(initialValue: max(1, set.reps ?? 10))
        _durationText = State(initialValue: set.durationSeconds.map { "\($0)" } ?? "")
        _tag = State(initialValue: set.tag)
        _notes = State(initialValue: set.notes)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    weightCard
                    repsAndDurationCard
                    tagCard
                    notesCard
                    deleteButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            bottomSaveBar
        }
        .background(BuddyTheme.canvasBackground.ignoresSafeArea())
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exerciseNameSnapshot)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text("Set #\(setNumberSnapshot)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(BuddyTheme.mutedText)
            }

            Spacer()

            Button {
                BuddyHaptics.lightImpact()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(BuddyTheme.elevatedSurface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Weight Card

    private var weightCard: some View {
        let deltas: [Double] = store.preferredUnit == .kg ? [-5, -2.5, 2.5, 5] : [-10, -5, 5, 10]

        return NativeCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("WEIGHT (\(store.preferredUnit.label.uppercased()))")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(BuddyTheme.mutedText)

                HStack {
                    TextField("Bodyweight", text: $weightText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 24, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                        .onChange(of: weightText) { _, newValue in
                            let cleaned = newValue
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: ",", with: ".")
                            if let parsed = Double(cleaned) {
                                weightValue = max(0, parsed)
                            } else if cleaned.isEmpty {
                                weightValue = 0
                            }
                        }

                    if !weightText.isEmpty {
                        Button {
                            BuddyHaptics.lightImpact()
                            weightValue = 0
                            weightText = ""
                        } label: {
                            Text("BW")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(BuddyTheme.mutedText)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(BuddyTheme.chipSurface))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(BuddyTheme.elevatedSurface)
                )

                HStack(spacing: 8) {
                    ForEach(deltas, id: \.self) { delta in
                        Button {
                            adjustWeight(by: delta)
                        } label: {
                            Text(delta > 0 ? "+\(Self.formatNumeric(delta))" : Self.formatNumeric(delta))
                                .font(.system(size: 13.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(delta > 0 ? BuddyTheme.inkInverse : Color.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(delta > 0 ? BuddyTheme.inkPrimary : BuddyTheme.chipSurface)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Reps & Duration Card

    private var repsAndDurationCard: some View {
        NativeCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text("REPS & DURATION")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(BuddyTheme.mutedText)

                HStack {
                    Text("Track Reps")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Toggle("", isOn: $hasReps)
                        .labelsHidden()
                        .tint(BuddyTheme.emeraldLive)
                }

                if hasReps {
                    HStack {
                        Text("Reps")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(BuddyTheme.mutedText)

                        Spacer()

                        HStack(spacing: 12) {
                            Button {
                                if reps > 1 {
                                    BuddyHaptics.lightImpact()
                                    reps -= 1
                                }
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(reps > 1 ? Color.primary : BuddyTheme.mutedText)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(BuddyTheme.elevatedSurface))
                            }
                            .buttonStyle(.plain)

                            Text("\(reps)")
                                .font(.system(size: 18, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.primary)
                                .frame(minWidth: 34)

                            Button {
                                if reps < 200 {
                                    BuddyHaptics.lightImpact()
                                    reps += 1
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(reps < 200 ? BuddyTheme.inkInverse : BuddyTheme.mutedText)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(reps < 200 ? BuddyTheme.inkPrimary : BuddyTheme.elevatedSurface))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().overlay(BuddyTheme.hairlineBorder)

                HStack {
                    Text("Duration (seconds)")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    TextField("Optional", text: $durationText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 16, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                        .frame(width: 96)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(BuddyTheme.elevatedSurface)
                        )
                }
            }
        }
    }

    // MARK: - Tag Card

    private var tagCard: some View {
        NativeCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("SET TAG")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(BuddyTheme.mutedText)

                HStack(spacing: 8) {
                    ForEach(SetTag.allCases) { option in
                        let selected = (tag == option)
                        Button {
                            BuddyHaptics.selection()
                            tag = option
                        } label: {
                            Text(option.displayLabel)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(selected ? BuddyTheme.inkInverse : Color.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(selected ? BuddyTheme.inkPrimary : BuddyTheme.chipSurface)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Notes Card

    private var notesCard: some View {
        NativeCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("NOTES")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(BuddyTheme.mutedText)

                TextField("Form cues, RPE, Tempo…", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                    )

                if !rawTranscriptSnapshot.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                            .padding(.top, 2)
                        Text("“\(rawTranscriptSnapshot)”")
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                }
            }
        }
    }

    // MARK: - Delete Button

    private var deleteButton: some View {
        Button {
            BuddyHaptics.warning()
            store.deleteSet(set)
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Delete Set")
                    .font(.system(size: 14.5, weight: .semibold))
            }
            .foregroundStyle(BuddyTheme.destructive)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(BuddyTheme.destructive.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Save Bar

    private var bottomSaveBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(BuddyTheme.hairlineBorder)

            Button {
                saveChanges()
            } label: {
                Text("Save Changes")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(BuddyTheme.inkInverse)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(BuddyTheme.inkPrimary))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(BuddyTheme.canvasBackground)
    }

    // MARK: - Actions

    private func adjustWeight(by delta: Double) {
        BuddyHaptics.lightImpact()
        let updated = max(0, ((weightValue + delta) * 10).rounded() / 10)
        weightValue = updated
        weightText = updated > 0 ? Self.formatNumeric(updated) : ""
    }

    private func saveChanges() {
        let cleanedWeight = weightText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        let finalWeightKg: Double?
        if cleanedWeight == initialWeightText {
            finalWeightKg = initialWeightKg
        } else {
            let parsedWeight = Double(cleanedWeight)
            finalWeightKg = parsedWeight.flatMap { $0 > 0 ? store.preferredUnit.toKg($0) : nil }
        }

        let cleanedDuration = durationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDuration = Int(cleanedDuration).flatMap { $0 > 0 ? $0 : nil }
        let finalReps: Int? = hasReps ? reps : nil

        store.updateSet(
            set,
            reps: finalReps,
            weightKg: finalWeightKg,
            durationSeconds: finalDuration,
            tag: tag,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        BuddyHaptics.success()
        dismiss()
    }

    private static func formatNumeric(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }
}
