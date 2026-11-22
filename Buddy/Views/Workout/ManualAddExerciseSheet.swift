import SwiftUI

/// OLED monochrome sheet for manually adding an exercise to either the active workout
/// or a specific past/current date selected on the Calendar tab.
struct ManualAddExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: WorkoutStore
    var targetDate: Date? = nil

    @State private var exerciseName: String = ""
    @State private var setsCount: Int = 3
    @State private var repsCount: Int = 10
    @State private var includeReps: Bool = true
    @State private var weightText: String = ""
    @State private var durationText: String = ""
    @State private var tag: SetTag = .normal
    @FocusState private var isNameFocused: Bool

    private let quickExerciseSuggestions: [String] = [
        "Bench Press", "Squat", "Deadlift", "Lat Pulldown",
        "Incline Dumbbell Press", "Leg Extension", "Lateral Raise", "Plank"
    ]

    private var canSave: Bool {
        !exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let targetDate, !Calendar.current.isDateInToday(targetDate) {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(BuddyTheme.inkPrimary)
                            Text("Logging for \(targetDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(BuddyTheme.cardSurface)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
                        }
                    }

                    exerciseCard
                    prescriptionCard
                    setTypeCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            bottomActionBar
        }
        .background(BuddyTheme.canvasBackground.ignoresSafeArea())
        .onAppear {
            isNameFocused = true
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            Text("Add Exercise")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.primary)

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
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Exercise Input Card

    private var exerciseCard: some View {
        NativeCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("EXERCISE")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(BuddyTheme.mutedText)

                TextField("e.g. Bench Press, Leg Extension, Plank", text: $exerciseName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .focused($isNameFocused)
                    .autocorrectionDisabled(false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isNameFocused ? BuddyTheme.inkPrimary.opacity(0.45) : BuddyTheme.hairlineBorder,
                                lineWidth: 0.9
                            )
                    }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickExerciseSuggestions, id: \.self) { suggestion in
                            let selected = exerciseName.caseInsensitiveCompare(suggestion) == .orderedSame
                            Button {
                                BuddyHaptics.selection()
                                exerciseName = suggestion
                                if suggestion == "Plank" {
                                    includeReps = false
                                    if durationText.isEmpty { durationText = "60" }
                                }
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(selected ? BuddyTheme.inkInverse : Color.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(selected ? BuddyTheme.inkPrimary : BuddyTheme.chipSurface)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sets / Reps / Weight / Duration Card

    private var prescriptionCard: some View {
        NativeCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text("SETS & LOAD")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(BuddyTheme.mutedText)

                // Sets stepper row
                HStack {
                    Text("Sets")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    monochromeStepper(value: $setsCount, range: 1...20)
                }

                Divider().overlay(BuddyTheme.hairlineBorder)

                // Track reps toggle + stepper
                HStack {
                    Text("Track Reps")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Toggle("", isOn: $includeReps)
                        .labelsHidden()
                        .tint(BuddyTheme.emeraldLive)
                }

                if includeReps {
                    HStack {
                        Text("Reps per set")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(BuddyTheme.mutedText)
                        Spacer()
                        monochromeStepper(value: $repsCount, range: 1...200)
                    }
                }

                Divider().overlay(BuddyTheme.hairlineBorder)

                // Weight & Duration side by side
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WEIGHT (\(store.preferredUnit.label.uppercased()))")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(BuddyTheme.mutedText)

                        TextField("Bodyweight", text: $weightText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 16, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("DURATION (SEC)")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(BuddyTheme.mutedText)

                        TextField("Optional", text: $durationText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 16, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )
                    }
                }
            }
        }
    }

    // MARK: - Set Type Card

    private var setTypeCard: some View {
        NativeCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("SET TYPE")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(BuddyTheme.mutedText)

                HStack(spacing: 8) {
                    ForEach(SetTag.allCases) { item in
                        let selected = (tag == item)
                        Button {
                            BuddyHaptics.selection()
                            tag = item
                        } label: {
                            Text(item.displayLabel)
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

    // MARK: - Bottom Bar

    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(BuddyTheme.hairlineBorder)

            Button {
                saveExercise()
            } label: {
                Text("Add Exercise")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSave ? BuddyTheme.inkInverse : BuddyTheme.mutedText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule(style: .continuous)
                            .fill(canSave ? BuddyTheme.inkPrimary : BuddyTheme.elevatedSurface)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(BuddyTheme.canvasBackground)
    }

    private func monochromeStepper(value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 12) {
            Button {
                if value.wrappedValue > range.lowerBound {
                    BuddyHaptics.lightImpact()
                    value.wrappedValue -= 1
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(value.wrappedValue > range.lowerBound ? Color.primary : BuddyTheme.mutedText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(BuddyTheme.elevatedSurface))
            }
            .buttonStyle(.plain)

            Text("\(value.wrappedValue)")
                .font(.system(size: 17, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .frame(minWidth: 32)

            Button {
                if value.wrappedValue < range.upperBound {
                    BuddyHaptics.lightImpact()
                    value.wrappedValue += 1
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(value.wrappedValue < range.upperBound ? BuddyTheme.inkInverse : BuddyTheme.mutedText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(value.wrappedValue < range.upperBound ? BuddyTheme.inkPrimary : BuddyTheme.elevatedSurface))
            }
            .buttonStyle(.plain)
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
            tag: tag,
            on: targetDate
        )
        BuddyHaptics.success()
        dismiss()
    }
}
