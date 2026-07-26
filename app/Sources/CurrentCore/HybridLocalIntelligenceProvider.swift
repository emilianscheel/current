import Foundation

public actor HybridLocalIntelligenceProvider: LocalIntelligenceProviding {
    private let primary: any LocalIntelligenceProviding
    private let fallback: any PromptResponseGenerating
    public private(set) var lastSuccessfulBackend: PromptGenerationBackend?

    public init(
        primary: any LocalIntelligenceProviding,
        fallback: any PromptResponseGenerating
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func refineDictation(
        _ deterministic: RefinementResult,
        context: DictationContext
    ) async -> RefinementResult {
        await primary.refineDictation(deterministic, context: context)
    }

    public func generatePromptDisposition(
        _ envelope: PromptContextEnvelope
    ) async throws -> PromptGenerationDisposition {
        do {
            let response = try await Self.withTimeout(.seconds(20)) {
                try await self.primary.generatePromptDisposition(envelope)
            }
            lastSuccessfulBackend = .appleFoundationModel
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
        }
        do {
            let response = try await Self.withTimeout(.seconds(45)) {
                try await self.fallback.generatePromptDisposition(envelope)
            }
            lastSuccessfulBackend = .gemma4
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw CurrentError.promptGenerationFailed(
                "Apple Intelligence and Gemma could not generate a valid response."
            )
        }
    }

    private nonisolated static func withTimeout<Value: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CurrentError.promptGenerationFailed(
                    "The model response timed out."
                )
            }
            guard let result = try await group.next() else {
                throw CurrentError.promptGenerationFailed(
                    "The model returned no response."
                )
            }
            group.cancelAll()
            return result
        }
    }
}
