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

@Test func audioAccumulatorTransfersAndClearsSamples() {
    let accumulator = AudioSampleAccumulator()
    accumulator.append([0.1, 0.2])
    accumulator.append([0.3])
    #expect(accumulator.take() == [0.1, 0.2, 0.3])
    #expect(accumulator.take().isEmpty)
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

@Test func partialModelSnapshotIsNotReady() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-model-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let required = [
        "parakeet_unified_encoder_int8.mlmodelc/coremldata.bin",
        "parakeet_unified_decoder.mlmodelc/coremldata.bin",
        "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin",
        "vocab.json",
        "metadata.json",
    ]
    for relativePath in required {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("complete".utf8).write(to: file)
    }
    #expect(ModelSnapshotValidator.isComplete(at: root))

    let partial = root.appendingPathComponent("parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin.partial")
    try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("unfinished".utf8).write(to: partial)
    #expect(!ModelSnapshotValidator.isComplete(at: root))
}

@Test func overlayLayoutAttachesToPhysicalNotch() {
    let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    let notch = CGRect(x: 656, y: 950, width: 200, height: 32)
    let layout = OverlayLayout(screenFrame: screen, safeAreaTop: 32, notchBounds: notch)

    #expect(layout.attachment == .notch)
    #expect(layout.collapsedSize == CGSize(width: 200, height: 32))
    #expect(layout.expandedSize == CGSize(width: 360, height: 50))
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
    let granted = PermissionSnapshot(microphone: .granted, accessibility: .granted, inputMonitoring: .granted)
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
