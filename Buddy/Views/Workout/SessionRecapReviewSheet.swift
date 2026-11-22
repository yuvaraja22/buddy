import SwiftUI

// MARK: - Full-Session Voice Recap Listening Sheet

/// Focused OLED monochrome capture sheet launched from Home's "Recap" tile or Calendar's
/// "Voice Log Day" button. Displays scrolling multi-line live captions and supports up to
/// 3 minutes of uninterrupted speech so users can recite their entire finished gym session in one go.
struct VoiceRecapCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss

    let pipeline: VoicePipelineCoordinator
    let store: WorkoutStore
    let targetDate: Date

    private var isRecording: Bool {
        if case .recording = pipeline.phase { return true }
        return false
    }

    private var isProcessing: Bool {
        pipeline.phase == .transcribing || pipeline.phase == .parsing
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workout Recap")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.primary)

                    Text(
                        Calendar.current.isDateInToday(targetDate)
                            ? "Tell Buddy every exercise you did in one go"
                            : "Voice logging for \(targetDate.formatted(date: .abbreviated, time: .omitted))"
                    )
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BuddyTheme.mutedText)
                }

                Spacer()

                Button {
                    BuddyHaptics.lightImpact()
                    pipeline.cancelRecording()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(BuddyTheme.elevatedSurface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel recap recording")
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Live Multi-Line Transcript Card
            NativeCard(padding: 16, cornerRadius: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        if isRecording {
                            PulsingLiveDot(color: BuddyTheme.destructive, size: 7)
                            Text("LISTENING")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(BuddyTheme.destructive)
                        } else if isProcessing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(BuddyTheme.inkPrimary)
                            Text(pipeline.phase == .transcribing ? "FINALIZING SPEECH…" : "PARSING FULL SESSION…")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(Color.primary)
                        } else {
                            Circle()
                                .fill(BuddyTheme.mutedText)
                                .frame(width: 7, height: 7)
                            Text("READY")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(BuddyTheme.mutedText)
                        }

                        Spacer()

                        if isRecording {
                            Text("\(DurationFormatter.formatClock(seconds: Int(pipeline.recordingDuration))) / 03:00")
                                .font(.system(size: 12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(BuddyTheme.mutedText)
                        }
                    }

                    ScrollView {
                        let transcript = pipeline.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if transcript.isEmpty {
                            Text("“Today I did bench press 60 kg 3 sets 10 reps, incline dumbbell press 20 kg 3 sets 12 reps, cable fly 15 kg 3 sets 15 reps, and tricep pushdown 25 kg 3 sets 12 reps.”")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(BuddyTheme.mutedText.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(transcript)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 200)

                    if isRecording {
                        VoiceWaveformStrip(levels: pipeline.audioLevels, barCount: 28)
                            .frame(height: 24)
                    }

                    if case .error(let message) = pipeline.phase {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(BuddyTheme.destructive)
                            Text(message)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(BuddyTheme.destructive)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 16)

            // Bottom Action Bar
            HStack(spacing: 10) {
                if isRecording {
                    Button {
                        BuddyHaptics.lightImpact()
                        pipeline.cancelRecording()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(BuddyTheme.elevatedSurface))
                    }
                    .buttonStyle(.plain)

                    Button {
                        BuddyHaptics.mediumImpact()
                        pipeline.finishRecordingAndProcess(into: store)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                            Text("Finish & Parse")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(BuddyTheme.inkInverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(BuddyTheme.inkPrimary))
                    }
                    .buttonStyle(.plain)
                } else if isProcessing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(BuddyTheme.inkPrimary)
                        Text("Extracting every exercise offline…")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(BuddyTheme.elevatedSurface))
                } else {
                    Button {
                        BuddyHaptics.mediumImpact()
                        pipeline.dismissError()
                        pipeline.beginRecapRecording(for: targetDate)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("Start Speaking")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(BuddyTheme.inkInverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(BuddyTheme.inkPrimary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(BuddyTheme.canvasBackground.ignoresSafeArea())
        .onAppear {
            if pipeline.phase == .idle {
                pipeline.beginRecapRecording(for: targetDate)
            }
        }
        .onChange(of: pipeline.pendingRecap?.id) { _, newID in
            if newID != nil {
                dismiss()
            }
        }
    }
}

// MARK: - Editable Draft Item Model

private struct EditableRecapItem: Identifiable, Equatable {
    let id: UUID = UUID()
    var exerciseName: String
    var setCount: Int
    var reps: Int?
    var weightText: String
    var weightUnit: WeightUnit
    var durationSeconds: Int?
    var tag: SetTag
    var note: String

    init(from parsed: ParsedSetGroupIntent, defaultUnit: WeightUnit) {
        let resolved = ExerciseCatalog.resolve(parsed.exerciseName)
        let unit = parsed.weightUnit ?? defaultUnit
        self.exerciseName = resolved.displayName
        self.setCount = max(1, parsed.setCount)
        self.reps = parsed.reps
        if let val = parsed.weightValue, val > 0 {
            let rounded = (val * 10).rounded() / 10
            self.weightText = rounded.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(rounded))"
                : String(format: "%.1f", rounded)
        } else {
            self.weightText = ""
        }
        self.weightUnit = unit
        self.durationSeconds = parsed.durationSeconds
        self.tag = parsed.tag
        self.note = parsed.note
    }

    init(defaultUnit: WeightUnit) {
        self.exerciseName = ""
        self.setCount = 3
        self.reps = 10
        self.weightText = ""
        self.weightUnit = defaultUnit
        self.durationSeconds = nil
        self.tag = .normal
        self.note = ""
    }

    func toParsedIntent() -> ParsedSetGroupIntent? {
        let trimmed = exerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleanedWeight = weightText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let parsedWeight = Double(cleanedWeight).flatMap { $0 > 0 ? $0 : nil }
        return ParsedSetGroupIntent(
            exerciseName: trimmed,
            setCount: max(1, setCount),
            reps: reps,
            weightValue: parsedWeight,
            weightUnit: parsedWeight != nil ? weightUnit : nil,
            durationSeconds: durationSeconds,
            tag: tag,
            note: note
        )
    }
}

// MARK: - Monochrome Review & Confirm Sheet

/// Presented after a full-session voice recap (or whenever 2+ exercises are parsed in one go).
/// Lets the user verify/edit every parsed exercise, adjust the date (Today or any past day),
/// optionally re-parse the raw transcript, and tap "Save & Finish Workout" or "Add to Active Session".
struct SessionRecapReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let recap: PendingSessionRecap
    let store: WorkoutStore
    let pipeline: VoicePipelineCoordinator
    let onComplete: () -> Void

    @State private var draftItems: [EditableRecapItem]
    @State private var selectedDate: Date
    @State private var sessionTitle: String
    @State private var transcriptText: String
    @State private var showTranscriptEditor: Bool = false
    @State private var isReparsing: Bool = false
    @State private var reparseError: String?

    private let splitQuickTitles: [String] = ["Push Day", "Pull Day", "Leg Day", "Upper Body", "Full Body", "Cardio"]

    init(
        recap: PendingSessionRecap,
        store: WorkoutStore,
        pipeline: VoicePipelineCoordinator,
        onComplete: @escaping () -> Void
    ) {
        self.recap = recap
        self.store = store
        self.pipeline = pipeline
        self.onComplete = onComplete
        _draftItems = State(initialValue: recap.items.map {
            EditableRecapItem(from: $0, defaultUnit: store.preferredUnit)
        })
        _selectedDate = State(initialValue: recap.targetDate)
        _sessionTitle = State(initialValue: recap.suggestedTitle)
        _transcriptText = State(initialValue: recap.rawTranscript)
    }

    private var validIntents: [ParsedSetGroupIntent] {
        draftItems.compactMap { $0.toParsedIntent() }
    }

    private var totalSetCount: Int {
        validIntents.reduce(0) { $0 + $1.setCount }
    }

    private var distinctExerciseCount: Int {
        Set(validIntents.map { ExerciseCatalog.resolve($0.exerciseName).canonicalName.lowercased() }).count
    }

    private var isTodaySelected: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sessionMetaCard
                    exercisesSection
                    transcriptCard
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review Session")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.primary)

                HStack(spacing: 6) {
                    Text("\(distinctExerciseCount) \(distinctExerciseCount == 1 ? "exercise" : "exercises") · \(totalSetCount) \(totalSetCount == 1 ? "set" : "sets")")
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(BuddyTheme.mutedText)

                    Text("·")
                        .foregroundStyle(BuddyTheme.mutedText)

                    Text(recap.parserSource.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BuddyTheme.mutedText)
                }
            }

            Spacer()

            Button {
                BuddyHaptics.lightImpact()
                onComplete()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(BuddyTheme.elevatedSurface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard recap")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Date & Title Card

    private var sessionMetaCard: some View {
        NativeCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("WORKOUT DETAILS")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(BuddyTheme.mutedText)

                // Title input
                TextField("Workout title", text: $sessionTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                    )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(splitQuickTitles, id: \.self) { split in
                            let selected = sessionTitle.caseInsensitiveCompare(split) == .orderedSame
                            Button {
                                BuddyHaptics.selection()
                                sessionTitle = split
                            } label: {
                                Text(split)
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

                Divider().overlay(BuddyTheme.hairlineBorder)

                // Date selector row
                HStack(spacing: 8) {
                    let isYesterday = Calendar.current.isDateInYesterday(selectedDate)

                    quickDateChip(title: "Today", isSelected: isTodaySelected) {
                        selectedDate = Date()
                    }

                    quickDateChip(title: "Yesterday", isSelected: isYesterday) {
                        if let yday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) {
                            selectedDate = yday
                        }
                    }

                    Spacer(minLength: 4)

                    DatePicker(
                        "",
                        selection: $selectedDate,
                        in: ...Date(),
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(BuddyTheme.inkPrimary)
                }
            }
        }
    }

    private func quickDateChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            BuddyHaptics.selection()
            action()
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isSelected ? BuddyTheme.inkInverse : Color.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? BuddyTheme.inkPrimary : BuddyTheme.chipSurface)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Parsed Exercises Section

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Parsed Exercises")
                    .font(BuddyTheme.sectionTitleFont)
                    .foregroundStyle(Color.primary)

                Spacer()

                Button {
                    BuddyHaptics.lightImpact()
                    draftItems.append(EditableRecapItem(defaultUnit: store.preferredUnit))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(BuddyTheme.elevatedSurface))
                }
                .buttonStyle(.plain)
            }

            if draftItems.isEmpty {
                NativeCard(padding: 16, cornerRadius: 14) {
                    Text("No exercises yet. Tap + Add or edit the transcript below and tap Re-parse.")
                        .font(.subheadline)
                        .foregroundStyle(BuddyTheme.mutedText)
                }
            } else {
                ForEach($draftItems) { $item in
                    recapItemCard($item)
                }
            }
        }
    }

    private func recapItemCard(_ item: Binding<EditableRecapItem>) -> some View {
        let resolved = ExerciseCatalog.resolve(item.wrappedValue.exerciseName)

        return NativeCard(padding: 12, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    WorkoutThumbnailView(
                        assetName: resolved.muscleGroup.thumbnailAssetName,
                        bottomRightBadge: "\(item.wrappedValue.setCount)×",
                        width: 68,
                        height: 40
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Exercise name", text: item.exerciseName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.primary)

                        Text(resolved.muscleGroup.rawValue)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(BuddyTheme.mutedText)
                    }

                    Spacer(minLength: 4)

                    Button {
                        BuddyHaptics.warning()
                        draftItems.removeAll(where: { $0.id == item.wrappedValue.id })
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(BuddyTheme.mutedText)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(BuddyTheme.elevatedSurface))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove exercise")
                }

                // Inline compact metrics row: Sets stepper | Reps stepper | Weight input
                HStack(spacing: 8) {
                    compactStepperBox(
                        label: "SETS",
                        value: item.setCount,
                        range: 1...20
                    )

                    if let currentReps = item.wrappedValue.reps {
                        compactStepperBox(
                            label: "REPS",
                            value: Binding(
                                get: { currentReps },
                                set: { item.wrappedValue.reps = $0 }
                            ),
                            range: 1...200
                        )
                    } else if let dur = item.wrappedValue.durationSeconds {
                        compactDurationBox(
                            seconds: Binding(
                                get: { dur },
                                set: { item.wrappedValue.durationSeconds = max(5, $0) }
                            )
                        )
                    } else {
                        Button {
                            BuddyHaptics.lightImpact()
                            item.wrappedValue.reps = 10
                        } label: {
                            VStack(spacing: 2) {
                                Text("REPS")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(BuddyTheme.mutedText)
                                Text("+ Add")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("WT (\(item.wrappedValue.weightUnit.label.uppercased()))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(BuddyTheme.mutedText)

                        TextField("BW", text: item.weightText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 14, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 82)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                    )
                }

                if item.wrappedValue.tag != .normal {
                    HStack(spacing: 6) {
                        StatusPill(
                            text: item.wrappedValue.tag.displayLabel,
                            tint: BuddyTheme.tagTint(for: item.wrappedValue.tag)
                        )
                        Button("Clear tag") {
                            item.wrappedValue.tag = .normal
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(BuddyTheme.mutedText)
                    }
                }
            }
        }
    }

    private func compactStepperBox(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(BuddyTheme.mutedText)

            HStack(spacing: 8) {
                Button {
                    if value.wrappedValue > range.lowerBound {
                        BuddyHaptics.lightImpact()
                        value.wrappedValue -= 1
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(BuddyTheme.chipSurface))
                }
                .buttonStyle(.plain)

                Text("\(value.wrappedValue)")
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                    .frame(minWidth: 20)

                Button {
                    if value.wrappedValue < range.upperBound {
                        BuddyHaptics.lightImpact()
                        value.wrappedValue += 1
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(BuddyTheme.inkInverse)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(BuddyTheme.inkPrimary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(BuddyTheme.elevatedSurface)
        )
    }

    private func compactDurationBox(seconds: Binding<Int>) -> some View {
        VStack(spacing: 3) {
            Text("TIME")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(BuddyTheme.mutedText)

            HStack(spacing: 6) {
                Button {
                    BuddyHaptics.lightImpact()
                    seconds.wrappedValue = max(5, seconds.wrappedValue - 15)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(BuddyTheme.chipSurface))
                }
                .buttonStyle(.plain)

                Text(DurationFormatter.formatCompact(seconds: seconds.wrappedValue))
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Button {
                    BuddyHaptics.lightImpact()
                    seconds.wrappedValue += 15
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(BuddyTheme.inkInverse)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(BuddyTheme.inkPrimary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(BuddyTheme.elevatedSurface)
        )
    }

    // MARK: - Editable Raw Transcript Disclosure

    private var transcriptCard: some View {
        NativeCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    BuddyHaptics.lightImpact()
                    withAnimation(.snappy(duration: 0.22)) {
                        showTranscriptEditor.toggle()
                    }
                } label: {
                    HStack {
                        Label("Spoken Transcript", systemImage: "waveform")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: showTranscriptEditor ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                }
                .buttonStyle(.plain)

                if showTranscriptEditor {
                    TextEditor(text: $transcriptText)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(Color.primary)
                        .frame(minHeight: 74)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(BuddyTheme.elevatedSurface)
                        )

                    if let reparseError {
                        Text(reparseError)
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.destructive)
                    }

                    Button {
                        reparseEditedTranscript()
                    } label: {
                        HStack(spacing: 6) {
                            if isReparsing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Color.primary)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            Text(isReparsing ? "Re-parsing…" : "Re-parse Transcript")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(BuddyTheme.chipSurface))
                    }
                    .buttonStyle(.plain)
                    .disabled(isReparsing || transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if !transcriptText.isEmpty {
                    Text("“\(transcriptText)”")
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.mutedText)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Bottom Save Bar

    private var bottomSaveBar: some View {
        let canSave = !validIntents.isEmpty

        return VStack(spacing: 8) {
            Divider().overlay(BuddyTheme.hairlineBorder)

            VStack(spacing: 8) {
                Button {
                    saveSession(finishImmediately: true)
                } label: {
                    Text(
                        isTodaySelected
                            ? "Save & Finish Workout"
                            : "Save for \(selectedDate.formatted(.dateTime.month(.abbreviated).day()))"
                    )
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

                if isTodaySelected {
                    Button {
                        saveSession(finishImmediately: false)
                    } label: {
                        Text(store.activeSession != nil ? "Add to Active Workout" : "Keep Active & Continue")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(canSave ? Color.primary : BuddyTheme.mutedText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(BuddyTheme.canvasBackground)
    }

    // MARK: - Actions

    private func saveSession(finishImmediately: Bool) {
        let intents = validIntents
        guard !intents.isEmpty else { return }

        BuddyHaptics.success()
        _ = store.saveReviewedSession(
            items: intents,
            date: selectedDate,
            title: sessionTitle,
            finishImmediately: finishImmediately,
            rawTranscript: transcriptText,
            parserSource: recap.parserSource
        )
        onComplete()
        dismiss()
    }

    private func reparseEditedTranscript() {
        let cleaned = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        isReparsing = true
        reparseError = nil
        Task { @MainActor in
            let intent = await pipeline.reparseRecapTranscript(cleaned, context: store.promptContext())
            isReparsing = false
            if intent.action == .logSets && !intent.items.isEmpty {
                draftItems = intent.items.map {
                    EditableRecapItem(from: $0, defaultUnit: store.preferredUnit)
                }
                if sessionTitle == "Workout" || sessionTitle == recap.suggestedTitle {
                    sessionTitle = intent.suggestedSessionTitle
                }
                BuddyHaptics.success()
            } else {
                reparseError = "Couldn't extract exercises from that phrasing. Try listing exercise, sets, reps, and weight."
                BuddyHaptics.warning()
            }
        }
    }
}
