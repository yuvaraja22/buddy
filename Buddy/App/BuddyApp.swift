import SwiftUI
import SwiftData
import WidgetKit

@main
struct BuddyApp: App {
    private let modelContainer: ModelContainer

    @State private var modelManager: ModelManager
    @State private var audioRecorder: AudioRecorderService
    @State private var appleSpeechService: AppleSpeechService
    @State private var whisperService: WhisperTranscriptionService
    @State private var llmService: LocalLLMService
    @State private var pipeline: VoicePipelineCoordinator
    @State private var workoutStore: WorkoutStore
    @State private var cloudSync: FirebaseSyncService

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("buddy.preferences.appearance") private var appearanceRaw: String = BuddyAppearance.dark.rawValue

    private var preferredAppearance: BuddyAppearance {
        BuddyAppearance(rawValue: appearanceRaw) ?? .dark
    }

    @MainActor
    init() {
        let container = Self.makeModelContainer()
        self.modelContainer = container

        let manager = ModelManager()
        let recorder = AudioRecorderService()
        let appleSpeech = AppleSpeechService()
        let whisper = WhisperTranscriptionService(modelManager: manager)
        let llm = LocalLLMService(modelManager: manager)

        // Strict mutual RAM exclusion: Whisper Large v3 Turbo and Qwen LLM never occupy RAM
        // simultaneously, keeping peak footprint safely under SideStore's iOS Jetsam ceiling.
        whisper.onBeforeLoadModel = { [weak llm] in
            guard let llm, llm.isLoaded || llm.isLoading else { return }
            llm.unload()
            try? await Task.sleep(for: .milliseconds(150))
        }
        llm.onBeforeLoadModel = { [weak whisper] in
            guard let whisper, whisper.isLoaded || whisper.isLoading || whisper.isPrewarming else { return }
            await whisper.unload()
            try? await Task.sleep(for: .milliseconds(150))
        }

        let coordinator = VoicePipelineCoordinator(
            audioRecorder: recorder,
            appleSpeechService: appleSpeech,
            whisperService: whisper,
            llmService: llm,
            modelManager: manager
        )
        let store = WorkoutStore(modelContext: container.mainContext)
        let sync = FirebaseSyncService()
        store.onDataMutated = { [weak sync, weak store] in
            guard let sync, let store else { return }
            sync.scheduleAutoSync(for: store)
        }
        coordinator.attachStore(store)

        _modelManager = State(initialValue: manager)
        _audioRecorder = State(initialValue: recorder)
        _appleSpeechService = State(initialValue: appleSpeech)
        _whisperService = State(initialValue: whisper)
        _llmService = State(initialValue: llm)
        _pipeline = State(initialValue: coordinator)
        _workoutStore = State(initialValue: store)
        _cloudSync = State(initialValue: sync)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                store: workoutStore,
                pipeline: pipeline,
                modelManager: modelManager,
                appleSpeechService: appleSpeechService,
                whisperService: whisperService,
                llmService: llmService,
                cloudSync: cloudSync
            )
            .tint(BuddyTheme.inkPrimary)
            .preferredColorScheme(preferredAppearance.colorScheme)
            .onAppear {
                BuddyAppearance.applyToAllWindows(preferredAppearance)
            }
            .onChange(of: appearanceRaw) { _, _ in
                BuddyAppearance.applyToAllWindows(preferredAppearance)
            }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                pipeline.handleEnteredBackground(store: workoutStore)
                llmService.stopCoachGeneration()
                llmService.unload()
                Task { @MainActor in
                    await whisperService.unloadIfIdle()
                }
                WidgetRefreshHelper.sync(store: workoutStore)
            case .active:
                BuddyAppearance.applyToAllWindows(preferredAppearance)
                modelManager.refreshDownloadState()
                appleSpeechService.refreshAuthorizationStatus()
                pipeline.resumePendingWorkIfNeeded(into: workoutStore)
                cloudSync.syncOnForegroundIfNeeded(store: workoutStore)
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            WorkoutSession.self,
            ExerciseEntry.self,
            LoggedSet.self,
            CoachMessage.self
        ])

        let storeURL = AppGroupResolver.sharedContainerURL.appendingPathComponent("Buddy.store")
        let sharedConfig = ModelConfiguration(
            "Buddy",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        if let container = try? ModelContainer(for: schema, configurations: [sharedConfig]) {
            return container
        }

        if let fallback = try? ModelContainer(for: schema) {
            return fallback
        }

        let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [inMemoryConfig])
        } catch {
            fatalError("Failed to initialize Buddy SwiftData ModelContainer: \(error)")
        }
    }
}

/// Builds and persists a fresh `WidgetSnapshot` from the current `WorkoutStore`
/// and triggers WidgetKit timeline reloads across home/lock screen widgets.
@MainActor
enum WidgetRefreshHelper {
    static func sync(store: WorkoutStore, referenceDate: Date = Date()) {
        store.syncWidgetsAndLiveActivity()
    }
}
