import Foundation

public actor LivePromptContextPreparer: PromptContextPreparing {
    private let repository: ContextRepository
    private let screenContext: any ScreenContextProviding
    private let conversationContext: ConversationContext?
    private var prefetchedObservation: ContextObservation?
    private var prefetchedTarget: ContextCaptureTarget?
    private var prefetchTask: Task<ContextObservation?, Never>?
    private var prefetchGeneration = UUID()

    public init(
        repository: ContextRepository,
        screenContext: any ScreenContextProviding,
        conversationContext: ConversationContext? = nil
    ) {
        self.repository = repository
        self.screenContext = screenContext
        self.conversationContext = conversationContext
    }

    public func prefetch(
        focusedContext: DictationContext,
        target: ContextCaptureTarget?,
        continuousContextEnabled: Bool
    ) async {
        guard ContextEngineeringFeatureFlags.recordingTimeCapture,
              continuousContextEnabled, let target else { return }
        let generation = UUID()
        prefetchGeneration = generation
        prefetchedTarget = target
        let task = Task { [screenContext] in
            try? await screenContext.refreshForPrompt(target: target)
        }
        prefetchTask = task
        let observation = await task.value
        guard !Task.isCancelled, prefetchGeneration == generation else { return }
        prefetchTask = nil
        if let observation {
            prefetchedTarget = target
            prefetchedObservation = observation
            _ = await repository.acceptForPrompt(observation)
        }
    }

    public func prepare(
        instruction: String,
        focusedContext: DictationContext,
        target: ContextCaptureTarget?,
        continuousContextEnabled: Bool,
        scope: PromptContextScope
    ) async throws -> PromptContextEnvelope {
        let conversation = ContextEngineeringFeatureFlags.conversationLedger
            ? await conversationContext?.snapshot() : nil
        guard continuousContextEnabled, let target else {
            return await repository.promptContext(
                instruction: instruction,
                focusedContext: focusedContext,
                target: target,
                includeApplicationContext: false,
                conversation: conversation,
                scope: scope
            )
        }
        let fresh: ContextObservation?
        if prefetchedTarget == target {
            if let observation = prefetchedObservation,
               Date().timeIntervalSince(observation.capturedAt) <= 30 {
                fresh = observation
                prefetchedObservation = nil
                prefetchedTarget = nil
            } else if let prefetchTask {
                let completed = try await Self.withTimeout(.milliseconds(250)) {
                    await prefetchTask.value.map { [$0] } ?? []
                }
                fresh = completed?.first
                if completed != nil {
                    self.prefetchTask = nil
                    prefetchedTarget = nil
                }
            } else {
                fresh = nil
                prefetchedTarget = nil
            }
        } else {
            fresh = try await Self.withTimeout(.milliseconds(250)) {
                [try await self.screenContext.refreshForPrompt(target: target)]
                    .compactMap { $0 }
            }?.first
        }
        try Task.checkCancellation()
        if let fresh {
            _ = await repository.acceptForPrompt(fresh)
            await screenContext.recordActivity(.init(
                target: target,
                kind: .accessibility
            ))
        }
        return await repository.promptContext(
            instruction: instruction,
            focusedContext: focusedContext,
            target: target,
            freshObservation: fresh,
            conversation: conversation,
            scope: scope
        )
    }

    private nonisolated static func withTimeout<Value: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value? {
        try await withThrowingTaskGroup(of: Value?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
