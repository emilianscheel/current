import Foundation

public actor LivePromptContextPreparer: PromptContextPreparing {
    private let repository: ContextRepository
    private let screenContext: any ScreenContextProviding

    public init(
        repository: ContextRepository,
        screenContext: any ScreenContextProviding
    ) {
        self.repository = repository
        self.screenContext = screenContext
    }

    public func prepare(
        instruction: String,
        focusedContext: DictationContext,
        target: ContextCaptureTarget?,
        continuousContextEnabled: Bool
    ) async throws -> PromptContextEnvelope {
        guard continuousContextEnabled, let target else {
            return await repository.promptContext(
                instruction: instruction,
                focusedContext: focusedContext,
                target: target,
                includeApplicationContext: false
            )
        }
        let fresh = try await screenContext.refreshForPrompt(target: target)
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
            freshObservation: fresh
        )
    }
}
