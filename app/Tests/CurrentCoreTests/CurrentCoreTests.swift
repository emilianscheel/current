import CoreAudio
import Foundation
import Testing
@testable import CurrentCore

@Test func supportedHardwareRequiresM3And16GB() {
    #expect(HardwareSupport(isAppleSilicon: true, generation: 3, memoryBytes: 16 * 1_073_741_824, modelName: "Apple M3").isSupported)
    #expect(!HardwareSupport(isAppleSilicon: true, generation: 2, memoryBytes: 32 * 1_073_741_824, modelName: "Apple M2").isSupported)
    #expect(!HardwareSupport(isAppleSilicon: true, generation: 4, memoryBytes: 8 * 1_073_741_824, modelName: "Apple M4").isSupported)
}

@Test func hardwareGenerationParser() {
    #expect(HardwareChecker.appleSiliconGeneration(from: "Apple M3 Pro") == 3)
    #expect(HardwareChecker.appleSiliconGeneration(from: "Apple M12 Max") == 12)
    #expect(HardwareChecker.appleSiliconGeneration(from: "Mac15,6") == nil)
}

@Test func shortcutTapDoesNotRecord() {
    var machine = ShortcutStateMachine()
    #expect(machine.fnChanged(isDown: true) == .armed)
    #expect(machine.fnChanged(isDown: false) == .cancelled)
    #expect(!machine.isRecording)
}

@Test func shortcutHoldRecordsExactlyOnce() {
    var machine = ShortcutStateMachine()
    #expect(machine.fnChanged(isDown: true) == .armed)
    #expect(machine.thresholdReached() == .pressed)
    #expect(machine.thresholdReached() == nil)
    #expect(machine.fnChanged(isDown: false) == .released)
}

@Test func fnChordCancelsPendingOrActiveRecording() {
    var pending = ShortcutStateMachine()
    _ = pending.fnChanged(isDown: true)
    #expect(pending.otherKeyPressed() == nil)
    #expect(pending.thresholdReached() == nil)
    #expect(pending.fnChanged(isDown: false) == nil)

    var active = ShortcutStateMachine()
    _ = active.fnChanged(isDown: true)
    _ = active.thresholdReached()
    #expect(active.otherKeyPressed() == .cancelled)
}

@Test func escapeCancelsRecording() {
    var machine = ShortcutStateMachine()
    _ = machine.fnChanged(isDown: true)
    _ = machine.thresholdReached()
    #expect(machine.escape() == .cancelled)
}

@Test func insertionSpacingIsDeterministic() {
    #expect(InsertionService.preparedText(" hello\n", trailingSpace: true) == "hello ")
    #expect(InsertionService.preparedText("hello ", trailingSpace: false) == "hello")
    #expect(InsertionService.preparedText("", trailingSpace: true) == "")
}

@Test func contextAwareInsertionSpacingUsesSurroundingText() {
    let middle = DictationContext(
        textBeforeCursor: "Hello",
        textAfterCursor: "world",
        destination: .emailOrDocument
    )
    #expect(InsertionService.preparedText("beautiful", context: middle) == " beautiful ")

    let messageEnd = DictationContext(destination: .message)
    #expect(InsertionService.preparedText("sounds good", context: messageEnd) == "sounds good")

    let selected = DictationContext(
        selectedText: "old",
        destination: .generic,
        supportsSelectionEditing: true
    )
    #expect(InsertionService.preparedText("new", context: selected) == "new")
}

@Test func dictationContextBoundsEphemeralTextAndSelectionState() {
    let context = DictationContext(
        selectedText: "two selected words",
        textBeforeCursor: String(repeating: "a", count: 2_000),
        textAfterCursor: String(repeating: "b", count: 2_000),
        supportsSelectionEditing: true
    )
    #expect(context.textBeforeCursor.count == DictationContext.maximumNearbyCharacters / 2)
    #expect(context.textAfterCursor.count == DictationContext.maximumNearbyCharacters / 2)
    #expect(context.isEditingSelection)
    #expect(context.selectedWordCount == 3)
}

@Test func deterministicRefinementCleansSpeechWithoutChangingIntent() {
    let context = DictationContext(destination: .message)
    let result = DeterministicRefiner.refine(
        "Um hello hello there comma see you Tuesday actually Wednesday period",
        context: context
    )
    #expect(result.text == "Hello there, see you Wednesday")
    #expect(result.transformations.contains(.fillerRemoval))
    #expect(result.transformations.contains(.repetitionRemoval))
    #expect(result.transformations.contains(.spokenPunctuation))
    #expect(result.transformations.contains(.backtrack))
    #expect(result.transformations.contains(.contextualPunctuation))
}

@Test func deterministicRefinementPreservesNonCorrectionActually() {
    let result = DeterministicRefiner.refine(
        "I actually enjoyed the movie",
        context: .empty
    )
    #expect(result.text == "I actually enjoyed the movie")
    #expect(!result.transformations.contains(.backtrack))
}

@Test func deterministicRefinementFormatsUnmistakableLists() {
    let result = DeterministicRefiner.refine(
        "My goals are one finish the report two send the email three take a break",
        context: DictationContext(destination: .emailOrDocument)
    )
    #expect(
        result.text
            == "My goals are:\n1. Finish the report\n2. Send the email\n3. Take a break"
    )
    #expect(result.transformations.contains(.listFormatting))
}

@Test func contextualVocabularyRestoresVisibleTechnicalIdentifiers() {
    let context = DictationContext(
        visibleIdentifiers: ["CurrentCore.swift", "FluidAudio"],
        destination: .codeOrTerminal
    )
    let result = DeterministicRefiner.refine(
        "open current core dot swift with fluid audio",
        context: context
    )
    #expect(result.text == "Open CurrentCore.swift with FluidAudio")
    #expect(result.transformations.contains(.contextualVocabulary))
}

@Test func learnedReplacementAppliesAsAWholePhrase() {
    let entries = [
        LearnedVocabularyEntry(spokenForm: "whisper flow", writtenForm: "Wispr Flow"),
    ]
    let result = DeterministicRefiner.refine(
        "compare whisper flow today",
        context: .empty,
        vocabulary: entries
    )
    #expect(result.text == "Compare Wispr Flow today")
    #expect(result.transformations.contains(.learnedReplacement))
}

@Test func semanticSafetyGatePreservesCriticalAnchors() {
    let source = "Do not send $25 to https://example.com from main.swift."
    #expect(
        SemanticSafetyGate.accepts(
            candidate: "Do not send $25 to https://example.com from main.swift.",
            preserving: source
        )
    )
    #expect(
        !SemanticSafetyGate.accepts(
            candidate: "Send $50 to https://example.com from main.swift.",
            preserving: source
        )
    )
    #expect(
        !SemanticSafetyGate.accepts(
            candidate: "Do not send $25 to https://other.example from main.swift.",
            preserving: source
        )
    )
}

@MainActor
@Test func learnedVocabularyPersistsAndCanBeForgotten() {
    let suiteName = "CurrentVocabularyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = LearnedVocabularyStore(defaults: defaults)
    first.learn(spokenForm: "whisper flow", writtenForm: "Wispr Flow")
    first.learn(spokenForm: "same", writtenForm: "same")
    #expect(first.entries.count == 1)

    let restored = LearnedVocabularyStore(defaults: defaults)
    #expect(restored.entries.first?.writtenForm == "Wispr Flow")
    restored.forgetAll()
    #expect(restored.entries.isEmpty)
}

@Test func correctionLearningAcceptsOnlyOneChangedTerm() {
    let correction = DictationCoordinator.learnedCorrection(
        from: "Ask Tony tomorrow",
        to: "Ask Toni tomorrow"
    )
    #expect(correction?.spoken == "Tony")
    #expect(correction?.written == "Toni")
    #expect(
        DictationCoordinator.learnedCorrection(
            from: "Ask Tony tomorrow",
            to: "Please ask Toni today"
        ) == nil
    )
    #expect(
        DictationCoordinator.learnedCorrection(
            from: "Meet at 5pm",
            to: "Meet at 6pm"
        ) == nil
    )
}

private struct DictationEvaluationFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let raw: String
        let destination: DictationDestination
        let before: String?
        let after: String?
        let identifiers: [String]?
        let expected: String
    }

    let version: Int
    let cases: [Case]
}

@Test func versionedDictationEvaluationCorpusPassesDeterministicFallback() throws {
    let url = try #require(
        Bundle.module.url(
            forResource: "dictation-evaluation-v1",
            withExtension: "json"
        )
    )
    let fixture = try JSONDecoder().decode(
        DictationEvaluationFixture.self,
        from: Data(contentsOf: url)
    )
    #expect(fixture.version == 1)
    #expect(fixture.cases.count >= 8)
    for evaluation in fixture.cases {
        let result = DeterministicRefiner.refine(
            evaluation.raw,
            context: DictationContext(
                textBeforeCursor: evaluation.before ?? "",
                textAfterCursor: evaluation.after ?? "",
                visibleIdentifiers: evaluation.identifiers ?? [],
                destination: evaluation.destination
            )
        )
        #expect(
            result.text == evaluation.expected,
            "Evaluation failed: \(evaluation.name)"
        )
    }
}

@Test func directSelectionEditsWorkWithoutFoundationModel() async {
    let service = ContextualRefinementService()
    let spelling = await service.edit(
        selection: "Tony",
        instruction: "It's T-O-N-I",
        context: .empty
    )
    #expect(spelling?.text == "Toni")

    let changed = await service.edit(
        selection: "The meeting is at 5pm Thursday.",
        instruction: "Change 5pm to 6pm",
        context: .empty
    )
    #expect(changed?.text == "The meeting is at 6pm Thursday.")
}

@Test func pasteTargetsFrontmostAppInsteadOfWebContentProcess() {
    #expect(
        InsertionService.eventProcessIdentifier(
            frontmost: 101,
            accessibilityElement: 202
        ) == 101
    )
    #expect(
        InsertionService.eventProcessIdentifier(
            frontmost: nil,
            accessibilityElement: 202
        ) == 202
    )
}

@Test func destinationClassificationUsesAppAndFieldSemantics() {
    #expect(
        InsertionService.destination(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            applicationName: "Slack",
            role: "AXTextArea",
            subrole: nil,
            description: nil
        ) == .message
    )
    #expect(
        InsertionService.destination(
            bundleIdentifier: "com.apple.Terminal",
            applicationName: "Terminal",
            role: "AXTextArea",
            subrole: nil,
            description: nil
        ) == .codeOrTerminal
    )
    #expect(
        InsertionService.destination(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            role: "AXTextField",
            subrole: "AXSearchField",
            description: "Address and Search"
        ) == .search
    )
}

@Test func secureFieldDetectionNeverDependsOnReadableValue() {
    #expect(
        InsertionService.isSecureField(
            role: "AXSecureTextField",
            subrole: nil,
            description: nil
        )
    )
    #expect(
        InsertionService.isSecureField(
            role: "AXTextField",
            subrole: "AXSecureInput",
            description: nil
        )
    )
    #expect(
        !InsertionService.isSecureField(
            role: "AXTextField",
            subrole: nil,
            description: "Email address"
        )
    )
}

@MainActor
@Test func insertionTargetPresentationResolvesAndClears() {
    let missingIcon = InsertionService.TargetApplicationPresentation(
        processIdentifier: 42,
        bundleIdentifier: "example.target",
        localizedName: "Target",
        icon: nil
    )
    #expect(missingIcon.processIdentifier == 42)
    #expect(missingIcon.localizedName == "Target")
    #expect(missingIcon.icon == nil)
    #expect(InsertionService.applicationPresentation(processIdentifier: nil) == nil)
    #expect(InsertionService.applicationPresentation(processIdentifier: pid_t.max) == nil)

    let insertion = InsertionService()
    insertion.captureTarget()
    insertion.clearTarget()
    #expect(insertion.targetApplicationPresentation == nil)
}

@Test func audioAccumulatorTransfersAndClearsSamples() {
    let accumulator = AudioSampleAccumulator()
    accumulator.append([0.1, 0.2])
    accumulator.append([0.3])
    #expect(accumulator.take() == [0.1, 0.2, 0.3])
    #expect(accumulator.take().isEmpty)
}

@Test func audioLevelNormalizationUsesPerceptualDecibelRange() {
    #expect(AudioLevelEnvelope.normalizedLevel(rms: 0) == 0)
    #expect(AudioLevelEnvelope.normalizedLevel(rms: .infinity) == 0)
    #expect(AudioLevelEnvelope.normalizedLevel(rms: pow(10, -50.0 / 20.0)) < 0.001)
    #expect(abs(AudioLevelEnvelope.normalizedLevel(rms: pow(10, -29.0 / 20.0)) - 0.5) < 0.001)
    #expect(AudioLevelEnvelope.normalizedLevel(rms: 1) == 1)
}

@Test func audioEnvelopeAttacksReleasesAndResetsSmoothly() {
    var envelope = AudioLevelEnvelope()
    let attack = envelope.update(rms: 1)
    #expect(attack > 0.5)
    for _ in 0..<8 { envelope.update(rms: 1) }
    let peak = envelope.value
    let release = envelope.update(rms: 0)
    #expect(peak > 0.99)
    #expect(release < peak)
    #expect(release > 0)
    envelope.reset()
    #expect(envelope.value == 0)
}

@Test func automaticInputAvoidsBluetoothCaptureWhenBuiltInMicExists() {
    #expect(
        AudioCaptureService.preferredAutomaticInputDeviceID(
            defaultDeviceID: 100,
            defaultTransport: kAudioDeviceTransportTypeBluetooth,
            builtInDeviceIDs: [200]
        ) == 200
    )
    #expect(
        AudioCaptureService.preferredAutomaticInputDeviceID(
            defaultDeviceID: 100,
            defaultTransport: kAudioDeviceTransportTypeBuiltIn,
            builtInDeviceIDs: [200]
        ) == 100
    )
    #expect(
        AudioCaptureService.preferredAutomaticInputDeviceID(
            defaultDeviceID: 100,
            defaultTransport: kAudioDeviceTransportTypeBluetooth,
            builtInDeviceIDs: []
        ) == 100
    )
}

@Test func permissionSnapshotFindsFirstMissing() {
    let snapshot = PermissionSnapshot(microphone: .granted, accessibility: .denied, inputMonitoring: .granted)
    #expect(snapshot.firstMissing == .accessibility)
    #expect(!snapshot.allGranted)
}

@Test func modelIntegrityDetectsMutation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-integrity-\(UUID().uuidString)")
    let model = root.appendingPathComponent("model", isDirectory: true)
    let manifest = root.appendingPathComponent("manifest.json")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    let weight = model.appendingPathComponent("weight.bin")
    try Data("trusted".utf8).write(to: weight)
    try ModelIntegrity.verifyOrCreateManifest(for: model, manifestURL: manifest)
    try ModelIntegrity.verifyOrCreateManifest(for: model, manifestURL: manifest)
    try Data("changed".utf8).write(to: weight)
    #expect(throws: CurrentError.self) { try ModelIntegrity.verifyOrCreateManifest(for: model, manifestURL: manifest) }
}

private func createCompleteModelSnapshot(at root: URL) throws {
    for relativePath in ModelSnapshotValidator.requiredFiles {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("complete".utf8).write(to: file)
    }
}

@Test func modelSnapshotRequiresEveryNonemptyV3Artifact() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-model-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    try createCompleteModelSnapshot(at: root)
    #expect(ModelSnapshotValidator.isComplete(at: root))

    let missing = root.appendingPathComponent(ModelSnapshotValidator.requiredFiles[0])
    try FileManager.default.removeItem(at: missing)
    #expect(!ModelSnapshotValidator.isComplete(at: root))

    try Data("restored".utf8).write(to: missing)
    let empty = root.appendingPathComponent(ModelSnapshotValidator.requiredFiles[1])
    try Data().write(to: empty)
    #expect(!ModelSnapshotValidator.isComplete(at: root))
}

@Test func partialV3ModelSnapshotIsNotReady() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-model-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    try createCompleteModelSnapshot(at: root)
    let partial = root.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin.partial")
    try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("unfinished".utf8).write(to: partial)
    #expect(!ModelSnapshotValidator.isComplete(at: root))
}

@Test func legacyModelCleanupRunsOnlyAfterReplacementIsReady() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-migration-\(UUID().uuidString)")
    let models = root.appendingPathComponent("Models", isDirectory: true)
    let snapshot = models.appendingPathComponent("legacy", isDirectory: true)
    let manifest = models.appendingPathComponent("legacy-integrity.json")
    let locations = ModelSnapshotLocations(models: models, snapshot: snapshot, integrityManifest: manifest)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data("legacy".utf8).write(to: snapshot.appendingPathComponent("weight.bin"))
    try Data("manifest".utf8).write(to: manifest)

    LegacyModelCleanup.removeIfReplacementReady(false, locations: locations)
    #expect(FileManager.default.fileExists(atPath: snapshot.path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))

    LegacyModelCleanup.removeIfReplacementReady(true, locations: locations)
    #expect(!FileManager.default.fileExists(atPath: snapshot.path))
    #expect(!FileManager.default.fileExists(atPath: manifest.path))
}

private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@Test func legacyCleanupFailureDoesNotRemoveOrFailReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-migration-\(UUID().uuidString)")
    let snapshot = root.appendingPathComponent("legacy", isDirectory: true)
    let manifest = root.appendingPathComponent("legacy-integrity.json")
    let locations = ModelSnapshotLocations(models: root, snapshot: snapshot, integrityManifest: manifest)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data("legacy".utf8).write(to: manifest)
    LegacyModelCleanup.removeIfReplacementReady(
        true,
        locations: locations,
        fileManager: FailingRemovalFileManager()
    )

    #expect(FileManager.default.fileExists(atPath: snapshot.path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))
}

@Test func overlayLayoutAttachesToPhysicalNotch() {
    let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    let notch = CGRect(x: 656, y: 950, width: 200, height: 32)
    let layout = OverlayLayout(screenFrame: screen, safeAreaTop: 32, notchBounds: notch)

    #expect(layout.attachment == .notch)
    #expect(layout.collapsedSize == CGSize(width: 200, height: 32))
    #expect(layout.expandedSize == CGSize(width: 360, height: 46))
    #expect(layout.panelFrame.midX == screen.midX)
    #expect(layout.panelFrame.maxY == screen.maxY)
    #expect(layout.topPadding == 0)
}

@Test func overlayLayoutUsesDetachedIslandWithoutNotch() {
    let screen = CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080)
    let layout = OverlayLayout(screenFrame: screen, safeAreaTop: 0, notchBounds: nil)

    #expect(layout.attachment == .detached)
    #expect(layout.expandedSize == CGSize(width: 220, height: 46))
    #expect(layout.panelFrame.midX == screen.midX)
    #expect(layout.panelFrame.maxY == screen.maxY)
    #expect(layout.topPadding == 6)
}

@Test func overlayLayoutCapsExpansionOnNarrowDisplays() {
    let screen = CGRect(x: 0, y: 0, width: 600, height: 800)
    let notch = CGRect(x: 200, y: 768, width: 200, height: 32)
    let layout = OverlayLayout(screenFrame: screen, safeAreaTop: 32, notchBounds: notch)

    #expect(abs(layout.expandedSize.width - 300) < 0.001)
    #expect(layout.panelFrame.minX >= screen.minX)
    #expect(layout.panelFrame.maxX <= screen.maxX)
}

@Test func menuBarSymbolStaysDefaultForEveryPhase() {
    for phase in DictationPhase.allCases {
        #expect(MenuBarPresentation.symbol(for: phase) == "alternatingcurrent")
    }
}

@Test func onboardingRepairsTheFirstMissingPermission() {
    let permissions = PermissionSnapshot(microphone: .granted, accessibility: .denied, inputMonitoring: .denied)
    #expect(OnboardingFlow.initialStep(saved: .practice, completed: true, permissions: permissions, modelInstalled: true) == .accessibility)
}

@Test func onboardingContinuesPastThePermissionRestart() {
    let granted = PermissionSnapshot(
        microphone: .granted,
        accessibility: .granted,
        screenRecording: .granted,
        inputMonitoring: .granted
    )
    #expect(OnboardingFlow.initialStep(saved: .restart, completed: false, permissions: granted, modelInstalled: false) == .model)
    #expect(OnboardingFlow.automaticDestination(from: .inputMonitoring, permissions: granted) == .restart)
}

@MainActor
@Test func onboardingStepPersists() {
    let suiteName = "CurrentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = SettingsStore(defaults: defaults)
    first.onboardingStep = .inputMonitoring
    let restored = SettingsStore(defaults: defaults)
    #expect(restored.onboardingStep == .inputMonitoring)
}

private func contextTestCalendar(timeZoneID: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneID)!
    return calendar
}

private func contextTestDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    calendar: Calendar
) -> Date {
    calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}

@MainActor
@Test func contextStoreGroupsDictationsByLocalDayAndSearchesContent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-context-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let calendar = contextTestCalendar(timeZoneID: "Europe/Berlin")
    let store = ContextStore(
        directory: root,
        calendar: calendar,
        locale: Locale(identifier: "en_US"),
        trashHandler: { try FileManager.default.removeItem(at: $0) }
    )
    let morning = contextTestDate(2026, 7, 24, 9, 5, calendar: calendar)
    let afternoon = contextTestDate(2026, 7, 24, 15, 30, calendar: calendar)
    let tomorrow = contextTestDate(2026, 7, 25, 8, 0, calendar: calendar)

    try store.append("Use *literal* Markdown.", at: morning)
    try store.append("Second conversation", at: afternoon)
    try store.append("Tomorrow's context", at: tomorrow)

    #expect(store.documents.map(\.id) == ["2026-07-25", "2026-07-24"])
    let firstDay = try #require(store.document(id: "2026-07-24"))
    #expect(firstDay.markdown.contains("09:05 h"))
    #expect(firstDay.markdown.contains("15:30 h"))
    #expect(firstDay.markdown.contains("\\*literal\\*"))
    #expect(firstDay.markdown.contains("**Second conversation**"))
    #expect(store.filteredDocuments(matching: "Second").map(\.id) == ["2026-07-24"])
    #expect(store.filteredDocuments(matching: "July 25").map(\.id) == ["2026-07-25"])
}

@MainActor
@Test func contextStoreUsesExactCapturedEntryFormat() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-context-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let calendar = contextTestCalendar(timeZoneID: "Europe/Berlin")
    let store = ContextStore(
        directory: root,
        calendar: calendar,
        locale: Locale(identifier: "en_DE")
    )
    let first = contextTestDate(2026, 7, 24, 13, 36, calendar: calendar)
    let second = contextTestDate(2026, 7, 24, 14, 7, calendar: calendar)

    try store.append("Hallo", at: first)
    try store.append("Use *literal* Markdown.", at: second)

    let document = try #require(store.document(id: "2026-07-24"))
    #expect(
        document.markdown
            == """
            Friday, 24. July 2026 13:36 h **Hallo**

            Friday, 24. July 2026 14:07 h **Use \\*literal\\* Markdown.**

            """
    )
}

@MainActor
@Test func contextStoreSafelyMigratesOnlyGeneratedLegacyDocuments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-context-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let calendar = contextTestCalendar(timeZoneID: "Europe/Berlin")
    let store = ContextStore(
        directory: root,
        calendar: calendar,
        locale: Locale(identifier: "en_DE")
    )
    let generatedURL = root.appendingPathComponent("2026-07-24.md")
    let customURL = root.appendingPathComponent("2026-07-25.md")
    let generated = """
    # Friday, 24. July 2026

    ## 09:05

    First

    ## 15:30

    Use \\*literal\\* Markdown.
    """
    let custom = "# Personal notes\n\n## Keep this structure\n\nUnchanged.\n"
    try Data(generated.utf8).write(to: generatedURL)
    try Data(custom.utf8).write(to: customURL)

    store.reload()

    #expect(
        try String(contentsOf: generatedURL, encoding: .utf8)
            == """
            Friday, 24. July 2026 09:05 h **First**

            Friday, 24. July 2026 15:30 h **Use \\*literal\\* Markdown.**

            """
    )
    #expect(try String(contentsOf: customURL, encoding: .utf8) == custom)
}

@MainActor
@Test func contextStoreUsesConfiguredTimezoneForDateBoundaries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-context-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let berlin = contextTestCalendar(timeZoneID: "Europe/Berlin")
    let instant = Date(timeIntervalSince1970: 1_774_651_400) // 2026-03-27 23:10 UTC
    let store = ContextStore(directory: root, calendar: berlin, locale: Locale(identifier: "en_US"))

    try store.append("After midnight locally", at: instant)

    let expected = berlin.dateComponents([.year, .month, .day], from: instant)
    let expectedID = String(format: "%04d-%02d-%02d", expected.year!, expected.month!, expected.day!)
    #expect(store.documents.first?.id == expectedID)
}

@MainActor
@Test func contextStoreSavesTrashesAndRecreatesDailyDocument() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-context-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let calendar = contextTestCalendar(timeZoneID: "Europe/Berlin")
    let store = ContextStore(
        directory: root,
        calendar: calendar,
        locale: Locale(identifier: "en_US"),
        trashHandler: { try FileManager.default.removeItem(at: $0) }
    )
    let date = contextTestDate(2026, 7, 24, 12, 0, calendar: calendar)
    let document = try store.append("Original", at: date)

    try store.save(documentID: document.id, markdown: "# Edited\n\nSaved atomically.\n")
    #expect(store.document(id: document.id)?.markdown.contains("Saved atomically") == true)

    try store.moveToTrash(documentID: document.id)
    #expect(store.documents.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: document.url.path))

    try store.append("Recreated", at: date)
    #expect(store.document(id: document.id)?.markdown.contains("Recreated") == true)
}

@Test func markdownRichTextCodecRoundTripsSupportedFormatting() {
    let markdown = """
    # Heading

    A **bold**, *italic*, `code`, and [link](https://example.com).

    - One
    - Two

    1. First

    > Quote
    """
    let richText = MarkdownRichTextCodec.attributedString(from: markdown)
    let output = MarkdownRichTextCodec.markdown(from: richText)

    #expect(output.contains("# Heading"))
    #expect(output.contains("**bold**"))
    #expect(output.contains("*italic*"))
    #expect(output.contains("`code`"))
    #expect(output.contains("[link](https://example.com)"))
    #expect(output.contains("- One"))
    #expect(output.contains("1. First"))
    #expect(output.contains("> Quote"))
}

@Test func markdownRichTextCodecPreservesVisibleBlockSeparators() {
    let markdown = """
    # Heading

    First paragraph.

    - One
    - Two
    """

    let richText = MarkdownRichTextCodec.attributedString(from: markdown)
    let visible = String(richText.characters)

    #expect(visible == "Heading\n\nFirst paragraph.\n\nOne\nTwo")
    #expect(MarkdownRichTextCodec.markdown(from: richText).contains("- One\n- Two"))
}

@Test func richTextListFormatterFormatsParagraphsAndTogglesOff() {
    var richText = MarkdownRichTextCodec.attributedString(
        from: "**One**\n\nTwo\n\nThree"
    )
    let twoRange = String(richText.characters).range(of: "Two")!
    let insertionOffset = String(richText.characters).distance(
        from: String(richText.characters).startIndex,
        to: twoRange.lowerBound
    )
    let insertion = richText.characters.index(
        richText.startIndex,
        offsetBy: insertionOffset
    )

    RichTextListFormatter.toggle(
        .bulleted,
        in: &richText,
        selection: .insertionPoint(insertion),
        identity: 100
    )
    var markdown = MarkdownRichTextCodec.markdown(from: richText)
    #expect(markdown.contains("**One**"))
    #expect(markdown.contains("- Two"))
    #expect(!markdown.contains("- Three"))

    RichTextListFormatter.toggle(
        .bulleted,
        in: &richText,
        selection: .insertionPoint(insertion),
        identity: 200
    )
    markdown = MarkdownRichTextCodec.markdown(from: richText)
    #expect(!markdown.contains("- Two"))
}

@Test func richTextListFormatterNumbersEverySelectedParagraph() {
    var richText = MarkdownRichTextCodec.attributedString(
        from: "**One**\n\nTwo\n\nThree"
    )

    RichTextListFormatter.toggle(
        .numbered,
        in: &richText,
        selection: .ranges([richText.startIndex..<richText.endIndex]),
        identity: 300
    )

    let markdown = MarkdownRichTextCodec.markdown(from: richText)
    #expect(markdown.contains("1. **One**"))
    #expect(markdown.contains("2. Two"))
    #expect(markdown.contains("3. Three"))
}

@Test func markdownRichTextCodecNormalizesUnsupportedMarkdownWithoutCrashing() {
    let markdown = """
    | Name | Value |
    | --- | --- |
    | Current | Context |
    """
    let richText = MarkdownRichTextCodec.attributedString(from: markdown)
    let output = MarkdownRichTextCodec.markdown(from: richText)

    #expect(output.contains("Name"))
    #expect(output.contains("Current"))
    #expect(output.contains("Context"))
}

@Test func contextRecordingSkipsCurrentsOwnEditor() {
    #expect(
        !DictationCoordinator.shouldRecordContext(
            targetProcessIdentifier: 42,
            currentProcessIdentifier: 42
        )
    )
    #expect(
        DictationCoordinator.shouldRecordContext(
            targetProcessIdentifier: 7,
            currentProcessIdentifier: 42
        )
    )
    #expect(
        DictationCoordinator.shouldRecordContext(
            targetProcessIdentifier: nil,
            currentProcessIdentifier: 42
        )
    )
}
