import SwiftUI
import SwiftData
import WidgetKit

@main
struct BuddyApp: App {
    private let modelContainer: ModelContainer

    @State private var modelManager: ModelManager
    @State private var audioRecorder: AudioRecorderService
    @State private var whisperService: WhisperTranscriptionService
    @State private var llmService: LocalLLMService
    @State private var pipeline: VoicePipelineCoordinator
    @State private var workoutStore: WorkoutStore

    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    init() {
        let container = Self.makeModelContainer()
        self.modelContainer = container

        let manager = ModelManager()
        let recorder = AudioRecorderService()
        let whisper = WhisperTranscriptionService(modelManager: manager)
        let llm = LocalLLMService(modelManager: manager)
        let coordinator = VoicePipelineCoordinator(
            audioRecorder: recorder,
            whisperService: whisper,
            llmService: llm,
            modelManager: manager
        )
        let store = WorkoutStore(modelContext: container.mainContext)

        _modelManager = State(initialValue: manager)
        _audioRecorder = State(initialValue: recorder)
        _whisperService = State(initialValue: whisper)
        _llmService = State(initialValue: llm)
        _pipeline = State(initialValue: coordinator)
        _workoutStore = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                store: workoutStore,
                pipeline: pipeline,
                modelManager: modelManager,
                whisperService: whisperService,
                llmService: llmService
            )
            .tint(BuddyTheme.cobalt)
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                if audioRecorder.isRecording {
                    pipeline.cancelRecording()
                }
                WidgetRefreshHelper.sync(store: workoutStore)
            case .active:
                modelManager.refreshDownloadState()
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
