import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let store: WorkoutStore
    let modelManager: ModelManager
    let whisperService: WhisperTranscriptionService
    let llmService: LocalLLMService

    @State private var showFileImporter: Bool = false
    @State private var importMessage: String?
    @State private var importIsError: Bool = false
    @State private var widgetRefreshNote: String?

    private let whisperPresets: [WhisperPreset] = [.baseEn, .tinyEn, .baseMultilingual]
    private let llmPresets: [LLMPreset] = [.qwen25_1_5B, .qwen25_0_5B, .custom]

    var body: some View {
        NavigationStack {
            Form {
                preferencesSection
                whisperSection
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
                    .fontWeight(.semibold)
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
            }
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section("Preferences") {
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

    // MARK: - Speech Model (WhisperKit)

    private var whisperSection: some View {
        let selected = modelManager.selectedWhisperPreset

        return Section {
            Picker(
                "Whisper Variant",
                selection: Binding(
                    get: { modelManager.selectedWhisperPreset },
                    set: { preset in
                        BuddyHaptics.selection()
                        modelManager.selectedWhisperPreset = preset
                        modelManager.refreshDownloadState()
                    }
                )
            ) {
                ForEach(whisperPresets, id: \.self) { preset in
                    Text("\(preset.displayName) (~\(preset.approximateSizeMB) MB)")
                        .tag(preset)
                }
            }

            Text(selected.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if modelManager.isDownloadingWhisper {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(modelManager.whisperDownloadProgress, 0), 1))
                        .tint(BuddyTheme.cobalt)
                    HStack {
                        Text("Downloading \(selected.displayName)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((min(max(modelManager.whisperDownloadProgress, 0), 1) * 100).rounded()))%")
                            .font(.caption.weight(.semibold))
                            .buddyNumeric()
                            .foregroundStyle(BuddyTheme.cobalt)
                    }
                }
            } else if modelManager.isWhisperDownloaded {
                HStack {
                    Label("Downloaded & Ready", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(BuddyTheme.emeraldLive)
                    Spacer()
                    Button("Delete", role: .destructive) {
                        BuddyHaptics.warning()
                        Task {
                            await whisperService.unload()
                            modelManager.deleteWhisperModel(selected)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else {
                Button {
                    BuddyHaptics.mediumImpact()
                    Task {
                        await modelManager.downloadWhisperModel(selected)
                    }
                } label: {
                    Label(
                        "Download \(selected.displayName) (~\(selected.approximateSizeMB) MB)",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BuddyTheme.cobalt)
                }
            }
        } header: {
            Text("Speech Model (WhisperKit)")
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
                        modelManager.selectedLLMPreset = preset
                        modelManager.refreshDownloadState()
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
                        .tint(BuddyTheme.cobalt)
                    HStack {
                        Text("Downloading \(selected.displayName)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((min(max(modelManager.llmDownloadProgress, 0), 1) * 100).rounded()))%")
                            .font(.caption.weight(.semibold))
                            .buddyNumeric()
                            .foregroundStyle(BuddyTheme.cobalt)
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
                    .foregroundStyle(BuddyTheme.cobalt)
                }
            }

            Button {
                BuddyHaptics.lightImpact()
                showFileImporter = true
            } label: {
                Label("Import .gguf from Files", systemImage: "doc.badge.plus")
                    .foregroundStyle(BuddyTheme.cobalt)
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
            LabeledContent("Whisper Runtime") {
                runtimeBadge(
                    isLoaded: whisperService.isLoaded,
                    isLoading: whisperService.isLoading,
                    label: whisperService.loadedVariantName
                )
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
                Task {
                    await whisperService.unload()
                    llmService.unload()
                }
            } label: {
                Label("Free Model Memory", systemImage: "memorychip")
                    .foregroundStyle(BuddyTheme.cobalt)
            }
            .disabled(!whisperService.isLoaded && !llmService.isLoaded)
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
                    .foregroundStyle(BuddyTheme.cobalt)
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
