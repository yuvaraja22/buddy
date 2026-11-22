import SwiftUI
import UIKit

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
    @State private var voiceDockHeight: CGFloat = 78
    @AppStorage("buddy.hasSeenOnboarding") private var hasSeenOnboarding: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            BuddyTheme.canvasBackground
                .ignoresSafeArea()

            // Keep all three tabs mounted so scroll position and chat state persist across switches,
            // while replacing iOS's dated translucent TabView with Uber's floating bottom pill bar.
            // Tab-active state and `.onChange(of: selectedTab)` handle keyboard dismissal, Coach LLM
            // cancellation, and pausing hidden 1 Hz timers cleanly.
            ZStack {
                WorkoutHomeView(
                    store: store,
                    pipeline: pipeline,
                    modelManager: modelManager,
                    appleSpeechService: appleSpeechService,
                    llmService: llmService,
                    isTabActive: selectedTab == .workout,
                    dockClearance: voiceDockHeight,
                    dismissSheetsToken: dismissWorkoutSheetsToken
                )
                .opacity(selectedTab == .workout ? 1 : 0)
                .allowsHitTesting(selectedTab == .workout)
                .accessibilityHidden(selectedTab != .workout)
                .zIndex(selectedTab == .workout ? 1 : 0)

                TrendsView(
                    store: store,
                    dockClearance: voiceDockHeight
                )
                .opacity(selectedTab == .trends ? 1 : 0)
                .allowsHitTesting(selectedTab == .trends)
                .accessibilityHidden(selectedTab != .trends)
                .zIndex(selectedTab == .trends ? 1 : 0)

                CoachView(
                    store: store,
                    llmService: llmService,
                    modelManager: modelManager,
                    isTabActive: selectedTab == .coach,
                    dockClearance: voiceDockHeight,
                    onOpenModelSetup: { showModelSetup = true }
                )
                .opacity(selectedTab == .coach ? 1 : 0)
                .allowsHitTesting(selectedTab == .coach)
                .accessibilityHidden(selectedTab != .coach)
                .zIndex(selectedTab == .coach ? 1 : 0)
            }

            // Pinned Uber-style floating pill bar + persistent Mic FAB.
            // Measures its live rendered height (including error pills) via VoiceDockHeightKey so
            // CoachView's composer and WorkoutHomeView's toast never overlap the dock.
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
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: VoiceDockHeightKey.self, value: proxy.size.height)
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .zIndex(10)
        }
        .onPreferenceChange(VoiceDockHeightKey.self) { measuredHeight in
            if measuredHeight > 0 {
                voiceDockHeight = measuredHeight
            }
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            guard oldTab != newTab else { return }
            // Resign any active TextField keyboard when switching tabs so it never lingers over Trends.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            // Free LocalLLMService's exclusive lock immediately if leaving Coach mid-generation.
            if oldTab == .coach {
                llmService.stopCoachGeneration()
            }
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
            .buddyAppearance()
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
