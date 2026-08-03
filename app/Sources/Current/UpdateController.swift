import AppKit
import CoreGraphics
import CurrentCore
import OSLog
import Sparkle

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private static let productionMode = "production"
    private static let pollInterval = Duration.seconds(15)
    private static let logger = Logger(
        subsystem: "com.emilianscheel.current",
        category: "Updates"
    )

    static var updatesEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CurrentUpdateMode")
            as? String == productionMode
    }

    private weak var runtime: AppRuntime?
    private var updaterController: SPUStandardUpdaterController!
    private var pendingInstallation: (() -> Void)?
    private var installationTask: Task<Void, Never>?
    private var installationGate = AutomaticUpdateInstallationGate()

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    deinit {
        installationTask?.cancel()
    }

    func start(runtime: AppRuntime) {
        guard Self.updatesEnabled else { return }
        self.runtime = runtime
        updaterController.startUpdater()
        // Production updates are intentionally mandatory. Re-assert these
        // values so preferences written by an older Sparkle integration cannot
        // disable checks, background downloads, or the privacy guarantee.
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = true
        updaterController.updater.sendsSystemProfile = false
    }

    func checkForUpdates() {
        guard Self.updatesEnabled else { return }
        updaterController.checkForUpdates(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        pendingInstallation = immediateInstallHandler
        installationGate = AutomaticUpdateInstallationGate()
        installationTask?.cancel()
        installationTask = Task { @MainActor [weak self] in
            await self?.waitForSafeInstallationWindow()
        }
        Self.logger.info(
            "Update build \(item.versionString, privacy: .public) is ready and waiting for a safe idle window."
        )
        return true
    }

    private func waitForSafeInstallationWindow() async {
        while !Task.isCancelled, pendingInstallation != nil {
            let idleTime = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: .null
            )
            if runtime?.canInstallAutomaticUpdate(
                secondsSinceUserInput: idleTime,
                gate: &installationGate
            ) == true {
                let installation = pendingInstallation
                pendingInstallation = nil
                installationTask = nil
                Self.logger.info(
                    "Installing the verified update during a safe idle window."
                )
                installation?()
                return
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
