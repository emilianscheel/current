import Foundation
import Testing
@testable import CurrentCore

private actor StubIntelligence: LocalIntelligenceProviding {
    private(set) var updateCalls = 0

    func classifyIntent(_ request: VoiceInteractionRequest) async -> IntentDecision {
        ConservativeIntentClassifier.classify(request.transcript)
            ?? IntentDecision(intent: .uncertain, confidence: 0)
    }

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

    func generatePromptResponse(
        _ envelope: PromptContextEnvelope
    ) async throws -> PromptResponse {
        try PromptResponse(text: "Generated response")
    }
}

@Test func automaticIntentClassificationIsConservative() {
    #expect(
        ConservativeIntentClassifier.classify(
            "Write a proper response email here"
        )?.intent == .prompt
    )
    #expect(
        ConservativeIntentClassifier.classify(
            "Schreib eine höfliche Antwort"
        )?.intent == .prompt
    )
    #expect(
        ConservativeIntentClassifier.classify(
            "I will send the response tomorrow"
        ) == nil
    )
    #expect(
        IntentDecision(intent: .uncertain, confidence: 0.3).effectiveIntent
            == .direct
    )
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
        intelligence: intelligence,
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
    try? await Task.sleep(for: .milliseconds(100))
    store.reload()
    #expect(store.appSessionDocuments().count == 2)
    #expect(await intelligence.updateCalls == 2)
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
