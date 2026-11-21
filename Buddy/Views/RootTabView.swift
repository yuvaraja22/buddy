import SwiftUI

enum BuddyTab: Hashable {
    case workout
    case trends
    case coach
}

struct RootTabView: View {
    let store: WorkoutStore
    let pipeline: VoicePipelineCoordinator
    let modelManager: ModelManager
    let whisperService: WhisperTranscriptionService
    let llmService: LocalLLMService

    @State private var selectedTab: BuddyTab = .workout
    @State private var showModelSetup: Bool = false
    @AppStorage("buddy.hasSeenOnboarding") private var hasSeenOnboarding: Bool = false

    var body: some View {
        TabView(selection: $selectedTab) {
            WorkoutHomeView(
                store: store,
                pipeline: pipeline,
                modelManager: modelManager,
                whisperService: whisperService,
                llmService: llmService
            )
            .tabItem {
                Label("Workout", systemImage: "figure.strengthtraining.traditional")
            }
            .tag(BuddyTab.workout)

            TrendsView(store: store)
                .tabItem {
                    Label("Trends", systemImage: "chart.xyaxis.line")
                }
                .tag(BuddyTab.trends)

            CoachView(
                store: store,
                llmService: llmService,
                modelManager: modelManager,
                onOpenModelSetup: { showModelSetup = true }
            )
            .tabItem {
                Label("Coach", systemImage: "sparkles")
            }
            .tag(BuddyTab.coach)
        }
        .tint(BuddyTheme.cobalt)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .task {
            modelManager.refreshDownloadState()
            if !hasSeenOnboarding && !modelManager.isAllDownloaded {
                hasSeenOnboarding = true
                showModelSetup = true
            }
        }
        .sheet(isPresented: $showModelSetup) {
            ModelSetupSheet(modelManager: modelManager)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let deepLink = DeepLink(url: url) else { return }

        switch deepLink {
        case .record:
            showModelSetup = false
            selectedTab = .workout
            Task { @MainActor in
                switch pipeline.phase {
                case .idle:
                    BuddyHaptics.lightImpact()
                    pipeline.beginRecording(isHoldMode: false)
                case .error:
                    pipeline.dismissError()
                    BuddyHaptics.lightImpact()
                    pipeline.beginRecording(isHoldMode: false)
                case .recording, .transcribing, .parsing:
                    break
                }
            }

        case .session:
            selectedTab = .workout

        case .trends:
            selectedTab = .trends

        case .coach:
            selectedTab = .coach
        }
    }
}
