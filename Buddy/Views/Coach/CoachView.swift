import SwiftUI
import SwiftData

struct CoachView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CoachMessage.createdAt, order: .forward) private var messages: [CoachMessage]

    let store: WorkoutStore
    let llmService: LocalLLMService
    let modelManager: ModelManager
    let onOpenModelSetup: () -> Void

    @State private var inputText: String = ""
    @State private var streamingReply: String = ""
    @State private var isAwaitingCoachReply: Bool = false
    @State private var coachError: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var conversationEpoch: Int = 0
    @State private var lastStreamScrollAt: Date = .distantPast
    @State private var showClearConfirmation: Bool = false
    @FocusState private var isInputFocused: Bool

    private var isCoachStreaming: Bool {
        isAwaitingCoachReply || llmService.isStreamingCoach
    }

    private let starterPrompts: [String] = [
        "Review today's session",
        "How's my consistency this month?",
        "What weight should I aim for next?",
        "Summarize my recent leg days"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                compactHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                offlineStatusBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                if !modelManager.isLLMDownloaded {
                    llmSetupPromptView
                } else {
                    chatScrollArea
                }
            }
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if modelManager.isLLMDownloaded {
                    coachInputBar
                }
            }
            .confirmationDialog(
                "Clear coach chat history?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Chat", role: .destructive) {
                    clearConversation()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onDisappear {
                if isCoachStreaming {
                    stopGenerating()
                }
            }
        }
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        HStack {
            HStack(spacing: 8) {
                Text("Coach")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)

                Text("OFFLINE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(BuddyTheme.mutedText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(BuddyTheme.chipSurface)
                    )
            }

            Spacer()

            if !messages.isEmpty {
                Button {
                    BuddyHaptics.lightImpact()
                    showClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(BuddyTheme.cardSurface))
                        .overlay {
                            Circle().strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .disabled(isCoachStreaming)
                .accessibilityLabel("Clear conversation")
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Top Offline Status Strip

    private var offlineStatusBanner: some View {
        let count = store.sessions.count
        let workoutWord = count == 1 ? "workout" : "workouts"
        let modelLabel = modelManager.selectedLLMPreset == .custom
            ? (modelManager.customLLMFileName ?? "Custom GGUF")
            : modelManager.selectedLLMPreset.displayName

        return HStack(spacing: 8) {
            Circle()
                .fill(modelManager.isLLMDownloaded ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
                .frame(width: 6, height: 6)

            Text("\(modelLabel) · Grounded in \(count) \(workoutWord)")
                .font(.caption.weight(.medium))
                .buddyNumeric()
                .foregroundStyle(BuddyTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.8)
        }
    }

    // MARK: - Model Missing Prompt

    private var llmSetupPromptView: some View {
        ScrollView {
            VStack(spacing: 16) {
                NativeCard(padding: 18, cornerRadius: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(BuddyTheme.elevatedSurface)
                                .frame(width: 44, height: 44)
                            Image(systemName: "sparkles")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your Offline Gym Coach")
                                .font(.system(size: 19, weight: .bold))
                            Text("Download Qwen 2.5 once over Wi-Fi to chat with an on-device strength coach grounded directly in your workouts, streaks, and progression — completely offline.")
                                .font(.subheadline)
                                .foregroundStyle(BuddyTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button {
                            BuddyHaptics.mediumImpact()
                            onOpenModelSetup()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Download Qwen 2.5")
                            }
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(BuddyTheme.inkInverse)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(BuddyTheme.inkPrimary)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, BuddyTheme.floatingBarClearance)
        }
    }

    // MARK: - Chat Stream & Starter Prompts

    private var chatScrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty && !isCoachStreaming && streamingReply.isEmpty {
                        starterPromptsSection
                            .padding(.top, 4)
                    } else {
                        ForEach(messages, id: \.id) { message in
                            CoachBubbleView(
                                role: message.role,
                                content: message.content,
                                timestamp: message.createdAt,
                                isStreaming: false
                            )
                            .id(message.id)
                        }

                        if isCoachStreaming || !streamingReply.isEmpty {
                            CoachBubbleView(
                                role: .assistant,
                                content: streamingReply.isEmpty ? "Thinking locally…" : streamingReply,
                                timestamp: Date(),
                                isStreaming: isCoachStreaming
                            )
                            .id("coach-streaming-anchor")
                        }
                    }

                    if let coachError {
                        errorBanner(coachError)
                            .id("coach-error-anchor")
                    }

                    Color.clear
                        .frame(height: 8)
                        .id("coach-bottom-anchor")
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: streamingReply.count) { _, _ in
                let now = Date()
                if now.timeIntervalSince(lastStreamScrollAt) >= 0.25 {
                    lastStreamScrollAt = now
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: isInputFocused) { _, focused in
                if focused {
                    scrollToBottom(proxy, animated: true)
                }
            }
            .onChange(of: isCoachStreaming) { _, isStreaming in
                if isStreaming {
                    scrollToBottom(proxy, animated: true)
                }
            }
        }
    }

    private var starterPromptsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask Buddy Coach")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                ForEach(starterPrompts, id: \.self) { prompt in
                    Button {
                        BuddyHaptics.lightImpact()
                        sendMessage(prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Text(prompt)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: 4)

                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BuddyTheme.mutedText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(BuddyTheme.cardSurface)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.8)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(BuddyTheme.destructive)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Button {
                coachError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BuddyTheme.mutedText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(BuddyTheme.destructive.opacity(0.4), lineWidth: 0.85)
        }
    }

    // MARK: - Monochrome Composer Bar

    private var coachInputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about sessions, overload, form…", text: $inputText, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(.vertical, 8)
                .padding(.leading, 6)

            if isCoachStreaming {
                Button {
                    BuddyHaptics.lightImpact()
                    stopGenerating()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(BuddyTheme.destructive))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop response")
            } else {
                let canSend = !trimmedInput.isEmpty && !llmService.isLoading
                Button {
                    BuddyHaptics.lightImpact()
                    sendMessage(inputText)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canSend ? BuddyTheme.inkInverse : BuddyTheme.mutedText)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(canSend ? BuddyTheme.inkPrimary : BuddyTheme.chipSurface)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(BuddyTheme.glassBorder, lineWidth: 0.9)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        // Sit snugly above the floating Uber tab bar when browsing, and snugly above the keyboard when typing.
        .padding(.bottom, isInputFocused ? 10 : 84)
        .animation(.snappy(duration: 0.2), value: isInputFocused)
    }

    // MARK: - Actions

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendMessage(_ rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCoachStreaming else { return }

        let priorHistory: [(role: CoachRole, content: String)] = messages
            .suffix(6)
            .map { (role: $0.role, content: $0.content) }

        let userRecord = CoachMessage(role: .user, content: trimmed)
        modelContext.insert(userRecord)
        try? modelContext.save()

        inputText = ""
        isInputFocused = false
        coachError = nil
        streamingReply = ""
        isAwaitingCoachReply = true

        let activeEpoch = conversationEpoch
        let workoutContext = StatsCalculator.buildCoachContext(
            sessions: store.sessions,
            preferredUnit: store.preferredUnit
        )

        generationTask?.cancel()
        generationTask = Task { @MainActor in
            defer {
                if conversationEpoch == activeEpoch {
                    isAwaitingCoachReply = false
                }
            }
            do {
                let reply = try await llmService.streamCoachReply(
                    userMessage: trimmed,
                    workoutContext: workoutContext,
                    history: priorHistory
                ) { delta in
                    guard conversationEpoch == activeEpoch else { return }
                    streamingReply.append(delta)
                }

                guard conversationEpoch == activeEpoch else { return }

                let resolvedReply = reply.isEmpty
                    ? streamingReply.trimmingCharacters(in: .whitespacesAndNewlines)
                    : reply

                if !resolvedReply.isEmpty {
                    let assistantRecord = CoachMessage(role: .assistant, content: resolvedReply)
                    modelContext.insert(assistantRecord)
                    try? modelContext.save()
                } else {
                    coachError = "Coach couldn't generate a response. Please try again."
                }
                streamingReply = ""
            } catch is CancellationError {
                if conversationEpoch == activeEpoch {
                    persistPartialStreamIfNeeded()
                }
            } catch {
                if conversationEpoch == activeEpoch {
                    persistPartialStreamIfNeeded()
                    coachError = error.localizedDescription
                    BuddyHaptics.error()
                }
            }
        }
    }

    private func stopGenerating() {
        isAwaitingCoachReply = false
        llmService.stopCoachGeneration()
        generationTask?.cancel()
        generationTask = nil
    }

    private func persistPartialStreamIfNeeded() {
        let partial = streamingReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty {
            let assistantRecord = CoachMessage(role: .assistant, content: partial)
            modelContext.insert(assistantRecord)
            try? modelContext.save()
        }
        streamingReply = ""
    }

    private func clearConversation() {
        conversationEpoch &+= 1
        stopGenerating()
        for message in messages {
            modelContext.delete(message)
        }
        try? modelContext.save()
        coachError = nil
        streamingReply = ""
        BuddyHaptics.lightImpact()
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("coach-bottom-anchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("coach-bottom-anchor", anchor: .bottom)
        }
    }
}

// MARK: - Monochrome Chat Bubble View

private struct CoachBubbleView: View {
    let role: CoachRole
    let content: String
    let timestamp: Date
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if role == .user {
                Spacer(minLength: 48)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 24)
            }
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(content)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(BuddyTheme.chipSurface)
                )

            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(BuddyTheme.mutedText)
                .padding(.trailing, 4)
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("Buddy Coach")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(BuddyTheme.inkPrimary)
                    }
                }

                Text(content)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(BuddyTheme.cardSurface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.8)
            }

            if !isStreaming {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(BuddyTheme.mutedText)
                    .padding(.leading, 4)
            }
        }
    }
}
