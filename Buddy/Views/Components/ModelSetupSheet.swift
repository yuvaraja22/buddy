import SwiftUI

struct ModelSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let modelManager: ModelManager
    let appleSpeechService: AppleSpeechService

    @State private var sceneRefreshTick: Int = 0

    /// Active LLM preset shown and downloaded by this sheet: honors `Qwen 2.5 0.5B` or an imported
    /// `Custom GGUF` when selected in Settings, and falls back to `Qwen 2.5 1.5B` if `.custom` is
    /// selected without a file on disk.
    private var activeLLMPreset: LLMPreset {
        if modelManager.selectedLLMPreset == .custom && !modelManager.isLLMDownloaded {
            return .qwen25_1_5B
        }
        return modelManager.selectedLLMPreset
    }

    var body: some View {
        let _ = sceneRefreshTick
        let preset = activeLLMPreset
        let isVoiceReady = appleSpeechService.isReadyForVoice(
            for: modelManager.selectedAppleSpeechLocale,
            mode: modelManager.selectedAppleSpeechMode
        )
        let isLLMReady = modelManager.isDownloaded(preset)
        let isAllReady = isVoiceReady && isLLMReady

        let llmCardTitle: String = {
            if preset == .custom, let customName = modelManager.customLLMFileName, !customName.isEmpty {
                return customName
            }
            return preset.displayName
        }()
        let llmCardSize = preset.approximateSizeMB > 0
            ? formatSizeMB(preset.approximateSizeMB)
            : "Imported"

        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    heroHeader(isVoiceReady: isVoiceReady)

                    VStack(spacing: 12) {
                        speechCard

                        modelRowCard(
                            icon: "sparkles",
                            title: llmCardTitle,
                            subtitle: preset.subtitle,
                            sizeText: llmCardSize,
                            isDownloaded: isLLMReady,
                            isDownloading: modelManager.isDownloadingLLM,
                            progress: modelManager.llmDownloadProgress,
                            onDownload: {
                                Task { await modelManager.downloadLLMModel(preset) }
                            }
                        )
                    }

                    if let error = modelManager.downloadError {
                        NativeCard(padding: 12, cornerRadius: 12, tint: BuddyTheme.destructive) {
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
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                bottomActionBar(
                    preset: preset,
                    isVoiceReady: isVoiceReady,
                    isLLMReady: isLLMReady,
                    isAllReady: isAllReady
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
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

    private var speechCard: some View {
        let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)
        let availability = appleSpeechService.checkAvailability(
            for: modelManager.selectedAppleSpeechLocale,
            mode: modelManager.selectedAppleSpeechMode
        )
        let ready = !isDenied && availability.isReady
        let statusText = isDenied
            ? "Speech Recognition permission is turned off. Enable it in iOS Settings → Buddy."
            : availability.statusMessage

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                            .frame(width: 40, height: 40)

                        Image(systemName: ready ? "checkmark.circle.fill" : "waveform")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ready ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Apple Speech (Gym Tuned)")
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(.primary)

                            Spacer()

                            Text("0 MB")
                                .font(.caption.weight(.bold))
                                .buddyNumeric()
                                .foregroundStyle(ready ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
                        }

                        Text("Hardware noise isolation, close-talk iPhone mic routing, and cloud-enhanced Apple Speech with automatic offline fallback.")
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
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
    }

    private func heroHeader(isVoiceReady: Bool) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(BuddyTheme.inkPrimary)
                    .frame(width: 60, height: 60)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(BuddyTheme.inkInverse)
            }

            VStack(spacing: 6) {
                Text("100% Offline AI")
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)

                Text(
                    isVoiceReady
                        ? "Voice logging works right away with Apple On-Device Speech. Download a local Qwen model once over Wi-Fi for your offline Gym Coach and natural-language parsing."
                        : "Enable offline Dictation in iOS Settings for voice logging, and download a local Qwen model once over Wi-Fi for your offline Gym Coach."
                )
                .font(.subheadline)
                .foregroundStyle(BuddyTheme.mutedText)
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
        .padding(.top, 6)
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
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                            .frame(width: 40, height: 40)

                        Image(systemName: isDownloaded ? "checkmark.circle.fill" : icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isDownloaded ? BuddyTheme.emeraldLive : Color.primary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Text(sizeText)
                                .font(.caption.weight(.bold))
                                .buddyNumeric()
                                .foregroundStyle(BuddyTheme.mutedText)
                        }

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isDownloading {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: min(max(progress, 0), 1))
                            .tint(BuddyTheme.inkPrimary)

                        HStack {
                            Text("Downloading…")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(BuddyTheme.mutedText)
                            Spacer()
                            Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                                .font(.caption2.weight(.bold))
                                .buddyNumeric()
                                .foregroundStyle(.primary)
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
                            .foregroundStyle(BuddyTheme.mutedText)
                        Spacer()
                        Button("Download") {
                            BuddyHaptics.lightImpact()
                            onDownload()
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private var privacyFootnote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.top, 2)

            Text("Recommended on Wi-Fi. You can switch between Qwen 2.5 1.5B, Qwen 2.5 0.5B, or import your own .gguf file anytime in Settings.")
                .font(.caption)
                .foregroundStyle(BuddyTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private func bottomActionBar(
        preset: LLMPreset,
        isVoiceReady: Bool,
        isLLMReady: Bool,
        isAllReady: Bool
    ) -> some View {
        let needsLLM = !isLLMReady && preset != .custom

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
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(BuddyTheme.inkInverse)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(BuddyTheme.inkPrimary)
                    )
                }
                .buttonStyle(.plain)
            } else if needsLLM {
                let isBusy = modelManager.isDownloadingLLM
                let sizeLabel = formatSizeMB(preset.approximateSizeMB)

                Button {
                    BuddyHaptics.mediumImpact()
                    Task {
                        await modelManager.downloadLLMModel(preset)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isBusy {
                            ProgressView()
                                .tint(BuddyTheme.inkInverse)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(isBusy ? "Downloading \(preset.displayName)…" : "Download \(preset.displayName) (\(sizeLabel))")
                    }
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(BuddyTheme.inkInverse)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(BuddyTheme.inkPrimary)
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
                    .foregroundStyle(BuddyTheme.mutedText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    BuddyHaptics.lightImpact()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                        Text("Continue (Typed & Manual Logging)")
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(BuddyTheme.inkInverse)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(BuddyTheme.inkPrimary)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(BuddyTheme.canvasBackground)
        .overlay(alignment: .top) {
            Divider().overlay(BuddyTheme.hairlineBorder)
        }
    }

    private func formatSizeMB(_ mb: Int) -> String {
        if mb >= 1000 {
            return String(format: "~%.2f GB", Double(mb) / 1000.0)
        }
        return "~\(mb) MB"
    }
}
