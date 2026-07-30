import Foundation

public actor HybridLocalIntelligenceProvider: LocalIntelligenceProviding {
    private let primary: any LocalIntelligenceProviding
    private let fallback: any PromptResponseGenerating
    private var consecutivePrimaryFailures = 0
    private var primaryCooldownUntil: Date?
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

    public func prewarmPrompt(conversationID: UUID) async {
        await primary.prewarmPrompt(conversationID: conversationID)
    }

    public func discardPromptCaches() async {
        await primary.discardPromptCaches()
        await fallback.discardPromptCaches()
    }

    public func generatePromptDisposition(
        _ request: PromptGenerationRequest
    ) async throws -> PromptGenerationDisposition {
        if primaryCooldownUntil.map({ $0 <= Date() }) == true {
            primaryCooldownUntil = nil
            consecutivePrimaryFailures = 0
        }
        if primaryCooldownUntil == nil, request.contextScope != .corpusWide {
            do {
                let response = try await Self.withTimeout(.seconds(6)) {
                    try await self.primary.generatePromptDisposition(request)
                }
                consecutivePrimaryFailures = 0
                lastSuccessfulBackend = .appleFoundationModel
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                consecutivePrimaryFailures += 1
                if ContextEngineeringFeatureFlags.backendCircuitBreaker,
                   consecutivePrimaryFailures >= 2 {
                    primaryCooldownUntil = Date().addingTimeInterval(60)
                }
            }
        }
        do {
            let response = try await Self.withTimeout(.seconds(30)) {
                try await self.fallback.generatePromptDisposition(request)
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
