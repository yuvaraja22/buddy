import SwiftUI

struct ModelSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let modelManager: ModelManager
    let appleSpeechService: AppleSpeechService

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroHeader

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
                bottomActionBar
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
    }

    @ViewBuilder
    private var speechCard: some View {
        if modelManager.selectedSpeechEngine == .appleOnDevice {
            let availability = appleSpeechService.checkAvailability(for: modelManager.selectedAppleSpeechLocale)
            NativeCard(padding: 16, cornerRadius: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(availability.isReady ? BuddyTheme.emeraldLive.opacity(0.14) : BuddyTheme.amberStreak.opacity(0.14))
                                .frame(width: 42, height: 42)

                            Image(systemName: availability.isReady ? "checkmark.circle.fill" : "waveform")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(availability.isReady ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
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
                                    .foregroundStyle(BuddyTheme.emeraldLive)
                            }

                            Text("Instant live speech-to-text tuned for 105 gym exercises & your accent. WhisperKit Large v3 Turbo is also available in Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: availability.isReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(availability.isReady ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
                        Text(availability.statusMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(availability.isReady ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
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

    private var heroHeader: some View {
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

                Text("Voice logging works right away with Apple On-Device Speech. Download Qwen 2.5 once over Wi-Fi for your offline Gym Coach and natural-language parsing.")
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

    private var bottomActionBar: some View {
        VStack(spacing: 10) {
            if modelManager.isAllDownloaded {
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
            } else {
                let isBusy = modelManager.isDownloadingWhisper || modelManager.isDownloadingLLM
                let downloadLabel: String = {
                    if isBusy { return "Downloading Offline AI…" }
                    if modelManager.selectedSpeechEngine == .appleOnDevice {
                        return "Download Qwen 2.5 Coach (~1.05 GB)"
                    }
                    let totalMB = modelManager.selectedWhisperPreset.approximateSizeMB + LLMPreset.qwen25_1_5B.approximateSizeMB
                    return "Download Offline AI Pack (\(formatSizeMB(totalMB)))"
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
                    Text("Start Now (Voice + Instant Parser Ready)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
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
