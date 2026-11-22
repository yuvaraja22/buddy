import SwiftUI

struct ModelSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let modelManager: ModelManager
    let appleSpeechService: AppleSpeechService

    @State private var sceneRefreshTick: Int = 0

    var body: some View {
        let _ = sceneRefreshTick
        let isAppleSpeechReady = appleSpeechService.isReadyForOfflineVoice(for: modelManager.selectedAppleSpeechLocale)
        let isVoiceReady = modelManager.isVoiceReady(appleSpeechReady: isAppleSpeechReady)
        let isAllReady = modelManager.isAllReady(appleSpeechReady: isAppleSpeechReady)

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroHeader(isVoiceReady: isVoiceReady)

                    VStack(spacing: 12) {
                        speechCard

                        modelRowCard(
                            icon: "sparkles",
                            title: LLMPreset.qwen25_1_5B.displayName,
                            subtitle: LLMPreset.qwen25_1_5B.subtitle,
                            sizeText: formatSizeMB(LLMPreset.qwen25_1_5B.approximateSizeMB),
                            isDownloaded: modelManager.isDownloaded(.qwen25_1_5B),
                            isDownloading: modelManager.isDownloadingLLM,
                            progress: modelManager.llmDownloadProgress,
                            onDownload: {
                                Task { await modelManager.downloadLLMModel(.qwen25_1_5B) }
                            }
                        )
                    }

                    if let error = modelManager.downloadError {
                        NativeCard(padding: 12, cornerRadius: 14, tint: BuddyTheme.destructive) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(BuddyTheme.destructive)
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }

                    privacyFootnote
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                bottomActionBar(isVoiceReady: isVoiceReady, isAllReady: isAllReady)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
            .onAppear {
                modelManager.refreshDownloadState()
                appleSpeechService.refreshAuthorizationStatus()
                sceneRefreshTick &+= 1
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    modelManager.refreshDownloadState()
                    appleSpeechService.refreshAuthorizationStatus()
                    sceneRefreshTick &+= 1
                }
            }
        }
    }

    @ViewBuilder
    private var speechCard: some View {
        if modelManager.selectedSpeechEngine == .appleOnDevice {
            let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)
            let availability = appleSpeechService.checkAvailability(for: modelManager.selectedAppleSpeechLocale)
            let ready = !isDenied && availability.isReady
            let statusText = isDenied
                ? "Speech Recognition permission is turned off. Enable it in iOS Settings → Buddy, or switch to WhisperKit in Settings."
                : availability.statusMessage

            NativeCard(padding: 16, cornerRadius: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(ready ? BuddyTheme.emeraldLive.opacity(0.14) : BuddyTheme.amberStreak.opacity(0.14))
                                .frame(width: 42, height: 42)

                            Image(systemName: ready ? "checkmark.circle.fill" : "waveform")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ready ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("Apple On-Device Speech")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Spacer()

                                Text("0 MB")
                                    .font(.caption.weight(.semibold))
                                    .buddyNumeric()
                                    .foregroundStyle(ready ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
                            }

                            Text("Instant live speech-to-text tuned for 105 gym exercises & your accent. WhisperKit Large v3 Turbo is also available in Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(ready ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
                        Text(statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ready ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            let preset = modelManager.selectedWhisperPreset
            modelRowCard(
                icon: "waveform",
                title: preset.displayName,
                subtitle: preset.subtitle,
                sizeText: "~\(preset.approximateSizeMB) MB",
                isDownloaded: modelManager.isDownloaded(preset),
                isDownloading: modelManager.isDownloadingWhisper,
                progress: modelManager.whisperDownloadProgress,
                onDownload: {
                    Task { await modelManager.downloadWhisperModel(preset) }
                }
            )
        }
    }

    private func heroHeader(isVoiceReady: Bool) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [BuddyTheme.cobalt, BuddyTheme.cobaltDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 68, height: 68)
                    .shadow(color: BuddyTheme.cobalt.opacity(0.32), radius: 14, x: 0, y: 6)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("100% Offline AI Pack")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text(
                    isVoiceReady
                        ? "Voice logging works right away with Apple On-Device Speech. Download Qwen 2.5 once over Wi-Fi for your offline Gym Coach and natural-language parsing."
                        : "Set up offline speech in iOS Settings (or switch to WhisperKit in Buddy Settings) and download Qwen 2.5 once over Wi-Fi for your offline Gym Coach."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            StatusPill(
                text: "Private On-Device · Zero Cloud",
                icon: "lock.shield.fill",
                tint: BuddyTheme.emeraldLive
            )
            .padding(.top, 2)
        }
        .padding(.top, 8)
    }

    private func modelRowCard(
        icon: String,
        title: String,
        subtitle: String,
        sizeText: String,
        isDownloaded: Bool,
        isDownloading: Bool,
        progress: Double,
        onDownload: @escaping () -> Void
    ) -> some View {
        NativeCard(padding: 16, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isDownloaded ? BuddyTheme.emeraldLive.opacity(0.14) : BuddyTheme.cobaltSoft)
                            .frame(width: 42, height: 42)

                        Image(systemName: isDownloaded ? "checkmark.circle.fill" : icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isDownloaded ? BuddyTheme.emeraldLive : BuddyTheme.cobalt)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Spacer()

                            Text(sizeText)
                                .font(.caption.weight(.semibold))
                                .buddyNumeric()
                                .foregroundStyle(.secondary)
                        }

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isDownloading {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: min(max(progress, 0), 1))
                            .tint(BuddyTheme.cobalt)

                        HStack {
                            Text("Downloading…")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                                .font(.caption2.weight(.semibold))
                                .buddyNumeric()
                                .foregroundStyle(BuddyTheme.cobalt)
                        }
                    }
                } else if isDownloaded {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.emeraldLive)
                        Text("Ready offline")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BuddyTheme.emeraldLive)
                    }
                } else {
                    HStack {
                        Text("Not downloaded yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Download") {
                            BuddyHaptics.lightImpact()
                            onDownload()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BuddyTheme.cobalt)
                    }
                }
            }
        }
    }

    private var privacyFootnote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(BuddyTheme.cobalt)
                .padding(.top, 2)

            Text("Recommended on Wi-Fi. You can switch between Apple On-Device Speech, WhisperKit Large v3 Turbo, or import your own .gguf anytime in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private func bottomActionBar(isVoiceReady: Bool, isAllReady: Bool) -> some View {
        let needsWhisper = (modelManager.selectedSpeechEngine == .whisperKit)
            && !modelManager.isDownloaded(modelManager.selectedWhisperPreset)
        let needsLLM = !modelManager.isDownloaded(.qwen25_1_5B)
        let hasPendingDownloads = needsWhisper || needsLLM
        let missingMB = (needsWhisper ? modelManager.selectedWhisperPreset.approximateSizeMB : 0)
            + (needsLLM ? LLMPreset.qwen25_1_5B.approximateSizeMB : 0)

        return VStack(spacing: 10) {
            if isAllReady {
                Button {
                    BuddyHaptics.success()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Start Training")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(BuddyTheme.cobalt)
                    )
                }
                .buttonStyle(.plain)
            } else if hasPendingDownloads {
                let isBusy = modelManager.isDownloadingWhisper || modelManager.isDownloadingLLM
                let downloadLabel: String = {
                    if isBusy { return "Downloading Offline AI…" }
                    if needsWhisper && needsLLM {
                        return "Download Offline AI Pack (\(formatSizeMB(missingMB)))"
                    }
                    if needsWhisper {
                        return "Download \(modelManager.selectedWhisperPreset.displayName) (\(formatSizeMB(missingMB)))"
                    }
                    return "Download Qwen 2.5 Coach (\(formatSizeMB(missingMB)))"
                }()

                Button {
                    BuddyHaptics.mediumImpact()
                    Task {
                        await modelManager.downloadRecommendedPack()
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isBusy {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(downloadLabel)
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [BuddyTheme.cobalt, BuddyTheme.cobaltDeep],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .opacity(isBusy ? 0.78 : 1.0)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    BuddyHaptics.lightImpact()
                    dismiss()
                } label: {
                    Text(
                        isVoiceReady
                            ? "Start Now (Voice + Instant Parser Ready)"
                            : "Skip for now (Use Typed & Manual Logging)"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            } else {
                // Qwen 2.5 is already cached, but Apple On-Device Speech still needs setup in iOS Settings.
                Button {
                    BuddyHaptics.lightImpact()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                        Text("Continue (Typed & Manual Logging)")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(BuddyTheme.cobalt)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func formatSizeMB(_ mb: Int) -> String {
        if mb >= 1000 {
            return String(format: "~%.2f GB", Double(mb) / 1000.0)
        }
        return "~\(mb) MB"
    }
}
