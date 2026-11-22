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
    let appleSpeechService: AppleSpeechService
    let whisperService: WhisperTranscriptionService
    let llmService: LocalLLMService

    @State private var selectedTab: BuddyTab = .workout
    @State private var showModelSetup: Bool = false
    @State private var didHandleDeepLinkOnLaunch: Bool = false
    @State private var dismissWorkoutSheetsToken: Int = 0
    @AppStorage("buddy.hasSeenOnboarding") private var hasSeenOnboarding: Bool = false

    var body: some View {
        TabView(selection: $selectedTab) {
            WorkoutHomeView(
                store: store,
                pipeline: pipeline,
                modelManager: modelManager,
                appleSpeechService: appleSpeechService,
                whisperService: whisperService,
                llmService: llmService,
                dismissSheetsToken: dismissWorkoutSheetsToken
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
            if !didHandleDeepLinkOnLaunch && !hasSeenOnboarding && !modelManager.isAllDownloaded {
                hasSeenOnboarding = true
                showModelSetup = true
            }
        }
        .sheet(isPresented: $showModelSetup) {
            ModelSetupSheet(
                modelManager: modelManager,
                appleSpeechService: appleSpeechService
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let deepLink = DeepLink(url: url) else { return }
        didHandleDeepLinkOnLaunch = true

        switch deepLink {
        case .record:
            showModelSetup = false
            dismissWorkoutSheetsToken &+= 1
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
            showModelSetup = false
            selectedTab = .workout

        case .trends:
            showModelSetup = false
            selectedTab = .trends

        case .coach:
            showModelSetup = false
            selectedTab = .coach
        }
    }
}
