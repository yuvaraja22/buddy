import SwiftUI

struct VoiceRecordDock: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    let pipeline: VoicePipelineCoordinator
    let store: WorkoutStore

    @GestureState private var isMicPressed: Bool = false
    @State private var pressBeganWhileIdle: Bool = false
    @State private var pressStartTime: Date?
    @State private var holdPromotionTask: Task<Void, Never>?

    @State private var isShowingTextInput: Bool = false
    @State private var typedInput: String = ""
    @FocusState private var isTextInputFocused: Bool

    private let holdThresholdNanoseconds: UInt64 = 350_000_000

    var body: some View {
        VStack(spacing: 8) {
            if case .error(let message) = pipeline.phase {
                errorPill(message: message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Group {
                if isShowingTextInput && isIdleOrError {
                    textInputBar
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    mainVoiceBar
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(dockBorderColor, lineWidth: isRecording ? 1.25 : 0.85)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.12),
                radius: 18,
                x: 0,
                y: 8
            )
        }
        .animation(.snappy(duration: 0.24), value: phaseAnimationKey)
        .animation(.snappy(duration: 0.22), value: isShowingTextInput)
        .onChange(of: isMicPressed) { wasPressed, nowPressed in
            if !wasPressed && nowPressed {
                handleTouchDown()
            } else if wasPressed && !nowPressed {
                handleTouchUp()
            }
        }
        .onChange(of: pipeline.phase) { _, newPhase in
            if case .recording = newPhase {
                isShowingTextInput = false
                isTextInputFocused = false
            }
        }
        .onDisappear {
            holdPromotionTask?.cancel()
            holdPromotionTask = nil
        }
    }

    // MARK: - Main Floating Voice Bar

    private var mainVoiceBar: some View {
        HStack(spacing: 12) {
            leadingControl

            centerStatusArea
                .frame(maxWidth: .infinity, alignment: .leading)

            // Kept as a single persistent view across idle -> recording -> hold transitions
            // so the active DragGesture is never invalidated mid-hold.
            dualModeMicButton
        }
    }

    @ViewBuilder
    private var leadingControl: some View {
        switch pipeline.phase {
        case .recording:
            Button {
                cancelCurrentRecording()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(BuddyTheme.elevatedSurface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

        case .transcribing, .parsing:
            ProgressView()
                .controlSize(.regular)
                .tint(BuddyTheme.cobalt)
                .frame(width: 42, height: 42)
                .background(Circle().fill(BuddyTheme.cobaltSoft))

        case .idle, .error:
            Button {
                BuddyHaptics.lightImpact()
                if case .error = pipeline.phase {
                    pipeline.dismissError()
                }
                isShowingTextInput = true
                isTextInputFocused = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(BuddyTheme.elevatedSurface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Type workout command")
        }
    }

    @ViewBuilder
    private var centerStatusArea: some View {
        switch pipeline.phase {
        case .idle, .error:
            VStack(alignment: .leading, spacing: 2) {
                Text("Log Set")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Tap or hold to log set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        case .recording(let isHoldMode):
            let streamingText = pipeline.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: streamingText.isEmpty ? 6 : 4) {
                if !streamingText.isEmpty {
                    Text("“\(streamingText)”")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                VoiceWaveformStrip(levels: pipeline.audioLevels, barCount: 28)
                    .frame(height: streamingText.isEmpty ? 24 : 16)

                HStack(spacing: 6) {
                    PulsingLiveDot(color: isHoldMode ? BuddyTheme.cobalt : BuddyTheme.destructive, size: 6)

                    Text(DurationFormatter.formatClock(seconds: Int(pipeline.recordingDuration)))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(isHoldMode ? "Hold — release to log" : "Listening — tap to finish")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

        case .transcribing:
            processingStatusView(
                stageTitle: pipeline.transcribingStageTitle,
                transcript: pipeline.liveTranscript
            )

        case .parsing:
            processingStatusView(
                stageTitle: pipeline.parsingStageTitle,
                transcript: pipeline.liveTranscript
            )
        }
    }

    private func processingStatusView(stageTitle: String, transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stageTitle)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(BuddyTheme.cobalt)
                .lineLimit(1)

            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("“\(transcript)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Processing 100% offline on iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Dual-Mode Tap / Press-and-Hold Mic Button

    private var dualModeMicButton: some View {
        let isProcessing = isTranscribingOrParsing

        return ZStack {
            if isRecording {
                Circle()
                    .fill(activeButtonColor.opacity(0.22))
                    .frame(width: 62, height: 62)
                    .scaleEffect(isMicPressed ? 1.12 : 1.0)
            }

            Circle()
                .fill(
                    LinearGradient(
                        colors: isProcessing
                            ? [BuddyTheme.cobalt.opacity(0.45), BuddyTheme.cobaltDeep.opacity(0.45)]
                            : [activeButtonColor, activeButtonDeepColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 54, height: 54)
                .shadow(
                    color: activeButtonColor.opacity(isProcessing ? 0.1 : 0.35),
                    radius: isMicPressed ? 12 : 8,
                    x: 0,
                    y: 4
                )

            Image(systemName: micButtonSymbol)
                .font(.system(size: isRecording && !isHoldMode ? 18 : 21, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 58, height: 58)
        .scaleEffect(isMicPressed ? 0.93 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isMicPressed)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isMicPressed) { _, state, _ in
                    state = true
                }
        )
        .allowsHitTesting(!isProcessing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityMicLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            handleAccessibilityActivation()
        }
    }

    private func handleAccessibilityActivation() {
        guard !isTranscribingOrParsing else { return }
        switch pipeline.phase {
        case .idle:
            BuddyHaptics.lightImpact()
            pipeline.beginRecording(isHoldMode: false)
        case .error:
            pipeline.dismissError()
            BuddyHaptics.lightImpact()
            pipeline.beginRecording(isHoldMode: false)
        case .recording:
            BuddyHaptics.mediumImpact()
            pipeline.finishRecordingAndProcess(into: store)
        case .transcribing, .parsing:
            break
        }
    }

    private func handleTouchDown() {
        guard !isTranscribingOrParsing else { return }

        switch pipeline.phase {
        case .idle, .error:
            if case .error = pipeline.phase {
                pipeline.dismissError()
            }
            pressBeganWhileIdle = true
            pressStartTime = Date()
            BuddyHaptics.lightImpact()
            pipeline.beginRecording(isHoldMode: false)

            holdPromotionTask?.cancel()
            holdPromotionTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: holdThresholdNanoseconds)
                guard !Task.isCancelled, isMicPressed else { return }
                if case .recording(let currentlyHold) = pipeline.phase, !currentlyHold {
                    BuddyHaptics.holdLockImpact()
                    pipeline.promoteToHoldMode()
                }
            }

        case .recording:
            // Second tap while already in hands-free tap-toggle recording mode
            pressBeganWhileIdle = false
            pressStartTime = Date()

        case .transcribing, .parsing:
            break
        }
    }

    private func handleTouchUp() {
        let startedAt = pressStartTime
        let beganFromIdle = pressBeganWhileIdle

        pressBeganWhileIdle = false
        pressStartTime = nil
        holdPromotionTask?.cancel()
        holdPromotionTask = nil

        guard case .recording(let currentlyHold) = pipeline.phase else { return }

        // If the gesture ended because iOS interrupted the app (Control Center, Home swipe,
        // incoming alert), cancel instead of submitting truncated audio for background inference.
        if scenePhase != .active {
            cancelCurrentRecording()
            return
        }

        if currentlyHold {
            // Released from hold-to-record -> immediately stop and process.
            BuddyHaptics.mediumImpact()
            pipeline.finishRecordingAndProcess(into: store)
        } else if !beganFromIdle {
            // Second tap in tap-toggle mode -> stop and process.
            BuddyHaptics.mediumImpact()
            pipeline.finishRecordingAndProcess(into: store)
        } else if let startedAt, Date().timeIntervalSince(startedAt) >= 0.35 {
            // Defensive fallback if gesture ended right at the 0.35s boundary before task resumed.
            BuddyHaptics.mediumImpact()
            pipeline.finishRecordingAndProcess(into: store)
        }
        // Otherwise: quick tap (< 0.35s) from idle -> remain in hands-free recording mode!
    }

    private func cancelCurrentRecording() {
        holdPromotionTask?.cancel()
        holdPromotionTask = nil
        pressBeganWhileIdle = false
        pressStartTime = nil
        BuddyHaptics.lightImpact()
        pipeline.cancelRecording()
    }

    // MARK: - Quick Text-to-LLM Input Bar

    private var textInputBar: some View {
        HStack(spacing: 10) {
            Button {
                BuddyHaptics.lightImpact()
                isTextInputFocused = false
                isShowingTextInput = false
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BuddyTheme.cobalt)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(BuddyTheme.cobaltSoft))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch back to voice")

            TextField("e.g. Bench press 60 kg 3 sets 10 reps", text: $typedInput)
                .font(.subheadline)
                .focused($isTextInputFocused)
                .submitLabel(.send)
                .onSubmit {
                    submitTypedCommand()
                }

            Button {
                submitTypedCommand()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(trimmedTypedInput.isEmpty ? Color.secondary.opacity(0.35) : BuddyTheme.cobalt)
                    )
            }
            .buttonStyle(.plain)
            .disabled(trimmedTypedInput.isEmpty)
            .accessibilityLabel("Send workout command")
        }
        .onAppear {
            Task { @MainActor in
                isTextInputFocused = true
            }
        }
    }

    private func submitTypedCommand() {
        let trimmed = trimmedTypedInput
        guard !trimmed.isEmpty else { return }
        BuddyHaptics.mediumImpact()
        typedInput = ""
        isTextInputFocused = false
        isShowingTextInput = false
        pipeline.processTypedInput(trimmed, into: store)
    }

    // MARK: - Inline Error Pill

    private func errorPill(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BuddyTheme.destructive)

            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 4)

            Button {
                pipeline.dismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(BuddyTheme.destructive.opacity(0.32), lineWidth: 0.9)
        }
    }

    // MARK: - Helpers

    private var trimmedTypedInput: String {
        typedInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRecording: Bool {
        if case .recording = pipeline.phase { return true }
        return false
    }

    private var isHoldMode: Bool {
        if case .recording(let hold) = pipeline.phase { return hold }
        return false
    }

    private var isTranscribingOrParsing: Bool {
        switch pipeline.phase {
        case .transcribing, .parsing: return true
        default: return false
        }
    }

    private var isIdleOrError: Bool {
        switch pipeline.phase {
        case .idle, .error: return true
        default: return false
        }
    }

    private var activeButtonColor: Color {
        switch pipeline.phase {
        case .recording(let hold):
            return hold ? BuddyTheme.cobalt : BuddyTheme.destructive
        default:
            return BuddyTheme.cobalt
        }
    }

    private var activeButtonDeepColor: Color {
        switch pipeline.phase {
        case .recording(let hold):
            return hold ? BuddyTheme.cobaltDeep : Color(uiColor: .systemRed).opacity(0.85)
        default:
            return BuddyTheme.cobaltDeep
        }
    }

    private var dockBorderColor: Color {
        if isRecording {
            return activeButtonColor.opacity(0.45)
        }
        return BuddyTheme.glassBorder
    }

    private var micButtonSymbol: String {
        switch pipeline.phase {
        case .recording(let hold):
            return hold ? "waveform" : "stop.fill"
        case .transcribing, .parsing:
            return "sparkles"
        case .idle, .error:
            return "mic.fill"
        }
    }

    private var accessibilityMicLabel: String {
        switch pipeline.phase {
        case .idle, .error:
            return "Tap or hold to record workout set"
        case .recording(let hold):
            return hold ? "Recording in hold mode. Release to log." : "Recording. Tap to finish and log."
        case .transcribing:
            return "Transcribing voice recording"
        case .parsing:
            return "Parsing sets"
        }
    }

    private var phaseAnimationKey: String {
        switch pipeline.phase {
        case .idle: return "idle"
        case .recording(let hold): return hold ? "recording-hold" : "recording-tap"
        case .transcribing: return "transcribing"
        case .parsing: return "parsing"
        case .error(let msg): return "error-\(msg)"
        }
    }
}

// MARK: - Live Cobalt Waveform Strip

private struct VoiceWaveformStrip: View {
    let levels: [Float]
    let barCount: Int

    var body: some View {
        let bars = normalizedBars()
        GeometryReader { proxy in
            let spacing: CGFloat = 2.5
            let totalSpacing = spacing * CGFloat(max(0, barCount - 1))
            let barWidth = max(2.0, (proxy.size.width - totalSpacing) / CGFloat(barCount))
            let maxHeight = max(8.0, proxy.size.height)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let magnitude = bars[index]
                    let barHeight = max(4.0, CGFloat(magnitude) * maxHeight)
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [BuddyTheme.cobalt, BuddyTheme.cobaltDeep.opacity(0.75)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: barHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }

    private func normalizedBars() -> [Float] {
        guard !levels.isEmpty else {
            return Array(repeating: 0.14, count: barCount)
        }
        if levels.count >= barCount {
            let slice = Array(levels.suffix(barCount))
            return slice.map { min(1.0, max(0.12, $0)) }
        }
        let paddingCount = barCount - levels.count
        let leading = Array(repeating: Float(0.12), count: paddingCount)
        return leading + levels.map { min(1.0, max(0.12, $0)) }
    }
}
