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
    @State private var coachError: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var showClearConfirmation: Bool = false
    @FocusState private var isInputFocused: Bool

    private let starterPrompts: [String] = [
        "Review today's session",
        "How's my consistency this month?",
        "What weight should I aim for next?",
        "Summarize my recent leg days"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                offlineStatusBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

                if !modelManager.isLLMDownloaded {
                    llmSetupPromptView
                } else {
                    chatScrollArea
                }
            }
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            BuddyHaptics.lightImpact()
                            showClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline.weight(.medium))
                        }
                        .disabled(llmService.isGenerating)
                        .accessibilityLabel("Clear conversation")
                    }
                }
            }
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
                if llmService.isGenerating {
                    stopGenerating()
                }
            }
        }
    }

    // MARK: - Top Offline Status Banner

    private var offlineStatusBanner: some View {
        let count = store.sessions.count
        let workoutWord = count == 1 ? "workout" : "workouts"
        let modelLabel = modelManager.selectedLLMPreset == .custom
            ? (modelManager.customLLMFileName ?? "Custom GGUF")
            : modelManager.selectedLLMPreset.displayName

        return HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(modelManager.isLLMDownloaded ? BuddyTheme.emeraldLive : BuddyTheme.cobalt)

            Text("100% Offline · \(modelLabel) · Grounded in \(count) \(workoutWord)")
                .font(.caption.weight(.medium))
                .buddyNumeric()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.75)
        }
    }

    // MARK: - Model Missing Prompt

    private var llmSetupPromptView: some View {
        ScrollView {
            VStack(spacing: 16) {
                NativeCard(padding: 20, cornerRadius: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(BuddyTheme.cobaltSoft)
                                .frame(width: 48, height: 48)
                            Image(systemName: "sparkles")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(BuddyTheme.cobalt)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your Offline Gym Coach")
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                            Text("Download Qwen 2.5 once over Wi-Fi to chat with an on-device strength coach grounded directly in your workouts, streaks, and progression — completely offline.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
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
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(BuddyTheme.cobalt)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    // MARK: - Chat Stream & Starter Prompts

    private var chatScrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty && !llmService.isGenerating && streamingReply.isEmpty {
                        starterPromptsSection
                            .padding(.top, 8)
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

                        if llmService.isGenerating || !streamingReply.isEmpty {
                            CoachBubbleView(
                                role: .assistant,
                                content: streamingReply.isEmpty ? "Thinking locally…" : streamingReply,
                                timestamp: Date(),
                                isStreaming: llmService.isGenerating
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
                scrollToBottom(proxy)
            }
            .onChange(of: streamingReply.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: llmService.isGenerating) { _, isGenerating in
                if isGenerating {
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private var starterPromptsSection: some View {
        NativeCard(padding: 18, cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(BuddyTheme.cobaltSoft)
                            .frame(width: 38, height: 38)
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(BuddyTheme.cobalt)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask Buddy Coach")
                            .font(.headline)
                        Text("Powered locally on your iPhone using your logged history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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
                                    .foregroundStyle(BuddyTheme.cobalt)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )
                        }
                        .buttonStyle(.plain)
                    }
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
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BuddyTheme.destructive.opacity(0.3), lineWidth: 0.85)
        }
    }

    // MARK: - Bottom Input Bar

    private var coachInputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about sessions, overload, form…", text: $inputText, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(.vertical, 8)
                .padding(.leading, 6)
                .submitLabel(.send)
                .onSubmit {
                    if !llmService.isGenerating {
                        sendMessage(inputText)
                    }
                }

            if llmService.isGenerating {
                Button {
                    BuddyHaptics.lightImpact()
                    stopGenerating()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(BuddyTheme.destructive)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop response")
            } else {
                let canSend = !trimmedInput.isEmpty && !llmService.isLoading
                Button {
                    BuddyHaptics.lightImpact()
                    sendMessage(inputText)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? BuddyTheme.cobalt : Color.secondary.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(BuddyTheme.glassBorder, lineWidth: 0.85)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - Actions

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendMessage(_ rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !llmService.isGenerating else { return }

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

        let workoutContext = StatsCalculator.buildCoachContext(
            sessions: store.sessions,
            preferredUnit: store.preferredUnit
        )

        generationTask?.cancel()
        generationTask = Task { @MainActor in
            do {
                let reply = try await llmService.streamCoachReply(
                    userMessage: trimmed,
                    workoutContext: workoutContext,
                    history: priorHistory
                ) { delta in
                    streamingReply.append(delta)
                }

                let resolvedReply = reply.isEmpty
                    ? streamingReply.trimmingCharacters(in: .whitespacesAndNewlines)
                    : reply

                if !resolvedReply.isEmpty {
                    let assistantRecord = CoachMessage(role: .assistant, content: resolvedReply)
                    modelContext.insert(assistantRecord)
                    try? modelContext.save()
                }
                streamingReply = ""
            } catch is CancellationError {
                persistPartialStreamIfNeeded()
            } catch {
                persistPartialStreamIfNeeded()
                coachError = error.localizedDescription
                BuddyHaptics.error()
            }
        }
    }

    private func stopGenerating() {
        llmService.stopGeneration()
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
        stopGenerating()
        for message in messages {
            modelContext.delete(message)
        }
        try? modelContext.save()
        coachError = nil
        streamingReply = ""
        BuddyHaptics.lightImpact()
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("coach-bottom-anchor", anchor: .bottom)
        }
    }
}

// MARK: - Chat Bubble View

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
                Spacer(minLength: 32)
            }
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(content)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [BuddyTheme.cobalt, BuddyTheme.cobaltDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(BuddyTheme.cobalt)
                    Text("Buddy Coach")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(BuddyTheme.cobalt)
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(BuddyTheme.cobalt)
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(BuddyTheme.cardSurface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.75)
            }

            if !isStreaming {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }
}
