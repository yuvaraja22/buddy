import Foundation

/// Serializes heavy on-device model residency handoffs between Parakeet CoreML (local speech) and
/// LocalLLMService (Qwen GGUF) so both models can never pass pre-load checks simultaneously
/// or overlap in RAM on SideStore free Apple ID builds (no `increased-memory-limit` entitlement).
@MainActor
public final class ModelMemoryCoordinator {
    public enum ResidentModel: Equatable, Sendable {
        case none
        case localSpeech
        case llm
    }

    public private(set) var activeOwner: ResidentModel = .none
    private var isTransitioning: Bool = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Acquires exclusive ownership of the model-transition lock, awaits full teardown of the
    /// opposing model when switching owners, claims `owner`, and runs `operation`.
    ///
    /// Deadlock safety: `unloadOther` MUST only cancel/await the opposing model's active CoreML/GGUF
    /// work and MUST NEVER re-enter `ModelMemoryCoordinator`.
    public func runExclusiveLoad<T>(
        for owner: ResidentModel,
        unloadOther: @MainActor () async -> Void,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        await acquireTransitionLock()
        defer { releaseTransitionLock() }

        try Task.checkCancellation()

        if activeOwner != owner {
            await unloadOther()
            try Task.checkCancellation()
        }

        activeOwner = owner
        return try await operation()
    }

    public func markUnloaded(_ owner: ResidentModel) {
        if activeOwner == owner {
            activeOwner = .none
        }
    }

    private func acquireTransitionLock() async {
        while isTransitioning {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        isTransitioning = true
    }

    private func releaseTransitionLock() {
        isTransitioning = false
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
