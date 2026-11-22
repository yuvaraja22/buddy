import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

/// Pure OLED monochrome Settings sheet matching Buddy's YouTube/Uber aesthetic
/// (zero default grey iOS Form chrome).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let store: WorkoutStore
    let modelManager: ModelManager
    let appleSpeechService: AppleSpeechService
    let llmService: LocalLLMService

    @AppStorage("buddy.preferences.appearance") private var appearanceRaw: String = BuddyAppearance.dark.rawValue
    @State private var showFileImporter: Bool = false
    @State private var importMessage: String?
    @State private var importIsError: Bool = false
    @State private var widgetRefreshNote: String?
    @State private var showDiagnostics: Bool = false
    @State private var sceneRefreshTick: Int = 0

    private let llmPresets: [LLMPreset] = [.qwen25_1_5B, .qwen25_0_5B, .custom]

    private var currentAppearance: BuddyAppearance {
        BuddyAppearance(rawValue: appearanceRaw) ?? .dark
    }

    var body: some View {
        let _ = sceneRefreshTick
        VStack(spacing: 0) {
            settingsHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    preferencesCard
                    speechCard
                    localLLMCard
                    runtimeCard
                    diagnosticsAccordionCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .background(BuddyTheme.canvasBackground.ignoresSafeArea())
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data]
        ) { result in
            handleGGUFImport(result)
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

    // MARK: - Top Header

    private var settingsHeader: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.primary)

            Spacer()

            Button {
                BuddyHaptics.lightImpact()
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(BuddyTheme.inkInverse)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(BuddyTheme.inkPrimary))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Appearance & Weight Units

    private var preferencesCard: some View {
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                sectionEyebrow("PREFERENCES")

                // Appearance inline segmented pills
                VStack(alignment: .leading, spacing: 8) {
                    Text("Appearance")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)

                    HStack(spacing: 6) {
                        ForEach(BuddyAppearance.allCases) { option in
                            let selected = (currentAppearance == option)
                            Button {
                                BuddyHaptics.selection()
                                appearanceRaw = option.rawValue
                                BuddyAppearance.applyToAllWindows(option)
                            } label: {
                                Text(shortAppearanceLabel(option))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(selected ? BuddyTheme.inkInverse : Color.primary)
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

                Divider().overlay(BuddyTheme.hairlineBorder)

                // Weight unit inline segmented pills
                VStack(alignment: .leading, spacing: 8) {
                    Text("Weight Unit")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)

                    HStack(spacing: 8) {
                        ForEach(WeightUnit.allCases) { unit in
                            let selected = (store.preferredUnit == unit)
                            Button {
                                BuddyHaptics.selection()
                                store.preferredUnit = unit
                                WidgetRefreshHelper.sync(store: store)
                            } label: {
                                Text(unit.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(selected ? BuddyTheme.inkInverse : Color.primary)
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
    }

    // MARK: - Apple On-Device Speech

    private var speechCard: some View {
        let availability = appleSpeechService.checkAvailability(for: modelManager.selectedAppleSpeechLocale)
        let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionEyebrow("APPLE ON-DEVICE SPEECH")
                    Spacer()
                    statusDotPill(
                        text: isDenied ? "Permission Off" : (availability.isReady ? "Offline Ready" : "Setup Needed"),
                        color: (isDenied || !availability.isReady) ? BuddyTheme.amberStreak : BuddyTheme.emeraldLive
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice Accent / Locale")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(AppleSpeechLocaleOption.allCases) { option in
                                let selected = (modelManager.selectedAppleSpeechLocale == option)
                                Button {
                                    BuddyHaptics.selection()
                                    modelManager.selectedAppleSpeechLocale = option
                                } label: {
                                    Text(option.displayName)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(selected ? BuddyTheme.inkInverse : Color.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
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

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isDenied || !availability.isReady ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle((isDenied || !availability.isReady) ? BuddyTheme.amberStreak : BuddyTheme.emeraldLive)
                        .padding(.top, 1)

                    Text(
                        isDenied
                            ? "Speech Recognition access is turned off. Enable it in iOS Settings → Buddy."
                            : availability.statusMessage
                    )
                    .font(.caption)
                    .foregroundStyle((isDenied || !availability.isReady) ? BuddyTheme.amberStreak : BuddyTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(BuddyTheme.elevatedSurface)
                )
            }
        }
    }

    // MARK: - Local LLM (llama.cpp)

    private var localLLMCard: some View {
        let selected = modelManager.selectedLLMPreset

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionEyebrow("LOCAL AI COACH & PARSER")
                    Spacer()
                    if modelManager.isLLMDownloaded {
                        statusDotPill(text: "Downloaded", color: BuddyTheme.emeraldLive)
                    } else {
                        statusDotPill(text: "Optional", color: BuddyTheme.mutedText)
                    }
                }

                VStack(spacing: 8) {
                    ForEach(llmPresets, id: \.self) { preset in
                        let isSelected = (selected == preset)
                        Button {
                            guard !modelManager.isDownloadingLLM else { return }
                            BuddyHaptics.selection()
                            let changed = (modelManager.selectedLLMPreset != preset)
                            modelManager.selectedLLMPreset = preset
                            modelManager.refreshDownloadState()
                            if changed {
                                llmService.unload()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(isSelected ? BuddyTheme.inkPrimary : BuddyTheme.mutedText)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.displayName)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Color.primary)

                                    Text(preset.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(BuddyTheme.mutedText)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }

                                Spacer(minLength: 4)

                                if preset.approximateSizeMB > 0 {
                                    Text(formatSizeMB(preset.approximateSizeMB))
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(BuddyTheme.mutedText)
                                }
                            }
                            .padding(11)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? BuddyTheme.inkPrimary.opacity(0.45) : Color.clear,
                                        lineWidth: 1.0
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(modelManager.isDownloadingLLM)
                    }
                }

                if let customName = modelManager.customLLMFileName, !customName.isEmpty {
                    keyValueRow(title: "Custom GGUF", value: customName)
                }

                // Download / Progress / Delete CTA
                if modelManager.isDownloadingLLM {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Downloading \(selected.displayName)…")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Text("\(Int((min(max(modelManager.llmDownloadProgress, 0), 1) * 100).rounded()))%")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.primary)
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(BuddyTheme.elevatedSurface)
                                Capsule()
                                    .fill(BuddyTheme.inkPrimary)
                                    .frame(width: max(8, proxy.size.width * min(max(modelManager.llmDownloadProgress, 0), 1)))
                            }
                        }
                        .frame(height: 6)

                        Button {
                            BuddyHaptics.lightImpact()
                            modelManager.cancelLLMDownload()
                        } label: {
                            Text("Cancel Download")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(BuddyTheme.destructive)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(BuddyTheme.destructive.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                } else if modelManager.isLLMDownloaded {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(BuddyTheme.emeraldLive)
                            Text("Ready for offline AI")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Color.primary)
                        }
                        Spacer()
                        Button {
                            BuddyHaptics.warning()
                            llmService.unload()
                            modelManager.deleteLLMModel(selected)
                        } label: {
                            Text("Delete")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(BuddyTheme.destructive)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(BuddyTheme.destructive.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(BuddyTheme.elevatedSurface)
                    )
                } else if selected != .custom {
                    Button {
                        BuddyHaptics.mediumImpact()
                        Task {
                            await modelManager.downloadLLMModel(selected)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("Download \(selected.displayName) (\(formatSizeMB(selected.approximateSizeMB)))")
                                .font(.system(size: 13.5, weight: .bold))
                        }
                        .foregroundStyle(BuddyTheme.inkInverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(BuddyTheme.inkPrimary))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    BuddyHaptics.lightImpact()
                    showFileImporter = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Import .gguf from Files")
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(BuddyTheme.chipSurface))
                }
                .buttonStyle(.plain)

                if let error = modelManager.downloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.destructive)
                }

                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundStyle(importIsError ? BuddyTheme.destructive : BuddyTheme.emeraldLive)
                }

                Text("Buddy uses the zero-latency Instant Parser automatically whenever no LLM is downloaded.")
                    .font(.caption)
                    .foregroundStyle(BuddyTheme.mutedText)
            }
        }
    }

    // MARK: - Memory & Runtime

    private var runtimeCard: some View {
        let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)
        let availability = appleSpeechService.checkAvailability(for: modelManager.selectedAppleSpeechLocale)
        let speechColor: Color = (isDenied || !availability.isReady) ? BuddyTheme.amberStreak : BuddyTheme.emeraldLive
        let speechLabel: String = isDenied ? "Permission Needed" : (!availability.isReady ? "Offline Pack Needed" : "Apple On-Device")

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                sectionEyebrow("MEMORY & RUNTIME")

                HStack {
                    Text("Speech Engine")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    statusDotPill(text: speechLabel, color: speechColor)
                }

                Divider().overlay(BuddyTheme.hairlineBorder)

                HStack {
                    Text("LLM Runtime")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    runtimeBadge(
                        isLoaded: llmService.isLoaded,
                        isLoading: llmService.isLoading,
                        label: llmService.loadedModelName
                    )
                }

                Divider().overlay(BuddyTheme.hairlineBorder)

                keyValueRow(title: "Model Storage", value: modelManager.totalStorageUsedDescription)

                if let memoryNotice = llmService.lastMemoryNotice, !memoryNotice.isEmpty {
                    Text(memoryNotice)
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.mutedText)
                }

                if llmService.isLoaded {
                    Button {
                        BuddyHaptics.lightImpact()
                        llmService.unload()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Free LLM Memory")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(BuddyTheme.chipSurface))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Collapsible Diagnostics & Widgets Accordion

    private var diagnosticsAccordionCard: some View {
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    BuddyHaptics.lightImpact()
                    withAnimation(.snappy(duration: 0.22)) {
                        showDiagnostics.toggle()
                    }
                } label: {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(BuddyTheme.mutedText)
                            Text("SideStore & Widget Diagnostics")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.primary)
                        }
                        Spacer()
                        Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                }
                .buttonStyle(.plain)

                if showDiagnostics {
                    Divider().overlay(BuddyTheme.hairlineBorder)

                    keyValueRow(title: "App Group", value: AppGroupResolver.diagnosticSummary)
                    keyValueRow(title: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "com.yuvaraja.buddy")

                    Button {
                        BuddyHaptics.success()
                        WidgetRefreshHelper.sync(store: store)
                        widgetRefreshNote = "Widgets refreshed at \(Date().formatted(date: .omitted, time: .standard))"
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12.5, weight: .bold))
                            Text("Refresh Widgets Now")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(BuddyTheme.chipSurface))
                    }
                    .buttonStyle(.plain)

                    if let widgetRefreshNote {
                        Text(widgetRefreshNote)
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.emeraldLive)
                    }

                    Text("App Groups resolve dynamically from embedded provisioning metadata so widgets stay synced after SideStore re-signing.")
                        .font(.caption2)
                        .foregroundStyle(BuddyTheme.mutedText)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(BuddyTheme.mutedText)
    }

    private func statusDotPill(text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6.5, height: 6.5)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private func keyValueRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.primary)
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BuddyTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func shortAppearanceLabel(_ option: BuddyAppearance) -> String {
        switch option {
        case .dark: return "OLED Dark"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    @ViewBuilder
    private func runtimeBadge(isLoaded: Bool, isLoading: Bool, label: String?) -> some View {
        if isLoading {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(BuddyTheme.inkPrimary)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(BuddyTheme.mutedText)
            }
        } else if isLoaded {
            statusDotPill(text: label ?? "Loaded", color: BuddyTheme.emeraldLive)
        } else {
            Text("Standby")
                .font(.caption.weight(.medium))
                .foregroundStyle(BuddyTheme.mutedText)
        }
    }

    private func handleGGUFImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                llmService.unload()
                try modelManager.importCustomGGUF(from: url)
                importIsError = false
                importMessage = "Imported \(url.lastPathComponent) successfully."
                BuddyHaptics.success()
            } catch {
                importIsError = true
                importMessage = "Import failed: \(error.localizedDescription)"
                BuddyHaptics.error()
            }

        case .failure(let error):
            importIsError = true
            importMessage = "File picker error: \(error.localizedDescription)"
            BuddyHaptics.error()
        }
    }

    private func formatSizeMB(_ mb: Int) -> String {
        if mb >= 1000 {
            return String(format: "~%.2f GB", Double(mb) / 1000.0)
        }
        return "~\(mb) MB"
    }
}
