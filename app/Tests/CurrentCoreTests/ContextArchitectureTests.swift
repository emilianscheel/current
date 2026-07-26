import Foundation
import CoreGraphics
import Testing
@testable import CurrentCore

private let modelRoutingCorpus: [(String, VoiceIntent)] = [
    ("Draft an email", .prompt),
    ("Draft and email", .prompt),
    ("Please write a proper response here", .prompt),
    ("Schreib eine höfliche Antwort", .prompt),
    ("The draft and email are ready", .direct),
    ("Type the words draft an email", .direct),
]

private actor StubIntelligence:
    LocalIntelligenceProviding,
    ContextStructuringProviding
{
    private(set) var updateCalls = 0

    func refineDictation(
        _ deterministic: RefinementResult,
        context: DictationContext
    ) async -> RefinementResult {
        deterministic
    }

    func updateContextDocument(
        currentState: String,
        observations: [ContextObservation]
    ) async throws -> ContextDocumentUpdate {
        updateCalls += 1
        let text = observations.flatMap(\.blocks).map(\.text).joined(separator: "\n")
        return ContextDocumentUpdate(
            changed: true,
            currentStateMarkdown: text,
            activityEntryMarkdown: text
        )
    }

    func generatePromptDisposition(
        _ envelope: PromptContextEnvelope
    ) async throws -> PromptGenerationDisposition {
        .generated(try PromptResponse(text: "Generated response"))
    }
}

private struct FailingPromptIntelligence: LocalIntelligenceProviding {
    func refineDictation(
        _ deterministic: RefinementResult,
        context: DictationContext
    ) async -> RefinementResult {
        deterministic
    }

    func generatePromptDisposition(
        _ envelope: PromptContextEnvelope
    ) async throws -> PromptGenerationDisposition {
        throw CurrentError.promptGenerationFailed("Primary unavailable")
    }
}

private struct FixedPromptGenerator: PromptResponseGenerating {
    let disposition: PromptGenerationDisposition

    init(text: String) throws {
        disposition = .generated(try PromptResponse(text: text))
    }

    init(disposition: PromptGenerationDisposition) {
        self.disposition = disposition
    }

    func generatePromptDisposition(
        _ envelope: PromptContextEnvelope
    ) async throws -> PromptGenerationDisposition {
        disposition
    }
}

private actor FixedIntentRouter: VoiceIntentRoutingProviding {
    let decision: IntentDecision?
    private(set) var classifyCount = 0
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0

    init(_ intent: VoiceIntent?) {
        decision = intent.map { IntentDecision(intent: $0, confidence: 0.9) }
    }

    func isAvailable() async -> Bool { decision != nil }
    func setEnabled(_ enabled: Bool) async {}
    func prepare(sessionID: UUID, context: IntentRoutingContext) async {
        prepareCount += 1
    }
    func classify(
        _ request: IntentRoutingRequest,
        sessionID: UUID
    ) async throws -> IntentDecision {
        classifyCount += 1
        guard let decision else {
            throw CurrentError.modelUnavailable("Router unavailable")
        }
        return decision
    }
    func cancel(sessionID: UUID) async { cancelCount += 1 }
}

private struct PromptOnlyIntelligence: LocalIntelligenceProviding {
    let generator: any PromptResponseGenerating

    func refineDictation(
        _ deterministic: RefinementResult,
        context: DictationContext
    ) async -> RefinementResult {
        deterministic
    }

    func generatePromptDisposition(
        _ envelope: PromptContextEnvelope
    ) async throws -> PromptGenerationDisposition {
        try await generator.generatePromptDisposition(envelope)
    }
}

private actor PromptScreenStub: ScreenContextProviding {
    let observation: ContextObservation?
    private(set) var refreshCount = 0
    private(set) var activityCount = 0

    init(observation: ContextObservation?) {
        self.observation = observation
    }

    func start() async throws {}
    func stop() async {}
    func scheduleCapture(
        trigger: ContextCaptureTrigger,
        target: ContextCaptureTarget?
    ) async {}
    func recordActivity(_ activity: RecentApplicationActivity) async {
        activityCount += 1
    }
    func setForegroundInteractionActive(_ active: Bool) async {}
    func refreshForPrompt(
        target: ContextCaptureTarget
    ) async throws -> ContextObservation? {
        refreshCount += 1
        return observation
    }
}

@Test func routingRequestBoundsFocusedContextWithoutScreenCapture() {
    let request = IntentRoutingRequest(
        transcript: String(repeating: "spoken ", count: 2_000),
        context: DictationContext(
            selectedText: String(repeating: "selected ", count: 2_000),
            textBeforeCursor: String(repeating: "before ", count: 500),
            textAfterCursor: String(repeating: "after ", count: 500)
        )
    )
    #expect(request.transcript.count <= IntentRoutingRequest.maximumTranscriptCharacters)
    #expect(request.context.selectionExcerpt.count <= IntentRoutingContext.maximumSelectionCharacters)
    #expect(request.context.textBeforeCursor.count <= IntentRoutingContext.maximumNearbyCharacters)
    #expect(request.context.textAfterCursor.count <= IntentRoutingContext.maximumNearbyCharacters)
}

@Test func uncertainAppleRouteFallsBackToGemmaExactlyOnce() async throws {
    let apple = FixedIntentRouter(.uncertain)
    let gemma = FixedIntentRouter(.prompt)
    let router = HybridVoiceIntentRouter(primary: apple, fallback: gemma)
    let sessionID = UUID()
    let decision = try await router.classify(
        IntentRoutingRequest(transcript: "Draft and email", context: .empty),
        sessionID: sessionID
    )
    #expect(decision.intent == .prompt)
    #expect(await apple.classifyCount == 1)
    #expect(await gemma.classifyCount == 1)
    #expect(await router.diagnostics.backend == .gemma4)
}

@Test func directAppleRouteDoesNotCallGemma() async throws {
    let apple = FixedIntentRouter(.direct)
    let gemma = FixedIntentRouter(.prompt)
    let router = HybridVoiceIntentRouter(primary: apple, fallback: gemma)
    let decision = try await router.classify(
        IntentRoutingRequest(
            transcript: "The draft and email are ready",
            context: .empty
        ),
        sessionID: UUID()
    )
    #expect(decision.intent == .direct)
    #expect(await gemma.classifyCount == 0)
    #expect(await router.diagnostics.backend == .appleFoundationModel)
}

@Test func dualUncertainRoutingFailsInsteadOfDefaultingToDirect() async {
    let router = HybridVoiceIntentRouter(
        primary: FixedIntentRouter(.uncertain),
        fallback: FixedIntentRouter(.uncertain)
    )
    do {
        _ = try await router.classify(
            IntentRoutingRequest(transcript: "Ambiguous words", context: .empty),
            sessionID: UUID()
        )
        Issue.record("Expected routing failure")
    } catch let error as CurrentError {
        guard case .intentClassificationFailed = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func hybridPromptGenerationFallsBackToGemmaAndTracksOnlyBackend() async throws {
    let provider = HybridLocalIntelligenceProvider(
        primary: FailingPromptIntelligence(),
        fallback: try FixedPromptGenerator(text: "Hello from Gemma")
    )
    let disposition = try await provider.generatePromptDisposition(
        PromptContextEnvelope(
            instruction: "Draft a friendly email to Alex about Tuesday",
            focusedContext: .empty,
            sections: []
        )
    )
    #expect(disposition.response?.text == "Hello from Gemma")
    #expect(await provider.lastSuccessfulBackend == .gemma4)
}

@Test func modelReportedInsufficientContextDoesNotFallThrough() async throws {
    let primary = FixedPromptGenerator(disposition: .insufficientContext)
    let typedProvider = HybridLocalIntelligenceProvider(
        primary: PromptOnlyIntelligence(generator: primary),
        fallback: try FixedPromptGenerator(text: "Must not be used")
    )
    let disposition = try await typedProvider.generatePromptDisposition(
        PromptContextEnvelope(
            instruction: "Draft and email",
            focusedContext: .empty,
            sections: []
        )
    )
    #expect(disposition == .insufficientContext)
    #expect(await typedProvider.lastSuccessfulBackend == .appleFoundationModel)
}

@Test func structuredPromptEnvelopeIsCodableAndKeepsFreshContextFirst() throws {
    let envelope = PromptContextEnvelope(
        instruction: "Reply to this",
        focusedContext: DictationContext(selectedText: "Selected"),
        sections: [
            .init(
                kind: .freshTargetObservation,
                title: "Fresh target-window observation",
                content: "NEW THREAD"
            ),
            .init(
                kind: .targetCurrentState,
                title: "Target application current state",
                content: "OLDER STATE"
            ),
            .init(
                kind: .otherApplicationActivity,
                title: "Other activity",
                content: String(repeating: "noise ", count: 1_000)
            ),
        ]
    )
    let decoded = try JSONDecoder().decode(
        PromptContextEnvelope.self,
        from: JSONEncoder().encode(envelope)
    )
    let rendered = decoded.rendered(maximumCharacters: 320)
    #expect(decoded == envelope)
    #expect(rendered.contains("Reply to this"))
    #expect(rendered.contains("Selected"))
    #expect(rendered.contains("NEW THREAD"))
    #expect(rendered.firstRange(of: "NEW THREAD")!.lowerBound
        < rendered.firstRange(of: "OLDER STATE")!.lowerBound)
}

@Test func contextWorkerInteractiveRequestsAreVersionedAndCodable() throws {
    let request = ContextWorkerPromptRequest(
        modelSnapshotPath: "/tmp/gemma",
        envelope: PromptContextEnvelope(
            instruction: "Compose a response",
            focusedContext: .empty,
            sections: []
        )
    )
    let decoded = try JSONDecoder().decode(
        ContextWorkerPromptRequest.self,
        from: JSONEncoder().encode(request)
    )
    #expect(ContextWorkerProtocolVersion.current == 3)
    #expect(decoded.requestID == request.requestID)
    #expect(decoded.priority == .interactive)
    #expect(DictationPhase.gatheringContext.displayName == "Reading context…")

    let intent = ContextWorkerIntentRequest(
        requestID: UUID(),
        modelSnapshotPath: "/tmp/gemma",
        routingRequest: IntentRoutingRequest(
            transcript: "Draft an email",
            context: .empty
        )
    )
    let decodedIntent = try JSONDecoder().decode(
        ContextWorkerIntentRequest.self,
        from: JSONEncoder().encode(intent)
    )
    #expect(decodedIntent.requestID == intent.requestID)
    #expect(decodedIntent.priority == .voiceRouting)
}

@Test func gemmaTypedRoutingAndPromptSchemasAreStrict() throws {
    let decision = try GemmaIntentNormalizer.decision(
        from: #"prefix {"intent":"prompt","confidence":0.91} suffix"#
    )
    #expect(decision == IntentDecision(intent: .prompt, confidence: 0.91))
    #expect(throws: (any Error).self) {
        try GemmaIntentNormalizer.decision(
            from: #"{"intent":"instruction","confidence":1}"#
        )
    }

    let generated = try GemmaPromptNormalizer.disposition(
        from: #"{"status":"generated","insertionText":"Hello Alex"}"#
    )
    #expect(generated.response?.text == "Hello Alex")
    let insufficient = try GemmaPromptNormalizer.disposition(
        from: #"{"status":"insufficientContext","insertionText":""}"#
    )
    #expect(insufficient == .insufficientContext)
    #expect(throws: (any Error).self) {
        try GemmaPromptNormalizer.disposition(
            from: #"{"status":"maybe","insertionText":"unsafe"}"#
        )
    }
}

@Test func modelRoutingEvaluationCorpusIsExplicitlyModelOwned() {
    #expect(modelRoutingCorpus.count == 6)
    // This remains data only: no production keyword classifier exists.
}

@Test func appleIntentRouterPassesEvaluationCorpusWhenGated() async throws {
    guard ProcessInfo.processInfo.environment[
        "CURRENT_RUN_INTENT_ROUTER_INTEGRATION"
    ] == "1" else { return }
    let router = AppleVoiceIntentRouter()
    guard await router.isAvailable() else { return }
    for (transcript, expected) in modelRoutingCorpus {
        let sessionID = UUID()
        let context = IntentRoutingContext(context: .empty)
        await router.prepare(sessionID: sessionID, context: context)
        let decision = try await router.classify(
            IntentRoutingRequest(transcript: transcript, context: .empty),
            sessionID: sessionID
        )
        #expect(decision.intent == expected)
    }
}

@MainActor
@Test func promptContextPreparationObeysContinuousContextSetting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "current-prompt-context-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ContextStore(directory: root)
    store.reload()
    let repository = ContextRepository(
        store: store,
        structurer: StubIntelligence()
    )
    let target = ContextCaptureTarget(
        processIdentifier: 8123,
        bundleIdentifier: "com.example.Mail",
        applicationName: "Mail",
        windowIdentifier: 45,
        windowTitle: "Message"
    )
    let fresh = ContextObservation(
        processIdentifier: target.processIdentifier,
        bundleIdentifier: target.bundleIdentifier,
        applicationName: target.applicationName,
        windowIdentifier: target.windowIdentifier,
        windowTitle: target.windowTitle,
        isFrontmost: true,
        blocks: [
            ContextTextBlock(
                text: "Alex asks whether Tuesday at 10 works.",
                source: .accessibility
            ),
        ]
    )
    let screen = PromptScreenStub(observation: fresh)
    let preparer = LivePromptContextPreparer(
        repository: repository,
        screenContext: screen
    )

    let disabled = try await preparer.prepare(
        instruction: "Draft an email",
        focusedContext: .empty,
        target: target,
        continuousContextEnabled: false
    )
    #expect(disabled.sections.isEmpty)
    #expect(await screen.refreshCount == 0)

    let enabled = try await preparer.prepare(
        instruction: "Draft an email",
        focusedContext: .empty,
        target: target,
        continuousContextEnabled: true
    )
    #expect(enabled.sections.first?.kind == .freshTargetObservation)
    #expect(enabled.sections.first?.content.contains("Tuesday at 10") == true)
    #expect(await screen.refreshCount == 1)
    #expect(await screen.activityCount == 1)
}

@Test func promptEnvelopeKeepsTargetContextAheadOfOtherApps() {
    let envelope = PromptContextEnvelope(
        instruction: "Reply to this",
        focusedContext: DictationContext(
            selectedText: "Original",
            textBeforeCursor: "Before",
            textAfterCursor: "After"
        ),
        targetApplicationContext: "TARGET-CONTEXT",
        otherVisibleApplicationContexts: [
            String(repeating: "other ", count: 500),
        ]
    )
    let rendered = envelope.rendered(maximumCharacters: 500)
    #expect(rendered.contains("Reply to this"))
    #expect(rendered.contains("Original"))
    #expect(rendered.contains("TARGET-CONTEXT"))
    #expect(rendered.contains("Other visible application context"))
    #expect(rendered.count <= 500)
}

@Test func ocrBlocksAreAttributedToTheOwningVisibleWindow() throws {
    let display = ContextBounds(x: 0, y: 0, width: 1_000, height: 800)
    let mail = WindowContextDescriptor(
        windowIdentifier: 1,
        processIdentifier: 10,
        bundleIdentifier: "com.apple.mail",
        applicationName: "Mail",
        title: "Inbox",
        frame: ContextBounds(x: 0, y: 0, width: 600, height: 800),
        isFrontmost: true
    )
    let notes = WindowContextDescriptor(
        windowIdentifier: 2,
        processIdentifier: 20,
        bundleIdentifier: "com.apple.Notes",
        applicationName: "Notes",
        title: "Notes",
        frame: ContextBounds(x: 600, y: 0, width: 400, height: 800),
        isFrontmost: false
    )
    let observations = OCRWindowMapper.observations(
        blocks: [
            ContextTextBlock(
                text: "Inbox message",
                source: .visionOCR,
                bounds: ContextBounds(x: 0.1, y: 0.4, width: 0.2, height: 0.1)
            ),
            ContextTextBlock(
                text: "A note",
                source: .visionOCR,
                bounds: ContextBounds(x: 0.75, y: 0.4, width: 0.1, height: 0.1)
            ),
        ],
        displayIdentifier: 99,
        displayFrame: display,
        windows: [mail, notes],
        capturedAt: Date()
    )
    #expect(observations.count == 2)
    #expect(
        observations.first(where: { $0.applicationName == "Mail" })?
            .blocks.map(\.text) == ["Inbox message"]
    )
    #expect(
        observations.first(where: { $0.applicationName == "Notes" })?
            .blocks.map(\.text) == ["A note"]
    )
}

@MainActor
@Test func appSessionDocumentsRoundTripMetadataAndClose() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "current-app-session-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ContextStore(directory: root)
    store.reload()
    let started = Date(timeIntervalSince1970: 1_775_000_000)
    let metadata = AppSessionMetadata(
        applicationName: "Mail",
        bundleIdentifier: "com.apple.mail",
        processIdentifier: 42,
        startedAt: started,
        dayIdentifier: "2026-04-01",
        iconRelativePath: "App Icons/com.apple.mail.png",
        sources: [.accessibility, .visionOCR]
    )
    let document = try store.applyAppSessionUpdate(
        metadata: metadata,
        update: ContextDocumentUpdate(
            changed: true,
            currentStateMarkdown: "Viewing the inbox.",
            activityEntryMarkdown: "Opened a message."
        ),
        at: started
    )
    #expect(document.id == "app:\(metadata.sessionID.rawValue)")
    #expect(document.markdown.contains("## Current state"))
    #expect(document.markdown.contains("Opened a message."))
    #expect(store.filteredDocuments(matching: "com.apple.mail").count == 1)

    try store.closeAppSessions(processIdentifier: 42, at: started.addingTimeInterval(60))
    let closed = try #require(store.appSessionDocument(sessionID: metadata.sessionID))
    guard case .appSession(let closedMetadata) = closed.kind else {
        Issue.record("Expected app-session document")
        return
    }
    #expect(closedMetadata.endedAt != nil)
    #expect(!closedMetadata.isActive)
}

@MainActor
@Test func repositoryDeduplicatesStaticContextAndCutsAtMidnight() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "current-repository-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let store = ContextStore(directory: root, calendar: calendar)
    store.reload()
    let intelligence = StubIntelligence()
    let repository = ContextRepository(
        store: store,
        structurer: intelligence,
        calendar: calendar
    )
    let firstDate = calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 25,
            hour: 23,
            minute: 59
        )
    )!
    let observation = ContextObservation(
        capturedAt: firstDate,
        processIdentifier: 404,
        bundleIdentifier: "example.app",
        applicationName: "Example",
        windowTitle: "Window",
        isFrontmost: true,
        blocks: [
            ContextTextBlock(text: "Static content", source: .accessibility),
        ]
    )
    #expect(await repository.accept(observation))
    #expect(!(await repository.accept(observation)))

    let nextDay = ContextObservation(
        capturedAt: firstDate.addingTimeInterval(120),
        processIdentifier: 404,
        bundleIdentifier: "example.app",
        applicationName: "Example",
        windowTitle: "Window",
        isFrontmost: true,
        blocks: [
            ContextTextBlock(text: "Next day", source: .accessibility),
        ]
    )
    #expect(await repository.accept(nextDay))
    await repository.stop()
    store.reload()
    #expect(store.appSessionDocuments().count == 2)
    #expect(await intelligence.updateCalls == 2)
}

@Test func accessibilityCoverageRequiresSemanticDepthOrUsefulText() {
    let key = ContextCoverageKey(
        processIdentifier: 42,
        windowTitle: "Document"
    )
    #expect(
        AccessibilityCoverage(
            key: key,
            lastAttempt: Date(),
            lastUsefulObservation: Date(),
            blockCount: 3,
            normalizedCharacterCount: 12
        ).isUseful
    )
    #expect(
        AccessibilityCoverage(
            key: key,
            lastAttempt: Date(),
            lastUsefulObservation: Date(),
            blockCount: 1,
            normalizedCharacterCount: 40
        ).isUseful
    )
    #expect(
        !AccessibilityCoverage(
            key: key,
            lastAttempt: Date(),
            lastUsefulObservation: nil,
            blockCount: 2,
            normalizedCharacterCount: 39
        ).isUseful
    )
}

@Test func gemmaOutputIsNormalizedToBoundedUniqueBullets() throws {
    let payload = """
    {
      "changed": true,
      "currentStateBullets": ["- Task 17 is due 2026-07-26", "Task 17 is due 2026-07-26", "https://example.com/item/17"],
      "activityBullets": ["• Status changed to Done"]
    }
    """
    let update = try ContextBulletNormalizer.update(from: payload)
    #expect(update.currentStateMarkdown.components(separatedBy: "\n").count == 2)
    #expect(update.currentStateMarkdown.contains("2026-07-26"))
    #expect(update.currentStateMarkdown.contains("https://example.com/item/17"))
    #expect(update.activityEntryMarkdown == "- Status changed to Done")
}

@Test func gemmaMetalRuntimeFindsPackagedResourceAndRejectsMissingOne() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "current-metal-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let resource = root.appendingPathComponent(
        "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
    )
    try FileManager.default.createDirectory(
        at: resource.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    #expect(
        GemmaMetalRuntime.defaultLibraryURL(searchRoots: [root]) == nil
    )
    #expect(FileManager.default.createFile(atPath: resource.path, contents: Data()))
    #expect(
        GemmaMetalRuntime.defaultLibraryURL(searchRoots: [root]) == resource
    )
}

@MainActor
@Test func installedGemmaCheckpointProducesDeterministicTokenWhenGated()
    async throws {
    guard ProcessInfo.processInfo.environment[
        "CURRENT_RUN_GEMMA_INTEGRATION"
    ] == "1" else {
        return
    }
    let manager = GemmaContextModelManager()
    let response = try await manager.runIntegrationProbe()
    #expect(!response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    await manager.unload()
}

@MainActor
@Test func aliasesPersistAndParticipateInSearch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "current-alias-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ContextStore(directory: root)
    store.reload()
    let document = try store.append("A dictated note", at: Date())
    try store.rename(
        documentID: document.id,
        displayName: "Quarterly planning"
    )
    store.reload()
    #expect(
        store.document(id: document.id)?.customDisplayName
            == "Quarterly planning"
    )
    #expect(store.filteredDocuments(matching: "Quarterly").count == 1)
    #expect(
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "Document Metadata.json"
            ).path
        )
    )
}

@MainActor
@Test func legacyAppSessionsMigrateAtomicallyAndPreserveTimestamps()
    async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "current-v2-migration-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let dayDirectory = root.appendingPathComponent(
        "App Sessions/2026-07-25",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: dayDirectory,
        withIntermediateDirectories: true
    )
    let sessionID = UUID().uuidString
    let markdown = """
    # Mail — App Session

    | Metadata | Value |
    | --- | --- |
    | App | Mail |
    | Bundle ID | com.apple.mail |
    | Session ID | \(sessionID) |
    | Process ID | 909 |
    | Started | 2026-07-25T10:00:00Z |
    | Ended | 2026-07-25T10:05:00Z |
    | Day | 2026-07-25 |
    | Icon |  |
    | Sources | Accessibility |

    ## Current state

    Reviewing the project message.

    ## Activity

    ### 10:01:02

    Opened the project message from Alex.
    """
    try Data(markdown.utf8).write(
        to: dayDirectory.appendingPathComponent("legacy.md"),
        options: .atomic
    )
    let store = ContextStore(directory: root)
    store.reload()
    #expect(store.appSessionDocumentsRequiringMigration().count == 1)
    let repository = ContextRepository(
        store: store,
        structurer: StubIntelligence()
    )
    await repository.migrateLegacyDocuments()
    let migrated = try #require(store.appSessionDocuments().first)
    #expect(migrated.markdown.contains("| Format Version | 2 |"))
    #expect(migrated.markdown.contains("### 10:01:02"))
    #expect(migrated.markdown.contains("Alex"))
}

@MainActor
@Test func deletingAnActiveSessionSuppressesRecreation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "current-session-discard-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ContextStore(directory: root)
    store.reload()
    let repository = ContextRepository(
        store: store,
        structurer: StubIntelligence()
    )
    let observation = ContextObservation(
        processIdentifier: 818,
        bundleIdentifier: "example.active",
        applicationName: "Active",
        windowTitle: "Main",
        blocks: [
            ContextTextBlock(
                text: "A sufficiently useful accessibility observation",
                source: .accessibility
            ),
        ]
    )
    #expect(await repository.accept(observation))
    let context = try #require((await repository.snapshot()).first)
    await repository.discardSession(
        documentID: "app:\(context.session.sessionID.rawValue)"
    )
    #expect(!(await repository.accept(observation)))
    #expect((await repository.snapshot()).isEmpty)
}

@Test func screenRecordingParticipatesInPermissionOrdering() {
    let snapshot = PermissionSnapshot(
        microphone: .granted,
        accessibility: .granted,
        screenRecording: .denied,
        inputMonitoring: .granted
    )
    #expect(snapshot.firstMissing == .screenRecording)
    #expect(
        OnboardingFlow.automaticDestination(
            from: .accessibility,
            permissions: snapshot
        ) == .screenRecording
    )
}

@MainActor
@Test func fixedBackgroundPolicyIgnoresObsoleteCaptureSettings() {
    let suiteName = "CurrentContextSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(4.0, forKey: "contextCaptureFramesPerSecond")
    defaults.set(1.0, forKey: "contextScreenshotIntervalSeconds")

    _ = SettingsStore(defaults: defaults)
    let policy = ContextBackgroundPolicy()
    #expect(policy.recencyInterval == 300)
    #expect(policy.normalRefreshDelay == 30)
    #expect(policy.interJobSpacing == 10)
    #expect(policy.userIdleDelay == 2)
}

@MainActor
@Test func repositoryDefensivelyRejectsCurrentByPIDOrBundle() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "current-exclusion-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ContextStore(directory: root)
    store.reload()
    let repository = ContextRepository(
        store: store,
        structurer: StubIntelligence(),
        excludedBundleIdentifiers: ["local.Current"],
        excludedProcessIdentifiers: [777]
    )
    let block = ContextTextBlock(
        text: "Should not be retained",
        source: .accessibility
    )

    #expect(
        !(await repository.accept(
            ContextObservation(
                processIdentifier: 777,
                bundleIdentifier: "example.other",
                applicationName: "PID match",
                blocks: [block]
            )
        ))
    )
    #expect(
        !(await repository.accept(
            ContextObservation(
                processIdentifier: 778,
                bundleIdentifier: "local.Current",
                applicationName: "Bundle match",
                blocks: [block]
            )
        ))
    )
    #expect((await repository.snapshot()).isEmpty)
}

@Test func perceptualHashUsesTheConfiguredChangeTolerance() {
    let original: UInt64 = 0b1010
    #expect(
        PerceptualImageHasher.isVisuallyEquivalent(
            original,
            original ^ 0b1111
        )
    )
    #expect(
        !PerceptualImageHasher.isVisuallyEquivalent(
            original,
            original ^ 0b1_1111
        )
    )

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: 90,
        height: 80,
        bitsPerComponent: 8,
        bytesPerRow: 90 * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.setFillColor(CGColor(gray: 0, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: 45, height: 80))
    context?.setFillColor(CGColor(gray: 1, alpha: 1))
    context?.fill(CGRect(x: 45, y: 0, width: 45, height: 80))
    let image = context?.makeImage()
    #expect(image.flatMap(PerceptualImageHasher.hash) != nil)
}

@Test func recentApplicationLedgerSpacesJobsAndUsesRoundRobinFairness() {
    let start = Date(timeIntervalSince1970: 1_000)
    var ledger = RecentApplicationLedger()
    let first = ContextCaptureTarget(
        processIdentifier: 1_001,
        bundleIdentifier: "example.first",
        applicationName: "First"
    )
    let second = ContextCaptureTarget(
        processIdentifier: 1_002,
        bundleIdentifier: "example.second",
        applicationName: "Second"
    )
    let acceptedFirst = ledger.record(.init(
        target: first,
        kind: .activation,
        occurredAt: start
    ))
    let acceptedSecond = ledger.record(.init(
        target: second,
        kind: .activation,
        occurredAt: start
    ))
    #expect(acceptedFirst)
    #expect(acceptedSecond)
    #expect(ledger.nextEligible(at: start.addingTimeInterval(29)) == nil)
    #expect(
        ledger.nextEligible(at: start.addingTimeInterval(30))?
            .target.processIdentifier == first.processIdentifier
    )
    ledger.markCompleted(
        processIdentifier: first.processIdentifier,
        at: start.addingTimeInterval(30)
    )
    #expect(ledger.nextEligible(at: start.addingTimeInterval(39.9)) == nil)
    #expect(
        ledger.nextEligible(at: start.addingTimeInterval(40))?
            .target.processIdentifier == second.processIdentifier
    )
}

@Test func recentApplicationLedgerResetsTypingDebounceAndExpiresApps() {
    let start = Date(timeIntervalSince1970: 2_000)
    var ledger = RecentApplicationLedger()
    let target = ContextCaptureTarget(
        processIdentifier: 2_001,
        bundleIdentifier: "example.editor",
        applicationName: "Editor"
    )
    let acceptedFirst = ledger.record(.init(
        target: target,
        kind: .typingSettled,
        occurredAt: start
    ))
    let acceptedSecond = ledger.record(.init(
        target: target,
        kind: .typingSettled,
        occurredAt: start.addingTimeInterval(2)
    ))
    #expect(acceptedFirst)
    #expect(acceptedSecond)
    #expect(ledger.nextEligible(at: start.addingTimeInterval(4.9)) == nil)
    #expect(ledger.nextEligible(at: start.addingTimeInterval(5)) != nil)
    ledger.expire(at: start.addingTimeInterval(5 * 60 + 2.1))
    #expect(ledger.entries.isEmpty)
}

@Test func recentApplicationLedgerIsBoundedAndRejectsSystemApps() {
    var ledger = RecentApplicationLedger()
    let start = Date(timeIntervalSince1970: 3_000)
    for index in 0..<13 {
        _ = ledger.record(.init(
            target: .init(
                processIdentifier: pid_t(3_000 + index),
                bundleIdentifier: "example.\(index)",
                applicationName: "App \(index)"
            ),
            kind: .activation,
            occurredAt: start.addingTimeInterval(Double(index))
        ))
    }
    #expect(ledger.entries.count == 12)
    for (offset, bundleIdentifier) in [
        "local.Current",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "local.Current.ContextWorker",
    ].enumerated() {
        let accepted = ledger.record(.init(
            target: .init(
                processIdentifier: pid_t(4_000 + offset),
                bundleIdentifier: bundleIdentifier,
                applicationName: "Excluded"
            ),
            kind: .activation,
            occurredAt: start
        ))
        #expect(!accepted)
    }
}

@Test func contextWorkerImagePayloadEnforcesBounds() throws {
    let valid = try ContextWorkerImagePayload(
        bgraData: Data(repeating: 0, count: 4 * 3 * 2),
        width: 3,
        height: 2,
        bytesPerRow: 12
    )
    #expect(valid.bgraData.count == 24)
    var rejected = false
    do {
        _ = try ContextWorkerImagePayload(
            bgraData: Data(repeating: 0, count: 4),
            width: 3,
            height: 2,
            bytesPerRow: 12
        )
    } catch {
        rejected = true
    }
    #expect(rejected)
}
