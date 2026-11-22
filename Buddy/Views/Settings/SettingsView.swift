import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

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
    @State private var sceneRefreshTick: Int = 0

    private let llmPresets: [LLMPreset] = [.qwen25_1_5B, .qwen25_0_5B, .custom]

    var body: some View {
        let _ = sceneRefreshTick
        NavigationStack {
            Form {
                preferencesSection
                speechSection
                llmSection
                memoryAndRuntimeSection
                diagnosticsSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
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
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section("Preferences") {
            Picker(
                "Appearance",
                selection: Binding(
                    get: { BuddyAppearance(rawValue: appearanceRaw) ?? .dark },
                    set: { newAppearance in
                        BuddyHaptics.selection()
                        appearanceRaw = newAppearance.rawValue
                        BuddyAppearance.applyToAllWindows(newAppearance)
                    }
                )
            ) {
                ForEach(BuddyAppearance.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            Picker(
                "Weight Unit",
                selection: Binding(
                    get: { store.preferredUnit },
                    set: { newUnit in
                        BuddyHaptics.selection()
                        store.preferredUnit = newUnit
                        WidgetRefreshHelper.sync(store: store)
                    }
                )
            ) {
                ForEach(WeightUnit.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
        }
    }

    // MARK: - Speech Recognition (Apple On-Device)

    private var speechSection: some View {
        let availability = appleSpeechService.checkAvailability(for: modelManager.selectedAppleSpeechLocale)
        let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)

        return Section {
            Picker(
                "Voice Accent / Locale",
                selection: Binding(
                    get: { modelManager.selectedAppleSpeechLocale },
                    set: { newLocale in
                        BuddyHaptics.selection()
                        modelManager.selectedAppleSpeechLocale = newLocale
                    }
                )
            ) {
                ForEach(AppleSpeechLocaleOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            if isDenied {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(BuddyTheme.amberStreak)
                        .padding(.top, 1)

                    Text("Speech Recognition access is turned off. Enable it in iOS Settings → Buddy.")
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.amberStreak)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: availability.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(availability.isReady ? BuddyTheme.emeraldLive : BuddyTheme.amberStreak)
                        .padding(.top, 1)

                    Text(availability.statusMessage)
                        .font(.caption)
                        .foregroundStyle(availability.isReady ? Color.secondary : BuddyTheme.amberStreak)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Apple On-Device Speech")
        } footer: {
            Text("100% offline with live streaming captions, gym exercise vocabulary hints, 0 MB download, and zero extra RAM usage.")
        }
    }

    // MARK: - Local LLM (llama.cpp)

    private var llmSection: some View {
        let selected = modelManager.selectedLLMPreset

        return Section {
            Picker(
                "LLM Model",
                selection: Binding(
                    get: { modelManager.selectedLLMPreset },
                    set: { preset in
                        BuddyHaptics.selection()
                        let changed = (modelManager.selectedLLMPreset != preset)
                        modelManager.selectedLLMPreset = preset
                        modelManager.refreshDownloadState()
                        if changed {
                            llmService.unload()
                        }
                    }
                )
            ) {
                ForEach(llmPresets, id: \.self) { preset in
                    if preset.approximateSizeMB > 0 {
                        Text("\(preset.displayName) (\(formatSizeMB(preset.approximateSizeMB)))")
                            .tag(preset)
                    } else {
                        Text(preset.displayName).tag(preset)
                    }
                }
            }
            .disabled(modelManager.isDownloadingLLM)

            Text(selected.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let customName = modelManager.customLLMFileName, !customName.isEmpty {
                LabeledContent("Custom GGUF") {
                    Text(customName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if modelManager.isDownloadingLLM {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: min(max(modelManager.llmDownloadProgress, 0), 1))
                        .tint(BuddyTheme.inkPrimary)
                    HStack {
                        Text("Downloading \(selected.displayName)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((min(max(modelManager.llmDownloadProgress, 0), 1) * 100).rounded()))%")
                            .font(.caption.weight(.semibold))
                            .buddyNumeric()
                            .foregroundStyle(.primary)
                    }
                    Button("Cancel Download", role: .destructive) {
                        BuddyHaptics.lightImpact()
                        modelManager.cancelLLMDownload()
                    }
                    .font(.caption.weight(.semibold))
                }
            } else if modelManager.isLLMDownloaded {
                HStack {
                    Label("Downloaded & Ready", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(BuddyTheme.emeraldLive)
                    Spacer()
                    Button("Delete", role: .destructive) {
                        BuddyHaptics.warning()
                        llmService.unload()
                        modelManager.deleteLLMModel(selected)
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else if selected != .custom {
                Button {
                    BuddyHaptics.mediumImpact()
                    Task {
                        await modelManager.downloadLLMModel(selected)
                    }
                } label: {
                    Label(
                        "Download \(selected.displayName) (\(formatSizeMB(selected.approximateSizeMB)))",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                }
            }

            Button {
                BuddyHaptics.lightImpact()
                showFileImporter = true
            } label: {
                Label("Import .gguf from Files", systemImage: "doc.badge.plus")
                    .foregroundStyle(.primary)
            }

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
        } header: {
            Text("Local LLM (llama.cpp)")
        } footer: {
            Text("Buddy falls back to the zero-latency Instant Parser whenever no LLM model is downloaded.")
        }
    }

    // MARK: - Memory & Runtime

    private var memoryAndRuntimeSection: some View {
        Section {
            LabeledContent("Speech Engine") {
                let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)
                let availability = appleSpeechService.checkAvailability(for: modelManager.selectedAppleSpeechLocale)
                let badgeColor: Color = (isDenied || !availability.isReady) ? BuddyTheme.amberStreak : BuddyTheme.emeraldLive
                let badgeLabel: String = {
                    if isDenied { return "Permission Needed" }
                    if !availability.isReady { return "Offline Pack Needed" }
                    return "Apple On-Device"
                }()

                HStack(spacing: 5) {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: 7, height: 7)
                    Text(badgeLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(badgeColor)
                }
            }

            LabeledContent("LLM Runtime") {
                runtimeBadge(
                    isLoaded: llmService.isLoaded,
                    isLoading: llmService.isLoading,
                    label: llmService.loadedModelName
                )
            }

            LabeledContent("Model Storage") {
                Text(modelManager.totalStorageUsedDescription)
                    .buddyNumeric()
                    .foregroundStyle(.secondary)
            }

            if let memoryNotice = llmService.lastMemoryNotice, !memoryNotice.isEmpty {
                Text(memoryNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                BuddyHaptics.lightImpact()
                llmService.unload()
            } label: {
                Label("Free LLM Memory", systemImage: "memorychip")
                    .foregroundStyle(.primary)
            }
            .disabled(!llmService.isLoaded)
        } header: {
            Text("Memory & Runtime")
        }
    }

    // MARK: - SideStore & Widget Sync

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("App Group") {
                Text(AppGroupResolver.diagnosticSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("Bundle ID") {
                Text(Bundle.main.bundleIdentifier ?? "com.yuvaraja.buddy")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Button {
                BuddyHaptics.success()
                WidgetRefreshHelper.sync(store: store)
                widgetRefreshNote = "Widgets refreshed at \(Date().formatted(date: .omitted, time: .standard))"
            } label: {
                Label("Test Widget Refresh", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(.primary)
            }

            if let widgetRefreshNote {
                Text(widgetRefreshNote)
                    .font(.caption)
                    .foregroundStyle(BuddyTheme.emeraldLive)
            }
        } header: {
            Text("SideStore & Widget Sync")
        } footer: {
            Text("App Groups are resolved dynamically from embedded provisioning metadata so widgets stay synced after SideStore re-signing.")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func runtimeBadge(isLoaded: Bool, isLoading: Bool, label: String?) -> some View {
        if isLoading {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if isLoaded {
            HStack(spacing: 5) {
                Circle()
                    .fill(BuddyTheme.emeraldLive)
                    .frame(width: 7, height: 7)
                Text(label ?? "Loaded")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BuddyTheme.emeraldLive)
            }
        } else {
            Text("Standby")
                .font(.caption)
                .foregroundStyle(.secondary)
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
