import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels

@Generable
private enum AppleRoutedIntent {
    case direct
    case prompt
    case uncertain
}

@Generable
private enum ApplePromptContextScope {
    case focused
    case retrieved
    case corpusWide
}

@Generable
private struct AppleIntentDecisionOutput {
    @Guide(description: "The routing decision")
    var intent: AppleRoutedIntent

    @Guide(description: "Confidence from zero to one")
    var confidence: Double

    @Guide(description: "focused for the active field, retrieved for bounded history search, corpusWide only for summaries across all documents")
    var contextScope: ApplePromptContextScope
}
#endif

public actor AppleVoiceIntentRouter: VoiceIntentRoutingProviding {
#if canImport(FoundationModels)
    private var sessions: [UUID: LanguageModelSession] = [:]
#endif

    public init() {}

    public func isAvailable() -> Bool {
#if canImport(FoundationModels)
        SystemLanguageModel.default.availability == .available
#else
        false
#endif
    }

    public func setEnabled(_ enabled: Bool) {
        if !enabled {
#if canImport(FoundationModels)
            sessions.removeAll()
#endif
        }
    }

    public func prepare(
        sessionID: UUID,
        context: IntentRoutingContext
    ) {
#if canImport(FoundationModels)
        guard isAvailable() else { return }
        let session = makeSession()
        sessions[sessionID] = session
        session.prewarm()
#endif
    }

    public func classify(
        _ request: IntentRoutingRequest,
        sessionID: UUID
    ) async throws -> IntentDecision {
#if canImport(FoundationModels)
        guard isAvailable() else {
            throw CurrentError.modelUnavailable(
                "Apple Intelligence intent routing is unavailable."
            )
        }
        let session = sessions.removeValue(forKey: sessionID) ?? makeSession()
        let response = try await session.respond(
            to: Self.prompt(request),
            generating: AppleIntentDecisionOutput.self,
            options: GenerationOptions(
                temperature: 0,
                maximumResponseTokens: 32
            )
        ).content
        try Task.checkCancellation()
        let intent: VoiceIntent = switch response.intent {
        case .direct: .direct
        case .prompt: .prompt
        case .uncertain: .uncertain
        }
        let scope: PromptContextScope = switch response.contextScope {
        case .focused: .focused
        case .retrieved: .retrieved
        case .corpusWide: .corpusWide
        }
        return IntentDecision(
            intent: intent,
            confidence: response.confidence,
            contextScope: intent == .prompt ? scope : .focused
        )
#else
        throw CurrentError.modelUnavailable(
            "Apple Intelligence intent routing is unavailable."
        )
#endif
    }

    public func cancel(sessionID: UUID) {
#if canImport(FoundationModels)
        sessions.removeValue(forKey: sessionID)
#endif
    }

#if canImport(FoundationModels)
    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            instructions: """
            Route one spoken interaction for a universal Mac dictation app.
            Choose direct when the speaker intends the transcript itself to be typed.
            Choose prompt when the speaker asks Current to create, transform, answer,
            summarize, translate, or otherwise produce text. Account for speech
            recognition errors and the focused-field context. Choose uncertain only
            when the intended action genuinely cannot be determined.

            Examples:
            - "Draft an email" and "Draft and email" are prompt.
            - "Please write a proper response here" is prompt.
            - "The draft and email are ready" is direct.
            - "Type the words draft an email" is direct.
            - Equivalent commands in other languages are prompt.
            Return only the generated structured decision.
            Use focused for transformations of selected or nearby text, retrieved for
            references to prior messages or facts, and corpusWide only for requests to
            summarize or compare the entire context-document collection.
            """
        )
    }
#endif

    private nonisolated static func prompt(
        _ request: IntentRoutingRequest
    ) -> String {
        let context = request.context
        return """
        Spoken transcript: \(request.transcript)
        Destination: \(context.destination.rawValue)
        Application: \(context.applicationName ?? "")
        Window: \(context.windowTitle ?? "")
        Focused role: \(context.focusedRole ?? "")
        Focused subrole: \(context.focusedSubrole ?? "")
        Has selection: \(context.hasSelection)
        Selection excerpt: \(context.selectionExcerpt)
        Text before cursor: \(context.textBeforeCursor)
        Text after cursor: \(context.textAfterCursor)
        """
    }
}

public actor HybridVoiceIntentRouter: VoiceIntentRoutingProviding {
    private enum Timeout: Error { case elapsed }

    private let primary: any VoiceIntentRoutingProviding
    private let fallback: any VoiceIntentRoutingProviding
    private let clock = ContinuousClock()
    private let signposter = OSSignposter(
        subsystem: "com.emilianscheel.current",
        category: "VoiceIntentRouting"
    )
    public private(set) var diagnostics = IntentRoutingDiagnostics(
        backend: nil,
        durationMilliseconds: 0,
        intent: nil
    )

    public init(
        primary: any VoiceIntentRoutingProviding,
        fallback: any VoiceIntentRoutingProviding
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func isAvailable() async -> Bool {
        let primaryAvailable = await primary.isAvailable()
        if primaryAvailable { return true }
        return await fallback.isAvailable()
    }

    public func setEnabled(_ enabled: Bool) async {
        await primary.setEnabled(enabled)
        if enabled, !(await primary.isAvailable()) {
            await fallback.setEnabled(true)
        } else {
            await fallback.setEnabled(false)
        }
    }

    public func prepare(
        sessionID: UUID,
        context: IntentRoutingContext
    ) async {
        let primaryAvailable = await primary.isAvailable()
        await fallback.setEnabled(!primaryAvailable)
        await primary.prepare(sessionID: sessionID, context: context)
        if !primaryAvailable {
            await fallback.prepare(sessionID: sessionID, context: context)
        }
    }

    public func classify(
        _ request: IntentRoutingRequest,
        sessionID: UUID
    ) async throws -> IntentDecision {
        let interval = signposter.beginInterval("Intent classification")
        defer { signposter.endInterval("Intent classification", interval) }
        let start = clock.now
        do {
            let decision = try await Self.withTimeout(.seconds(2)) {
                try await self.primary.classify(request, sessionID: sessionID)
            }
            if decision.intent != .uncertain {
                record(
                    backend: .appleFoundationModel,
                    decision: decision,
                    startedAt: start
                )
                return decision
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
        }

        do {
            let decision = try await Self.withTimeout(.seconds(3)) {
                try await self.fallback.classify(request, sessionID: sessionID)
            }
            guard decision.intent != .uncertain else {
                throw CurrentError.intentClassificationFailed(
                    "Both local models were uncertain."
                )
            }
            record(backend: .gemma4, decision: decision, startedAt: start)
            return decision
        } catch is CancellationError {
            throw CancellationError()
        } catch Timeout.elapsed {
            recordFailure(startedAt: start, timedOut: true)
            throw CurrentError.intentClassificationFailed(
                "Gemma intent routing timed out."
            )
        } catch let error as CurrentError {
            if Task.isCancelled { throw CancellationError() }
            recordFailure(startedAt: start)
            if case .intentClassificationFailed = error { throw error }
            throw CurrentError.intentClassificationFailed(
                error.localizedDescription
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            recordFailure(startedAt: start)
            throw CurrentError.intentClassificationFailed(
                "Neither local model returned a valid decision."
            )
        }
    }

    public func cancel(sessionID: UUID) async {
        await primary.cancel(sessionID: sessionID)
        await fallback.cancel(sessionID: sessionID)
    }

    private func record(
        backend: IntentRoutingBackend,
        decision: IntentDecision,
        startedAt: ContinuousClock.Instant
    ) {
        diagnostics = .init(
            backend: backend,
            durationMilliseconds: milliseconds(since: startedAt),
            intent: decision.intent
        )
    }

    private func recordFailure(
        startedAt: ContinuousClock.Instant,
        timedOut: Bool = false
    ) {
        diagnostics = .init(
            backend: nil,
            durationMilliseconds: milliseconds(since: startedAt),
            intent: nil,
            timedOut: timedOut
        )
    }

    private func milliseconds(
        since start: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: clock.now).components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    private nonisolated static func withTimeout<Value: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw Timeout.elapsed
            }
            guard let result = try await group.next() else {
                throw Timeout.elapsed
            }
            group.cancelAll()
            return result
        }
    }
}
