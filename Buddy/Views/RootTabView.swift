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
    let llmService: LocalLLMService

    @State private var selectedTab: BuddyTab = .workout
    @State private var showModelSetup: Bool = false
    @State private var didHandleDeepLinkOnLaunch: Bool = false
    @State private var dismissWorkoutSheetsToken: Int = 0
    @AppStorage("buddy.hasSeenOnboarding") private var hasSeenOnboarding: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            BuddyTheme.canvasBackground
                .ignoresSafeArea()

            // Keep all three tabs mounted so scroll position and chat state persist across switches,
            // while replacing iOS's dated translucent TabView with Uber's floating bottom pill bar.
            ZStack {
                WorkoutHomeView(
                    store: store,
                    pipeline: pipeline,
                    modelManager: modelManager,
                    appleSpeechService: appleSpeechService,
                    llmService: llmService,
                    dismissSheetsToken: dismissWorkoutSheetsToken
                )
                .opacity(selectedTab == .workout ? 1 : 0)
                .allowsHitTesting(selectedTab == .workout)
                .accessibilityHidden(selectedTab != .workout)
                .zIndex(selectedTab == .workout ? 1 : 0)

                TrendsView(store: store)
                    .opacity(selectedTab == .trends ? 1 : 0)
                    .allowsHitTesting(selectedTab == .trends)
                    .accessibilityHidden(selectedTab != .trends)
                    .zIndex(selectedTab == .trends ? 1 : 0)

                CoachView(
                    store: store,
                    llmService: llmService,
                    modelManager: modelManager,
                    onOpenModelSetup: { showModelSetup = true }
                )
                .opacity(selectedTab == .coach ? 1 : 0)
                .allowsHitTesting(selectedTab == .coach)
                .accessibilityHidden(selectedTab != .coach)
                .zIndex(selectedTab == .coach ? 1 : 0)
            }

            // Pinned Uber-style floating pill bar + persistent Mic FAB.
            // Ignores keyboard avoidance so keyboards glide cleanly over the bottom nav while
            // text input bars (Workout command bar / Coach composer) remain above the keyboard.
            VStack(spacing: 0) {
                VoiceRecordDock(
                    selectedTab: $selectedTab,
                    pipeline: pipeline,
                    store: store,
                    onVoiceRecordingBegan: {
                        if selectedTab != .workout {
                            selectedTab = .workout
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .zIndex(10)
        }
        .tint(BuddyTheme.inkPrimary)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .task {
            modelManager.refreshDownloadState()
            appleSpeechService.refreshAuthorizationStatus()
            let appleSpeechReady = appleSpeechService.isReadyForOfflineVoice(for: modelManager.selectedAppleSpeechLocale)
            if !didHandleDeepLinkOnLaunch && !hasSeenOnboarding && !modelManager.isAllReady(appleSpeechReady: appleSpeechReady) {
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
