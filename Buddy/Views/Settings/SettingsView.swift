import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

/// Organized Uber/YouTube-style OLED monochrome Settings hub:
/// 1. Profile & Preferences directly on the root screen (Display Name, Weekly Goal 1–7d, Appearance, Weight Unit)
/// 2. App Settings drill-down rows for Cloud Sync & Backup, Voice & Local AI, and SideStore Diagnostics.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let store: WorkoutStore
    let modelManager: ModelManager
    let appleSpeechService: AppleSpeechService
    let whisperService: WhisperTranscriptionService
    let llmService: LocalLLMService
    let cloudSync: FirebaseSyncService

    @AppStorage("buddy.preferences.appearance") private var appearanceRaw: String = BuddyAppearance.dark.rawValue
    @State private var sceneRefreshTick: Int = 0

    private var currentAppearance: BuddyAppearance {
        BuddyAppearance(rawValue: appearanceRaw) ?? .dark
    }

    var body: some View {
        let _ = sceneRefreshTick
        let consistency = StatsCalculator.consistency(
            sessions: store.sessions,
            referenceDate: Date(),
            weeklyGoal: store.weeklyGoal
        )

        NavigationStack {
            VStack(spacing: 0) {
                settingsHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        profileCard(consistency: consistency)

                        weeklyGoalCard(consistency: consistency)

                        quickPreferencesCard

                        appSettingsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
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
        .tint(BuddyTheme.inkPrimary)
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

    // MARK: - Profile Card

    private func profileCard(consistency: ConsistencyStats) -> some View {
        let trimmedName = store.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let avatarInitials = initials(from: trimmedName)

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                sectionEyebrow("PROFILE")

                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(BuddyTheme.inkPrimary)
                            .frame(width: 46, height: 46)
                        Text(avatarInitials)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(BuddyTheme.inkInverse)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "Your Name",
                            text: Binding(
                                get: { store.displayName },
                                set: { store.displayName = $0 }
                            )
                        )
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .submitLabel(.done)

                        HStack(spacing: 6) {
                            Text("\(consistency.totalWorkouts) \(consistency.totalWorkouts == 1 ? "workout" : "workouts")")
                                .monospacedDigit()
                            Text("·")
                            Text("\(consistency.currentStreakDays)d streak")
                                .monospacedDigit()
                            Text("·")
                            Text("\(store.weeklyGoal)d/wk goal")
                                .monospacedDigit()
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(BuddyTheme.mutedText)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }
            }
        }
    }

    // MARK: - Settable Weekly Goal Card (1–7 days/week)

    private func weeklyGoalCard(consistency: ConsistencyStats) -> some View {
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    sectionEyebrow("WEEKLY GOAL")
                    Spacer()
                    Text("\(store.weeklyGoal) \(store.weeklyGoal == 1 ? "day" : "days") / week")
                        .font(.system(size: 13.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                }

                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { days in
                        let selected = (store.weeklyGoal == days)
                        Button {
                            BuddyHaptics.selection()
                            store.weeklyGoal = days
                        } label: {
                            Text("\(days)")
                                .font(.system(size: 14, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(selected ? BuddyTheme.inkInverse : Color.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(selected ? BuddyTheme.inkPrimary : BuddyTheme.chipSurface)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(days) workouts per week")
                    }
                }

                Text("This week: \(consistency.workoutsThisWeek) of \(store.weeklyGoal) completed. Updates Home, Calendar, Trends, and Widgets.")
                    .font(.caption)
                    .foregroundStyle(BuddyTheme.mutedText)
            }
        }
    }

    // MARK: - Quick Preferences (Appearance & Weight Unit)

    private var quickPreferencesCard: some View {
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                sectionEyebrow("PREFERENCES")

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

    // MARK: - App Settings Navigation Rows

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App Settings")
                .font(BuddyTheme.sectionTitleFont)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 2)

            NativeCard(padding: 0, cornerRadius: 14) {
                VStack(spacing: 0) {
                    NavigationLink {
                        CloudSyncSettingsView(store: store, cloudSync: cloudSync)
                    } label: {
                        settingsNavRow(
                            icon: "icloud",
                            title: "Cloud Sync & Backup",
                            subtitle: cloudSyncRowSubtitle,
                            statusColor: cloudSyncRowDotColor
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .overlay(BuddyTheme.hairlineBorder)
                        .padding(.leading, 56)

                    NavigationLink {
                        VoiceAndAISettingsView(
                            modelManager: modelManager,
                            appleSpeechService: appleSpeechService,
                            whisperService: whisperService,
                            llmService: llmService
                        )
                    } label: {
                        settingsNavRow(
                            icon: "waveform",
                            title: "Voice & Local AI",
                            subtitle: voiceAndAIRowSubtitle,
                            statusColor: voiceAndAIRowDotColor
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .overlay(BuddyTheme.hairlineBorder)
                        .padding(.leading, 56)

                    NavigationLink {
                        DiagnosticsSettingsView(store: store)
                    } label: {
                        settingsNavRow(
                            icon: "wrench.and.screwdriver",
                            title: "SideStore & Diagnostics",
                            subtitle: "Widgets, App Group & Bundle ID",
                            statusColor: nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func settingsNavRow(
        icon: String,
        title: String,
        subtitle: String,
        statusColor: Color?
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(BuddyTheme.elevatedSurface)
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primary)

                HStack(spacing: 5) {
                    if let statusColor {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.mutedText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(BuddyTheme.mutedText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: - Live Row Status Subtitles

    private var cloudSyncRowSubtitle: String {
        if cloudSync.isSignedIn {
            if cloudSync.syncState == .syncing {
                return "Firebase · Syncing…"
            }
            if case .error = cloudSync.syncState {
                return "Firebase · Sync issue"
            }
            if let synced = cloudSync.lastSyncedAt {
                return "Firebase · Synced \(synced.formatted(date: .omitted, time: .shortened))"
            }
            return "Firebase · \(cloudSync.userEmail ?? "Connected")"
        }
        if cloudSync.isConfigured {
            return cloudSync.isGoogleSignInConfigured
                ? "Google Sign-In · Tap to sync"
                : "Firebase · Tap to sign in"
        }
        return "Firebase & JSON Export"
    }

    private var cloudSyncRowDotColor: Color? {
        if cloudSync.isSignedIn {
            if case .error = cloudSync.syncState { return BuddyTheme.destructive }
            return BuddyTheme.emeraldLive
        }
        return BuddyTheme.mutedText
    }

    private var voiceAndAIRowSubtitle: String {
        let aiLabel = modelManager.isLLMDownloaded
            ? modelManager.selectedLLMPreset.displayName
            : "Instant Parser"
        if modelManager.effectiveSpeechEngine == .whisperKit {
            return "\(modelManager.selectedWhisperPreset.shortDisplayName) · \(aiLabel)"
        }
        return "Apple Speech (\(modelManager.selectedAppleSpeechMode.shortLabel)) · \(aiLabel)"
    }

    private var voiceAndAIRowDotColor: Color {
        if modelManager.effectiveSpeechEngine == .whisperKit {
            return BuddyTheme.emeraldLive
        }
        let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)
        let availability = appleSpeechService.checkAvailability(
            for: modelManager.selectedAppleSpeechLocale,
            mode: modelManager.selectedAppleSpeechMode
        )
        return (isDenied || !availability.isReady) ? BuddyTheme.amberStreak : BuddyTheme.emeraldLive
    }

    // MARK: - Helpers

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(BuddyTheme.mutedText)
    }

    private func shortAppearanceLabel(_ option: BuddyAppearance) -> String {
        switch option {
        case .dark: return "OLED Dark"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    private func initials(from name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "B" : letters
    }
}

// MARK: - Sub-Page: Voice & Local AI Settings

private struct VoiceAndAISettingsView: View {
    let modelManager: ModelManager
    let appleSpeechService: AppleSpeechService
    let whisperService: WhisperTranscriptionService
    let llmService: LocalLLMService

    @State private var showFileImporter: Bool = false
    @State private var importMessage: String?
    @State private var importIsError: Bool = false
    @State private var manualOptimizeError: String?

    private let whisperPresets: [WhisperPreset] = [.largeV3Turbo, .largeV3TurboCompact, .smallEn]
    private let llmPresets: [LLMPreset] = [.qwen25_1_5B, .qwen25_0_5B, .custom]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                speechCard
                gymAudioCard
                localLLMCard
                runtimeCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(BuddyTheme.canvasBackground.ignoresSafeArea())
        .navigationTitle("Voice & Local AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data]
        ) { result in
            handleGGUFImport(result)
        }
    }

    private var speechCard: some View {
        let selectedEngine = modelManager.selectedSpeechEngine
        let isWhisperBusy = modelManager.isDownloadingWhisper
            || modelManager.isOptimizingWhisper
            || whisperService.isPrewarming

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionEyebrow("SPEECH ENGINE")
                    Spacer()
                    speechHeaderStatusPill
                }

                // Engine segmented toggle: WhisperKit (Local) vs Apple Speech
                HStack(spacing: 6) {
                    ForEach(SpeechEngine.allCases) { engine in
                        let selected = (selectedEngine == engine)
                        Button {
                            BuddyHaptics.selection()
                            modelManager.selectedSpeechEngine = engine
                            if engine == .appleSpeech {
                                Task { @MainActor in
                                    await whisperService.unloadAndWait()
                                }
                            }
                        } label: {
                            Text(engine.displayName)
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

                Text(selectedEngine.subtitle)
                    .font(.caption)
                    .foregroundStyle(BuddyTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(BuddyTheme.hairlineBorder)

                if selectedEngine == .whisperKit {
                    whisperModelSection(isBusy: isWhisperBusy)
                } else {
                    appleSpeechSection
                }
            }
        }
    }

    @ViewBuilder
    private var speechHeaderStatusPill: some View {
        if modelManager.selectedSpeechEngine == .whisperKit {
            if modelManager.isWhisperDownloaded {
                statusDotPill(
                    text: modelManager.isPrewarmed(modelManager.selectedWhisperPreset) ? "ANE Ready" : "Downloaded",
                    color: BuddyTheme.emeraldLive
                )
            } else {
                statusDotPill(text: "Download Needed", color: BuddyTheme.amberStreak)
            }
        } else {
            let mode = modelManager.selectedAppleSpeechMode
            let availability = appleSpeechService.checkAvailability(
                for: modelManager.selectedAppleSpeechLocale,
                mode: mode
            )
            let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)
            let readyPillText: String = {
                if isDenied { return "Permission Off" }
                if !availability.isReady { return "Setup Needed" }
                return mode == .offlineOnly ? "Offline Ready" : "Ready"
            }()
            statusDotPill(
                text: readyPillText,
                color: (isDenied || !availability.isReady) ? BuddyTheme.amberStreak : BuddyTheme.emeraldLive
            )
        }
    }

    @ViewBuilder
    private func whisperModelSection(isBusy: Bool) -> some View {
        let selectedPreset = modelManager.selectedWhisperPreset
        let isDownloaded = modelManager.isWhisperDownloaded
        let isPrewarmed = modelManager.isPrewarmed(selectedPreset)

        VStack(spacing: 8) {
            ForEach(whisperPresets, id: \.self) { preset in
                let isSelected = (selectedPreset == preset)
                let presetDownloaded = modelManager.isDownloaded(preset)
                Button {
                    guard !isBusy else { return }
                    BuddyHaptics.selection()
                    manualOptimizeError = nil
                    let changed = (modelManager.selectedWhisperPreset != preset)
                    modelManager.selectedWhisperPreset = preset
                    modelManager.refreshDownloadState()
                    if changed {
                        Task { @MainActor in
                            await whisperService.unloadAndWait()
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? BuddyTheme.inkPrimary : BuddyTheme.mutedText)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(preset.displayName)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                if presetDownloaded {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(BuddyTheme.emeraldLive)
                                }
                            }

                            Text(preset.subtitle)
                                .font(.caption)
                                .foregroundStyle(BuddyTheme.mutedText)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 4)

                        Text(formatSizeMB(preset.approximateSizeMB))
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(BuddyTheme.mutedText)
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
                .disabled(isBusy)
            }
        }

        if modelManager.isLowRAMDeviceForLargeWhisper && selectedPreset.isLargeModel {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BuddyTheme.amberStreak)
                    .padding(.top, 1)
                Text("This device has ~\(Int(modelManager.deviceRAMGB.rounded())) GB RAM. Whisper Small (217 MB) is recommended on SideStore builds to avoid iOS memory termination.")
                    .font(.caption)
                    .foregroundStyle(BuddyTheme.amberStreak)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(BuddyTheme.elevatedSurface)
            )
        }

        if isBusy {
            let isStandalonePrewarm = whisperService.isPrewarming
                && !modelManager.isDownloadingWhisper
                && !modelManager.isOptimizingWhisper
            let statusText: String = {
                if !modelManager.whisperDownloadStatusText.isEmpty {
                    return modelManager.whisperDownloadStatusText
                }
                if whisperService.isPrewarming {
                    return "Optimizing \(selectedPreset.shortDisplayName) for Neural Engine (one-time)…"
                }
                return "Preparing \(selectedPreset.shortDisplayName)…"
            }()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if isStandalonePrewarm {
                        ProgressView()
                            .controlSize(.small)
                            .tint(BuddyTheme.inkPrimary)
                    }
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    if !isStandalonePrewarm {
                        Text("\(Int((min(max(modelManager.whisperDownloadProgress, 0), 1) * 100).rounded()))%")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary)
                    }
                }

                if !isStandalonePrewarm {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BuddyTheme.elevatedSurface)
                            Capsule()
                                .fill(BuddyTheme.inkPrimary)
                                .frame(width: max(8, proxy.size.width * min(max(modelManager.whisperDownloadProgress, 0), 1)))
                        }
                    }
                    .frame(height: 6)
                }

                Button {
                    BuddyHaptics.lightImpact()
                    modelManager.cancelWhisperDownload()
                    whisperService.cancelInFlightWork()
                } label: {
                    Text(modelManager.isDownloadingWhisper ? "Cancel Download" : "Cancel Optimization")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BuddyTheme.destructive)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(BuddyTheme.destructive.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        } else if isDownloaded {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BuddyTheme.emeraldLive)
                    Text(isPrewarmed ? "Ready offline · Neural Engine cached" : "Ready offline")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }
                Spacer()
                if !isPrewarmed {
                    Button {
                        BuddyHaptics.lightImpact()
                        manualOptimizeError = nil
                        Task { @MainActor in
                            do {
                                try await whisperService.prewarmDownloadedModel(selectedPreset)
                            } catch is CancellationError {
                                // User cancelled optimization cleanly.
                            } catch {
                                manualOptimizeError = "Neural Engine optimization failed: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Text("Optimize")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(BuddyTheme.chipSurface))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    BuddyHaptics.warning()
                    manualOptimizeError = nil
                    Task { @MainActor in
                        await whisperService.unloadAndWait()
                        modelManager.deleteWhisperModel(selectedPreset)
                    }
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
        } else {
            Button {
                BuddyHaptics.mediumImpact()
                manualOptimizeError = nil
                Task { @MainActor in
                    await modelManager.downloadWhisperModel(selectedPreset) { downloadedPreset in
                        try await whisperService.prewarmDownloadedModel(downloadedPreset)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Download & Optimize (\(formatSizeMB(selectedPreset.approximateSizeMB)))")
                        .font(.system(size: 13.5, weight: .bold))
                }
                .foregroundStyle(BuddyTheme.inkInverse)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(BuddyTheme.inkPrimary))
            }
            .buttonStyle(.plain)
        }

        if let error = modelManager.whisperError ?? manualOptimizeError {
            Text(error)
                .font(.caption)
                .foregroundStyle(BuddyTheme.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("Memory-Safe Mode: Buddy automatically swaps Whisper & Qwen so only one model uses RAM at a time, and uses Instant Parser for clean sets to keep Whisper fast.")
            .font(.caption)
            .foregroundStyle(BuddyTheme.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var appleSpeechSection: some View {
        let mode = modelManager.selectedAppleSpeechMode
        let availability = appleSpeechService.checkAvailability(
            for: modelManager.selectedAppleSpeechLocale,
            mode: mode
        )
        let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)

        VStack(alignment: .leading, spacing: 8) {
            Text("Recognition Mode")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)

            HStack(spacing: 6) {
                ForEach(AppleSpeechRecognitionMode.allCases) { option in
                    let selected = (mode == option)
                    Button {
                        BuddyHaptics.selection()
                        modelManager.selectedAppleSpeechMode = option
                    } label: {
                        Text(option.displayName)
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

            Text(mode.subtitle)
                .font(.caption)
                .foregroundStyle(BuddyTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider().overlay(BuddyTheme.hairlineBorder)

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

    private var gymAudioCard: some View {
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 11) {
                sectionEyebrow("GYM AUDIO CAPTURE")

                Toggle(
                    isOn: Binding(
                        get: { modelManager.enableGymNoiseIsolation },
                        set: { newValue in
                            BuddyHaptics.selection()
                            modelManager.enableGymNoiseIsolation = newValue
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gym Noise Isolation")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Text("Apple hardware voice processing suppresses loud gym music and clanks for both WhisperKit and Apple Speech.")
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(BuddyTheme.emeraldLive)

                Divider().overlay(BuddyTheme.hairlineBorder)

                Toggle(
                    isOn: Binding(
                        get: { modelManager.preferBuiltInMic },
                        set: { newValue in
                            BuddyHaptics.selection()
                            modelManager.preferBuiltInMic = newValue
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prefer iPhone Mic")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Text("Keeps AirPods in stereo music mode and records from iPhone's close-talk mic instead of low-bitrate Bluetooth call audio.")
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(BuddyTheme.emeraldLive)
            }
        }
    }

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
                            Task { @MainActor in
                                await llmService.unloadAndWait()
                                modelManager.deleteLLMModel(selected)
                            }
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

                if let error = modelManager.llmError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundStyle(importIsError ? BuddyTheme.destructive : BuddyTheme.emeraldLive)
                }

                Text("Buddy uses the zero-latency Instant Parser automatically whenever no LLM is downloaded or when WhisperKit outputs a clean workout log.")
                    .font(.caption)
                    .foregroundStyle(BuddyTheme.mutedText)
            }
        }
    }

    private var runtimeCard: some View {
        let usingWhisper = (modelManager.effectiveSpeechEngine == .whisperKit)
        let mode = modelManager.selectedAppleSpeechMode
        let isDenied = (appleSpeechService.authorizationStatus == .denied || appleSpeechService.authorizationStatus == .restricted)
        let availability = appleSpeechService.checkAvailability(
            for: modelManager.selectedAppleSpeechLocale,
            mode: mode
        )
        let speechColor: Color = usingWhisper
            ? BuddyTheme.emeraldLive
            : ((isDenied || !availability.isReady) ? BuddyTheme.amberStreak : BuddyTheme.emeraldLive)
        let speechLabel: String = {
            if usingWhisper {
                return modelManager.selectedWhisperPreset.shortDisplayName
            }
            if isDenied { return "Permission Needed" }
            return !availability.isReady ? "Setup Needed" : "Apple \(mode.shortLabel)"
        }()

        let anyModelLoaded = whisperService.isLoaded || llmService.isLoaded
        let memoryNotices = [whisperService.lastMemoryNotice, llmService.lastMemoryNotice]
            .compactMap { notice -> String? in
                guard let notice, !notice.isEmpty else { return nil }
                return notice
            }

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                sectionEyebrow("MEMORY & RUNTIME")

                HStack {
                    Text("Active Speech")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    statusDotPill(text: speechLabel, color: speechColor)
                }

                Divider().overlay(BuddyTheme.hairlineBorder)

                HStack {
                    Text("Whisper Runtime")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    runtimeBadge(
                        isLoaded: whisperService.isLoaded,
                        isLoading: whisperService.isLoading || whisperService.isPrewarming,
                        label: whisperService.loadedVariantName
                    )
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

                ForEach(memoryNotices, id: \.self) { notice in
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(BuddyTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if anyModelLoaded {
                    Button {
                        BuddyHaptics.lightImpact()
                        Task { @MainActor in
                            await llmService.unloadAndWait()
                            await whisperService.unloadAndWait()
                            llmService.lastMemoryNotice = nil
                            whisperService.lastMemoryNotice = nil
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Free Model Memory")
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

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(BuddyTheme.mutedText)
    }

    private func statusDotPill(text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6.5, height: 6.5)
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

    @ViewBuilder
    private func runtimeBadge(isLoaded: Bool, isLoading: Bool, label: String?) -> some View {
        if isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(BuddyTheme.inkPrimary)
                Text("Loading…").font(.caption).foregroundStyle(BuddyTheme.mutedText)
            }
        } else if isLoaded {
            statusDotPill(text: label ?? "Loaded", color: BuddyTheme.emeraldLive)
        } else {
            Text("Standby").font(.caption.weight(.medium)).foregroundStyle(BuddyTheme.mutedText)
        }
    }

    private func handleGGUFImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
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

// MARK: - Sub-Page: SideStore & Diagnostics

private struct DiagnosticsSettingsView: View {
    let store: WorkoutStore
    @State private var widgetRefreshNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NativeCard(padding: 15, cornerRadius: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SIDESTORE & WIDGET SYNC")
                            .font(.system(size: 10.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(BuddyTheme.mutedText)

                        keyValueRow(title: "App Group", value: AppGroupResolver.diagnosticSummary)
                        Divider().overlay(BuddyTheme.hairlineBorder)
                        keyValueRow(title: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "com.yuvaraja.buddy")
                        Divider().overlay(BuddyTheme.hairlineBorder)
                        keyValueRow(title: "Active App IDs", value: "2 (App + Widgets)")

                        Button {
                            BuddyHaptics.success()
                            WidgetRefreshHelper.sync(store: store)
                            widgetRefreshNote = "Widgets refreshed at \(Date().formatted(date: .omitted, time: .standard))"
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12.5, weight: .bold))
                                Text("Refresh Widgets Now")
                                    .font(.system(size: 13.5, weight: .bold))
                            }
                            .foregroundStyle(BuddyTheme.inkInverse)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(BuddyTheme.inkPrimary))
                        }
                        .buttonStyle(.plain)

                        if let widgetRefreshNote {
                            Text(widgetRefreshNote)
                                .font(.caption)
                                .foregroundStyle(BuddyTheme.emeraldLive)
                        }

                        Text("App Groups resolve dynamically from embedded provisioning metadata so widgets stay synced after SideStore re-signing.")
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(BuddyTheme.canvasBackground.ignoresSafeArea())
        .navigationTitle("SideStore & Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
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
}
