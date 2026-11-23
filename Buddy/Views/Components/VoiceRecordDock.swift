import SwiftUI

/// Uber-inspired floating monochrome bottom capsule combining tab navigation (`Workout | Trends | Coach`)
/// with a persistent thumb-reachable tap/hold Mic FAB that morphs seamlessly into a live-caption
/// recording bar when active — eliminating double-stacked bottom chrome.
struct VoiceRecordDock: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @Binding var selectedTab: BuddyTab
    let pipeline: VoicePipelineCoordinator
    let store: WorkoutStore
    let onVoiceRecordingBegan: () -> Void

    @GestureState private var isMicPressed: Bool = false
    @State private var pressBeganWhileIdle: Bool = false
    @State private var pressStartTime: Date?
    @State private var holdPromotionTask: Task<Void, Never>?

    private let holdThresholdNanoseconds: UInt64 = 350_000_000

    var body: some View {
        VStack(spacing: 8) {
            if case .error(let message) = pipeline.phase {
                errorPill(message: message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                // Left capsule: switches cleanly between Uber-style pill nav tabs and live recording bar
                Group {
                    if isIdleOrError {
                        floatingTabCapsule
                    } else {
                        activeRecordingCapsule
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background {
                    Capsule(style: .continuous)
                        .fill(BuddyTheme.floatingBarSurface)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isRecording ? activeButtonColor.opacity(0.55) : BuddyTheme.glassBorder,
                            lineWidth: isRecording ? 1.25 : 0.9
                        )
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.60 : 0.14),
                    radius: 16,
                    x: 0,
                    y: 6
                )

                // Persistent right-side Mic FAB: never recreated across idle -> recording -> hold
                // so the active DragGesture is never invalidated mid-hold.
                dualModeMicButton
            }
        }
        .animation(.snappy(duration: 0.24), value: phaseAnimationKey)
        .onChange(of: isMicPressed) { wasPressed, nowPressed in
            if !wasPressed && nowPressed {
                handleTouchDown()
            } else if wasPressed && !nowPressed {
                handleTouchUp()
            }
        }
        .onDisappear {
            holdPromotionTask?.cancel()
            holdPromotionTask = nil
        }
    }

    // MARK: - Uber-Style Floating Pill Navigation Bar

    private var floatingTabCapsule: some View {
        HStack(spacing: 2) {
            tabPillItem(
                tab: .workout,
                title: "Home",
                symbol: "house.fill",
                inactiveSymbol: "house"
            )
            tabPillItem(
                tab: .calendar,
                title: "Calendar",
                symbol: "calendar",
                inactiveSymbol: "calendar"
            )
            tabPillItem(
                tab: .trends,
                title: "Trends",
                symbol: "chart.bar.fill",
                inactiveSymbol: "chart.bar"
            )
            tabPillItem(
                tab: .coach,
                title: "Coach",
                symbol: "sparkles",
                inactiveSymbol: "sparkles"
            )
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
    }

    private func tabPillItem(
        tab: BuddyTab,
        title: String,
        symbol: String,
        inactiveSymbol: String
    ) -> some View {
        let isSelected = (selectedTab == tab)

        return Button {
            guard selectedTab != tab else { return }
            BuddyHaptics.selection()
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? symbol : inactiveSymbol)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : BuddyTheme.mutedText)

                Text(title)
                    .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : BuddyTheme.mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(BuddyTheme.elevatedSurface)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Live Recording / Processing Capsule

    private var activeRecordingCapsule: some View {
        HStack(spacing: 10) {
            leadingControl

            centerStatusArea
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
    }

    @ViewBuilder
    private var leadingControl: some View {
        switch pipeline.phase {
        case .recording:
            Button {
                cancelCurrentRecording()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(BuddyTheme.elevatedSurface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

        case .transcribing, .parsing:
            ProgressView()
                .controlSize(.small)
                .tint(BuddyTheme.inkPrimary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(BuddyTheme.elevatedSurface))

        case .idle, .error:
            EmptyView()
        }
    }

    @ViewBuilder
    private var centerStatusArea: some View {
        switch pipeline.phase {
        case .recording(let isHoldMode):
            let streamingText = pipeline.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: streamingText.isEmpty ? 5 : 3) {
                if !streamingText.isEmpty {
                    Text("“\(streamingText)”")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                VoiceWaveformStrip(levels: pipeline.audioLevels, barCount: 24)
                    .frame(height: streamingText.isEmpty ? 20 : 14)

                HStack(spacing: 5) {
                    PulsingLiveDot(
                        color: isHoldMode ? BuddyTheme.inkPrimary : BuddyTheme.destructive,
                        size: 5
                    )

                    Text(DurationFormatter.formatClock(seconds: Int(pipeline.recordingDuration)))
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text("·")
                        .foregroundStyle(BuddyTheme.mutedText)

                    Text(isHoldMode ? "Release to log" : "Tap mic to finish")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(BuddyTheme.mutedText)
                        .lineLimit(1)
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

        case .idle, .error:
            EmptyView()
        }
    }

    private func processingStatusView(stageTitle: String, transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stageTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("“\(transcript)”")
                    .font(.caption)
                    .foregroundStyle(BuddyTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(pipeline.processingModeCaption)
                    .font(.caption2)
                    .foregroundStyle(BuddyTheme.mutedText)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Persistent Monochrome Tap / Press-and-Hold Mic FAB

    private var dualModeMicButton: some View {
        let isProcessing = isTranscribingOrParsing

        return ZStack {
            if isRecording {
                Circle()
                    .fill(activeButtonColor.opacity(0.24))
                    .frame(width: 66, height: 66)
                    .scaleEffect(isMicPressed ? 1.12 : 1.0)
            }

            Circle()
                .fill(isProcessing ? BuddyTheme.elevatedSurface : activeButtonColor)
                .frame(width: 58, height: 58)
                .overlay {
                    if isProcessing {
                        Circle()
                            .strokeBorder(BuddyTheme.glassBorder, lineWidth: 1)
                    }
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.55 : 0.18),
                    radius: isMicPressed ? 14 : 10,
                    x: 0,
                    y: 4
                )

            Image(systemName: micButtonSymbol)
                .font(.system(size: isRecording && !isHoldMode ? 17 : 21, weight: .bold))
                .foregroundStyle(isProcessing ? Color.primary : activeGlyphColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 60, height: 60)
        .scaleEffect(isMicPressed ? 0.92 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isMicPressed)
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
            onVoiceRecordingBegan()
            pipeline.beginRecording(isHoldMode: false)
        case .error:
            pipeline.dismissError()
            BuddyHaptics.lightImpact()
            onVoiceRecordingBegan()
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
            onVoiceRecordingBegan()
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

        if scenePhase != .active {
            cancelCurrentRecording()
            return
        }

        if currentlyHold {
            BuddyHaptics.mediumImpact()
            pipeline.finishRecordingAndProcess(into: store)
        } else if !beganFromIdle {
            BuddyHaptics.mediumImpact()
            pipeline.finishRecordingAndProcess(into: store)
        } else if let startedAt, Date().timeIntervalSince(startedAt) >= 0.35 {
            BuddyHaptics.mediumImpact()
            pipeline.finishRecordingAndProcess(into: store)
        }
    }

    private func cancelCurrentRecording() {
        holdPromotionTask?.cancel()
        holdPromotionTask = nil
        pressBeganWhileIdle = false
        pressStartTime = nil
        BuddyHaptics.lightImpact()
        pipeline.cancelRecording()
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
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(BuddyTheme.mutedText)
                    .padding(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BuddyTheme.floatingBarSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BuddyTheme.destructive.opacity(0.45), lineWidth: 0.9)
        }
    }

    // MARK: - Helpers

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
            return hold ? BuddyTheme.inkPrimary : BuddyTheme.destructive
        default:
            return BuddyTheme.inkPrimary
        }
    }

    private var activeGlyphColor: Color {
        switch pipeline.phase {
        case .recording(let hold):
            return hold ? BuddyTheme.inkInverse : Color.white
        default:
            return BuddyTheme.inkInverse
        }
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
            return "Finalizing speech recognition"
        case .parsing:
            return "Parsing workout sets"
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

// MARK: - Monochrome Waveform Strip

struct VoiceWaveformStrip: View {
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
                    let barHeight = max(3.0, CGFloat(magnitude) * maxHeight)
                    Capsule(style: .continuous)
                        .fill(BuddyTheme.inkPrimary.opacity(0.35 + Double(magnitude) * 0.65))
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
