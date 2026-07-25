import AppKit
import CurrentCore
import Observation
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
    var settings = SettingsStore.shared
    let permissions = PermissionManager()
    let model = ModelManager()
    let contextStore = ContextStore()
    let intelligence = AppleFoundationModelProvider()
    @ObservationIgnored lazy var contextRepository = ContextRepository(
        store: contextStore,
        intelligence: intelligence
    )
    @ObservationIgnored lazy var screenContext = ScreenContextCoordinator(
        repository: contextRepository,
        framesPerSecond: settings.contextCaptureFramesPerSecond
    )
    @ObservationIgnored lazy var coordinator = VoiceInteractionCoordinator(
        settings: settings,
        model: model,
        intelligence: intelligence,
        contextRepository: contextRepository
    )
    let hardware = HardwareChecker().current()
    @ObservationIgnored lazy var overlay = NotchOverlayController(audio: coordinator.audio, settings: settings)
    @ObservationIgnored lazy var onboarding = OnboardingController(runtime: self)
    @ObservationIgnored lazy var context = ContextWindowController(runtime: self, store: contextStore)
    @ObservationIgnored private var auxiliaryWindowIDs: Set<UUID> = []

    init() {
        contextStore.reload()
        try? contextStore.closeAppSessions(at: Date())
        coordinator.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.overlay.show(
                phase: phase,
                targetApplication: self.coordinator.insertion.targetApplicationPresentation,
                editingWordCount: self.coordinator.insertion.currentContext.selectedWordCount,
                partialTranscript: self.coordinator.partialTranscription
            )
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
        coordinator.onMonitoringChange = { [weak self] active in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if active,
                   self.settings.continuousContextEnabled,
                   self.permissions.snapshot().screenRecording.isGranted {
                    try? await self.screenContext.start()
                } else {
                    await self.screenContext.stop()
                }
            }
        }
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
        runtime.model.prepareIfNeeded()

        if runtime.hardware.isSupported {
            if runtime.permissions.snapshot().inputMonitoring.isGranted { runtime.coordinator.startMonitoring() }
            if !runtime.settings.onboardingComplete || !runtime.permissions.snapshot().allGranted || !runtime.model.hasInstalledSnapshot {
                runtime.onboarding.show()
            }
        } else {
            runtime.onboarding.showUnsupported()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime?.onboarding.refreshPermissions()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isFinishingTermination, let runtime else {
            return .terminateNow
        }
        isFinishingTermination = true
        runtime.context.flush()
        Task {
            await runtime.screenContext.stop()
            runtime.coordinator.stopMonitoring()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.context.flush()
    }
}
