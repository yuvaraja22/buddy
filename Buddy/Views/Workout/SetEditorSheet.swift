import SwiftUI

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
        NavigationStack {
            Form {
                weightSection
                repsAndDurationSection
                tagSection
                notesSection
                deleteSection
            }
            .navigationTitle(exerciseNameSnapshot)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Sections

    private var weightSection: some View {
        let deltas: [Double] = store.preferredUnit == .kg ? [-5, -2.5, 2.5, 5] : [-10, -5, 5, 10]

        return Section {
            HStack {
                Text("Weight (\(store.preferredUnit.label))")
                Spacer()
                TextField("Bodyweight", text: $weightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(BuddyTheme.cobalt)
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
            }

            HStack(spacing: 8) {
                ForEach(deltas, id: \.self) { delta in
                    Button {
                        adjustWeight(by: delta)
                    } label: {
                        Text(delta > 0 ? "+\(Self.formatNumeric(delta))" : Self.formatNumeric(delta))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(delta > 0 ? BuddyTheme.cobalt : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(delta > 0 ? BuddyTheme.cobaltSoft : BuddyTheme.elevatedSurface)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Set \(setNumberSnapshot) · Load")
        }
    }

    private var repsAndDurationSection: some View {
        Section("Reps & Duration") {
            Toggle("Track Reps", isOn: $hasReps)

            if hasReps {
                Stepper(value: $reps, in: 1...300) {
                    HStack {
                        Text("Reps")
                        Spacer()
                        Text("\(reps)")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(BuddyTheme.cobalt)
                    }
                }
            }

            HStack {
                Text("Duration (seconds)")
                Spacer()
                TextField("None", text: $durationText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .buddyNumeric()
            }

            HStack(spacing: 8) {
                ForEach([30, 45, 60, 90], id: \.self) { seconds in
                    Button {
                        BuddyHaptics.selection()
                        durationText = "\(seconds)"
                    } label: {
                        Text("\(seconds)s")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(durationText == "\(seconds)" ? .white : BuddyTheme.cobalt)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(durationText == "\(seconds)" ? BuddyTheme.cobalt : BuddyTheme.cobaltSoft)
                            )
                    }
                    .buttonStyle(.plain)
                }

                if !durationText.isEmpty {
                    Button {
                        BuddyHaptics.selection()
                        durationText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var tagSection: some View {
        Section("Set Type") {
            Picker("Set Type", selection: $tag) {
                ForEach(SetTag.allCases) { item in
                    Text(item.displayLabel).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var notesSection: some View {
        Section {
            TextField("Form cues, tempo, RPE…", text: $notes, axis: .vertical)
                .lineLimit(2...4)
        } header: {
            Text("Notes")
        } footer: {
            if !rawTranscriptSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Voice transcript: “\(rawTranscriptSnapshot)”")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                BuddyHaptics.warning()
                dismiss()
                let targetSet = set
                Task { @MainActor in
                    store.deleteSet(targetSet)
                }
            } label: {
                HStack {
                    Spacer()
                    Label("Delete Set", systemImage: "trash")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Actions

    private func adjustWeight(by delta: Double) {
        BuddyHaptics.selection()
        let next = max(0, ((weightValue + delta) * 10).rounded() / 10)
        weightValue = next
        weightText = next > 0 ? Self.formatNumeric(next) : ""
    }

    private func saveChanges() {
        let trimmedWeightText = weightText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWeightKg: Double?
        if trimmedWeightText == initialWeightText {
            // Preserve exact underlying kg value when the user didn't edit weight.
            resolvedWeightKg = initialWeightKg
        } else {
            let parsedWeight = Double(trimmedWeightText.replacingOccurrences(of: ",", with: "."))
            resolvedWeightKg = parsedWeight.flatMap { $0 > 0 ? store.preferredUnit.toKg($0) : nil }
        }

        let resolvedReps: Int? = hasReps ? max(1, reps) : nil
        let resolvedDuration: Int? = Int(durationText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }

        store.updateSet(
            set,
            reps: resolvedReps,
            weightKg: resolvedWeightKg,
            durationSeconds: resolvedDuration,
            tag: tag,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        BuddyHaptics.success()
        dismiss()
    }

    private static func formatNumeric(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }
}
