import AppKit
import CurrentCore
import Observation
import OSLog
import ServiceManagement
import SwiftUI

@main
struct CurrentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            if let runtime = appDelegate.runtime {
                SettingsView(runtime: runtime)
                    .frame(minWidth: 620, minHeight: 520)
            } else {
                ProgressView().frame(width: 620, height: 520)
            }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
@Observable
final class AppRuntime {
    @ObservationIgnored private static let logger = Logger(
        subsystem: "com.emilianscheel.current",
        category: "ContextWorkerMode"
    )
    var settings = SettingsStore.shared
    let permissions = PermissionManager()
    let model = ModelManager()
    let contextWorker = ContextWorkerClient()
    let contextStore = ContextStore()
    let conversationContext = ConversationContext()
    @ObservationIgnored lazy var retrievalIndex = ContextRetrievalIndex(
        databaseURL: contextStore.directory.appendingPathComponent("Context Search.sqlite")
    )
    let appleIntelligence = AppleFoundationModelProvider()
    @ObservationIgnored lazy var contextModel = GemmaContextModelManager(
        worker: contextWorker
    )
    @ObservationIgnored lazy var contextRepository = ContextRepository(
        store: contextStore,
        structurer: contextModel,
        retrievalIndex: retrievalIndex
    )
    @ObservationIgnored lazy var screenContext = ScreenContextCoordinator(
        repository: contextRepository,
        ocr: XPCVisionOCRProvider(client: contextWorker),
        worker: contextWorker
    )
    @ObservationIgnored lazy var promptContextPreparer =
        LivePromptContextPreparer(
            repository: contextRepository,
            screenContext: screenContext,
            conversationContext: conversationContext
        )
    @ObservationIgnored lazy var intelligence = HybridLocalIntelligenceProvider(
        primary: appleIntelligence,
        fallback: XPCGemmaPromptProvider(client: contextWorker)
    )
    @ObservationIgnored lazy var intentRouter = HybridVoiceIntentRouter(
        primary: AppleVoiceIntentRouter(),
        fallback: GemmaVoiceIntentRouter(client: contextWorker)
    )
    @ObservationIgnored lazy var coordinator = VoiceInteractionCoordinator(
        settings: settings,
        model: model,
        intelligence: intelligence,
        intentRouter: intentRouter,
        contextRepository: contextRepository,
        promptContextPreparer: promptContextPreparer,
        conversationContext: conversationContext
    )
    let hardware = HardwareChecker().current()
    @ObservationIgnored lazy var overlay = NotchOverlayController(audio: coordinator.audio, settings: settings)
    @ObservationIgnored lazy var onboarding = OnboardingController(runtime: self)
    @ObservationIgnored lazy var context = ContextWindowController(runtime: self, store: contextStore)
    @ObservationIgnored lazy var usageMonitor = UsageMetricsMonitor(
        worker: contextWorker
    )
    @ObservationIgnored lazy var usage = UsageStatisticsWindowController(
        runtime: self
    )
    @ObservationIgnored lazy var about = AboutWindowController(runtime: self)
    @ObservationIgnored private var auxiliaryWindowIDs: Set<UUID> = []
    @ObservationIgnored private var phaseUpdateGeneration = UUID()
    @ObservationIgnored private var promptMemoryPressureSource:
        DispatchSourceMemoryPressure?
    @ObservationIgnored private var permissionMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var lastPermissionSnapshot: PermissionSnapshot?
    private(set) var inputMonitoringRestartRequired = false

    init() {
        contextStore.reload()
        scheduleRetrievalReindex()
        contextStore.onDocumentsChanged = { [weak self] _ in
            self?.scheduleRetrievalReindex()
        }
        let promptMemoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        promptMemoryPressureSource.setEventHandler { [weak self] in
            Task { await self?.intelligence.discardPromptCaches() }
        }
        promptMemoryPressureSource.resume()
        self.promptMemoryPressureSource = promptMemoryPressureSource
        try? contextStore.closeAppSessions(at: Date())
        coordinator.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            let interactionActive = phase != .idle
            let generation = UUID()
            self.phaseUpdateGeneration = generation
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.screenContext.setForegroundInteractionActive(
                    interactionActive
                )
                await self.finishDeferredContextWorkerDisableIfNeeded()
                guard self.phaseUpdateGeneration == generation else { return }
                self.overlay.show(
                    phase: phase,
                    targetApplication: self.coordinator.insertion.targetApplicationPresentation,
                    editingWordCount: self.coordinator.insertion.currentContext.selectedWordCount,
                    partialTranscript: self.coordinator.partialTranscription
                )
            }
        }
        coordinator.onPartialTranscriptionChange = { [weak self] partial in
            guard let self else { return }
            self.overlay.show(
                phase: self.coordinator.phase,
                targetApplication: self.coordinator.insertion.targetApplicationPresentation,
                editingWordCount: self.coordinator.insertion.currentContext.selectedWordCount,
                partialTranscript: partial
            )
        }
        coordinator.onSuccessfulTranscription = { [weak self] text, date in
            self?.context.append(text, at: date)
        }
        coordinator.onTranscriptionCompleted = { [weak self] date in
            self?.usageMonitor.recordSuccessfulTranscription(at: date)
        }
        coordinator.shortcut.onKeyboardActivity = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      let target = InsertionService
                          .frontmostContextCaptureTarget(
                              includeWindowTitle: false
                          ) else {
                    return
                }
                await self.screenContext.scheduleCapture(
                    trigger: .typingSettled,
                    target: target
                )
            }
        }
        coordinator.shortcut.onUserActivity = { [weak self] kind in
            guard kind == .mouse else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let target = InsertionService
                          .frontmostContextCaptureTarget(
                              includeWindowTitle: false
                          ) else { return }
                await self.screenContext.recordActivity(.init(
                    target: target,
                    kind: kind
                ))
            }
        }
        coordinator.shortcut.onPermissionLoss = { [weak self] permission in
            Task { @MainActor [weak self] in
                await self?.handlePermissionLoss(permission)
            }
        }
        coordinator.onTextCommitted = { [weak self] target in
            Task { @MainActor [weak self] in
                await self?.screenContext.scheduleCapture(
                    trigger: .textCommitted,
                    target: target
                )
            }
        }
        coordinator.onMonitoringChange = { [weak self] active in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if active {
                    await self.reconcileContinuousContext(
                        snapshot: self.permissions.snapshot()
                    )
                } else {
                    if self.inputMonitoringRestartRequired {
                        await self.screenContext.suspendForPermissionLoss(
                            .inputMonitoring
                        )
                    } else {
                        await self.screenContext.suspendBackgroundCapture()
                    }
                    await self.contextModel.unload()
                }
            }
        }
    }

    func startPermissionMonitoring() {
        guard permissionMonitorTask == nil else { return }
        let initial = permissions.snapshot()
        lastPermissionSnapshot = initial
        permissionMonitorTask = Task { @MainActor [weak self] in
            await self?.refreshPermissionState(force: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.refreshPermissionState()
            }
        }
    }

    func stopPermissionMonitoring() {
        permissionMonitorTask?.cancel()
        permissionMonitorTask = nil
    }

    func effectivePermissionSnapshot() -> PermissionSnapshot {
        var snapshot = permissions.snapshot()
        if inputMonitoringRestartRequired {
            snapshot.inputMonitoring = .denied
        }
        return snapshot
    }

    func refreshPermissionState(force: Bool = false) async {
        let current = permissions.snapshot()
        let previous = lastPermissionSnapshot
        guard force || previous != current else { return }
        lastPermissionSnapshot = current

        let revoked = previous.map {
            current.revokedPermissions(since: $0)
        } ?? []
        let restored = previous.map {
            current.restoredPermissions(since: $0)
        } ?? []
        if revoked.contains(.microphone) {
            coordinator.cancel()
        }
        if revoked.contains(.inputMonitoring) {
            await handlePermissionLoss(.inputMonitoring)
        }
        if restored.contains(.inputMonitoring) {
            inputMonitoringRestartRequired = true
            onboarding.requireInputMonitoringRestart()
        }

        if !current.accessibility.isGranted {
            await screenContext.suspendForPermissionLoss(.accessibility)
        } else if !current.screenRecording.isGranted {
            await screenContext.suspendForPermissionLoss(.screenRecording)
        } else if !current.inputMonitoring.isGranted
                    || inputMonitoringRestartRequired {
            await screenContext.suspendForPermissionLoss(.inputMonitoring)
        } else {
            await reconcileContinuousContext(snapshot: current)
        }
    }

    private func handlePermissionLoss(_ permission: PermissionKind) async {
        guard permission == .inputMonitoring else { return }
        if !inputMonitoringRestartRequired {
            inputMonitoringRestartRequired = true
            onboarding.requireInputMonitoringRestart()
            coordinator.stopMonitoring()
        }
        await screenContext.suspendForPermissionLoss(.inputMonitoring)
    }

    private func reconcileContinuousContext(
        snapshot: PermissionSnapshot
    ) async {
        guard settings.contextWorkerEnabled,
              settings.isEnabled,
              settings.continuousContextEnabled else {
            await screenContext.suspendBackgroundCapture()
            return
        }
        if !snapshot.accessibility.isGranted {
            await screenContext.suspendForPermissionLoss(.accessibility)
        } else if !snapshot.screenRecording.isGranted {
            await screenContext.suspendForPermissionLoss(.screenRecording)
        } else if !snapshot.inputMonitoring.isGranted
                    || inputMonitoringRestartRequired {
            await screenContext.suspendForPermissionLoss(.inputMonitoring)
        } else {
            contextModel.prepareIfNeeded()
            try? await screenContext.start()
        }
    }

    func scheduleRetrievalReindex() {
        guard ContextEngineeringFeatureFlags.localRetrieval else { return }
        let documents = contextStore.documents
        Task.detached(priority: .utility) { [retrievalIndex] in
            try? await retrievalIndex.synchronize(
                documents: documents,
                buildSemanticVectors: true
            )
        }
    }

    func setContextWorkerEnabled(_ enabled: Bool) {
        guard settings.contextWorkerEnabled != enabled else { return }
        settings.contextWorkerEnabled = enabled
        Task { @MainActor [weak self] in
            await self?.applyContextWorkerMode(enabled)
        }
    }

    func applyContinuousContextPreference() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileContinuousContext(
                snapshot: self.permissions.snapshot()
            )
            await self.finishDeferredContextWorkerDisableIfNeeded()
        }
    }

    private func applyContextWorkerMode(_ enabled: Bool) async {
        Self.logger.notice(
            "Context worker mode changed to \(enabled ? "rich" : "fast", privacy: .public)"
        )
        if enabled {
            contextModel.prepareIfNeeded()
            await intentRouter.setEnabled(settings.isEnabled)
            applyContinuousContextPreference()
            return
        }
        await screenContext.suspendBackgroundCapture()
        await finishDeferredContextWorkerDisableIfNeeded()
    }

    private func finishDeferredContextWorkerDisableIfNeeded() async {
        guard !settings.contextWorkerEnabled,
              coordinator.currentExecutionMode != .rich else { return }
        await intentRouter.setEnabled(false)
        await contextModel.unload(force: true)
    }

    func setAuxiliaryWindow(_ id: UUID, visible: Bool) {
        if visible { auxiliaryWindowIDs.insert(id) }
        else { auxiliaryWindowIDs.remove(id) }
        applyDockPolicy()
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(!auxiliaryWindowIDs.isEmpty || settings.showDockIcon ? .regular : .accessory)
    }

    func applyLaunchAtLogin() {
        do {
            if settings.launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func relaunch() {
        let bundle = Bundle.main.bundleURL
        let helper = bundle.appendingPathComponent("Contents/Helpers/CurrentRelauncher")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        let process = Process()
        process.executableURL = helper
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: AppRuntime?
    private var statusController: StatusItemController?
    private var isFinishingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = AppRuntime()
        self.runtime = runtime
        runtime.applyDockPolicy()
        statusController = StatusItemController(runtime: runtime)
        runtime.startPermissionMonitoring()
        runtime.usageMonitor.start()
        runtime.model.prepareIfNeeded()
        if runtime.settings.contextWorkerEnabled {
            runtime.contextModel.prepareIfNeeded()
        }

        if runtime.hardware.isSupported {
            if runtime.permissions.snapshot().inputMonitoring.isGranted { runtime.coordinator.startMonitoring() }
            if !runtime.settings.onboardingComplete
                || !runtime.permissions.snapshot().allGranted(
                    contextWorkerEnabled:
                        runtime.settings.contextWorkerEnabled
                )
                || !runtime.model.hasInstalledSnapshot
                || (runtime.settings.contextWorkerEnabled
                    && !runtime.contextModel.hasInstalledSnapshot) {
                runtime.onboarding.show()
            }
        } else {
            runtime.onboarding.showUnsupported()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime?.onboarding.refreshPermissions()
        Task { await runtime?.refreshPermissionState(force: true) }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isFinishingTermination, let runtime else {
            return .terminateNow
        }
        isFinishingTermination = true
        runtime.stopPermissionMonitoring()
        runtime.context.flush()
        Task {
            runtime.coordinator.stopMonitoring()
            await runtime.usageMonitor.stop()
            await runtime.screenContext.stop()
            await runtime.contextWorker.unload(force: true)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.context.flush()
    }
}
