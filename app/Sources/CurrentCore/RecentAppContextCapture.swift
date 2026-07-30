import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import OSLog
@preconcurrency import ScreenCaptureKit

@MainActor
public final class AccessibilityContextSource: AccessibilityContextProviding {
    private struct ApplicationDescriptor: Sendable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let applicationName: String
        let isFrontmost: Bool
    }

    private struct SnapshotResult: Sendable {
        let observation: ContextObservation?
        let coverage: AccessibilityCoverage
    }

    public var onActivity: ((RecentApplicationActivity) -> Void)?
    public var onTermination: ((pid_t) -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var coverageByKey: [ContextCoverageKey: AccessibilityCoverage] = [:]

    public init() {}

    public func start() {
        guard workspaceTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(observe(
            NSWorkspace.didLaunchApplicationNotification,
            center: center,
            kind: .launch
        ))
        workspaceTokens.append(observe(
            NSWorkspace.didActivateApplicationNotification,
            center: center,
            kind: .activation
        ))
        workspaceTokens.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = Self.application(from: notification)
                else { return }
                Task { @MainActor [weak self] in
                    self?.removeObserver(
                        processIdentifier: application.processIdentifier
                    )
                    self?.onTermination?(application.processIdentifier)
                }
            }
        )
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           !isExcluded(frontmost),
           let target = Self.target(for: frontmost) {
            installObserver(for: frontmost)
            onActivity?(.init(target: target, kind: .activation))
        }
    }

    public func stop() {
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceTokens.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observers.removeAll()
        coverageByKey.removeAll()
    }

    public func retainObservers(for processIdentifiers: Set<pid_t>) {
        for processIdentifier in observers.keys
        where !processIdentifiers.contains(processIdentifier) {
            removeObserver(processIdentifier: processIdentifier)
        }
    }

    public func refreshCoverage(
        for target: ContextCaptureTarget
    ) async -> ContextCaptureDecision {
        guard let application = NSRunningApplication(
            processIdentifier: target.processIdentifier
        ), isEligible(application), !isExcluded(application) else {
            return .unavailable
        }
        installObserver(for: application)
        let descriptor = ApplicationDescriptor(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName ?? target.applicationName,
            isFrontmost: application.isActive
        )
        let results = await Task.detached(priority: .background) {
            Self.snapshotResults(
                descriptor,
                preferredWindowTitle: target.windowTitle
            )
        }.value
        guard !Task.isCancelled else { return .unavailable }
        for result in results {
            coverageByKey[result.coverage.key] = result.coverage
        }
        guard let result = Self.matchingResult(results, target: target) else {
            return .screenshotFallback(.init(
                processIdentifier: target.processIdentifier,
                windowIdentifier: target.windowIdentifier,
                windowTitle: target.windowTitle
            ))
        }
        guard result.coverage.isUseful, let observation = result.observation
        else {
            return .screenshotFallback(result.coverage.key)
        }
        return .accessibility(observation)
    }

    public func coverage(
        for target: ContextCaptureTarget
    ) async -> AccessibilityCoverage? {
        let exact = ContextCoverageKey(
            processIdentifier: target.processIdentifier,
            windowIdentifier: target.windowIdentifier,
            windowTitle: target.windowTitle
        )
        if let result = coverageByKey[exact] { return result }
        let matches = coverageByKey.values.filter {
            $0.key.processIdentifier == target.processIdentifier
                && (target.windowTitle == nil
                    || $0.key.windowTitle == target.windowTitle)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func observe(
        _ name: Notification.Name,
        center: NotificationCenter,
        kind: ContextActivityKind
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] notification in
            guard let application = Self.application(from: notification)
            else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isExcluded(application),
                      let target = Self.target(for: application) else { return }
                self.installObserver(for: application)
                self.onActivity?(.init(target: target, kind: kind))
            }
        }
    }

    private func installObserver(for application: NSRunningApplication) {
        guard !isExcluded(application), isEligible(application) else { return }
        let processIdentifier = application.processIdentifier
        guard observers[processIdentifier] == nil else { return }
        var observer: AXObserver?
        let result = AXObserverCreate(
            processIdentifier,
            { _, element, _, pointer in
                guard let pointer else { return }
                let source = Unmanaged<AccessibilityContextSource>
                    .fromOpaque(pointer).takeUnretainedValue()
                var processIdentifier: pid_t = 0
                guard AXUIElementGetPid(element, &processIdentifier) == .success
                else { return }
                Task { @MainActor in
                    guard let application = NSRunningApplication(
                        processIdentifier: processIdentifier
                    ), let target = AccessibilityContextSource.target(
                        for: application
                    ), !source.isExcluded(application) else { return }
                    source.onActivity?(.init(
                        target: target,
                        kind: .accessibility
                    ))
                }
            },
            &observer
        )
        guard result == .success, let observer else { return }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        for notification in [
            kAXFocusedWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXWindowCreatedNotification,
            kAXTitleChangedNotification,
            kAXValueChangedNotification,
            kAXSelectedTextChangedNotification,
        ] {
            _ = AXObserverAddNotification(
                observer,
                applicationElement,
                notification as CFString,
                pointer
            )
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        observers[processIdentifier] = observer
    }

    private func removeObserver(processIdentifier: pid_t) {
        coverageByKey = coverageByKey.filter {
            $0.key.processIdentifier != processIdentifier
        }
        guard let observer = observers.removeValue(forKey: processIdentifier)
        else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func isExcluded(_ application: NSRunningApplication) -> Bool {
        ContextApplicationExclusions.contains(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    private func isEligible(_ application: NSRunningApplication) -> Bool {
        !application.isTerminated
            && !application.isHidden
            && application.activationPolicy != .prohibited
    }

    private nonisolated static func application(
        from notification: Notification
    ) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
    }

    private static func target(
        for application: NSRunningApplication
    ) -> ContextCaptureTarget? {
        guard !application.isTerminated else { return nil }
        return ContextCaptureTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName ?? "Application"
        )
    }

    private nonisolated static func snapshotResults(
        _ application: ApplicationDescriptor,
        preferredWindowTitle: String?
    ) -> [SnapshotResult] {
        let appElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        let allWindows = elementsAttribute(kAXWindowsAttribute, from: appElement)
        var focusedWindow: AXUIElement?
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue {
            focusedWindow = (focusedValue as! AXUIElement)
        }
        let windows: [AXUIElement]
        if let preferredWindowTitle,
           let preferred = allWindows.first(where: {
               stringAttribute(kAXTitleAttribute, from: $0)
                    == preferredWindowTitle
           }) {
            windows = [preferred]
        } else if let focusedWindow {
            windows = [focusedWindow]
        } else {
            windows = Array(allWindows.prefix(1))
        }
        let attemptedAt = Date()
        return windows.enumerated().map { index, window in
            let title = stringAttribute(kAXTitleAttribute, from: window)
            let blocks = textBlocks(in: window)
            let key = ContextCoverageKey(
                processIdentifier: application.processIdentifier,
                windowTitle: title ?? "__untitled:\(index)"
            )
            let count = blocks.reduce(0) {
                $0 + ContextObservation.normalized($1.text).count
            }
            let useful = blocks.count >= 3 || count >= 40
            return SnapshotResult(
                observation: blocks.isEmpty ? nil : ContextObservation(
                    processIdentifier: application.processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.applicationName,
                    windowTitle: title,
                    isFrontmost: application.isFrontmost,
                    blocks: blocks
                ),
                coverage: AccessibilityCoverage(
                    key: key,
                    lastAttempt: attemptedAt,
                    lastUsefulObservation: useful ? attemptedAt : nil,
                    blockCount: blocks.count,
                    normalizedCharacterCount: count
                )
            )
        }
    }

    private nonisolated static func matchingResult(
        _ results: [SnapshotResult],
        target: ContextCaptureTarget
    ) -> SnapshotResult? {
        if let title = target.windowTitle, !title.isEmpty,
           let match = results.first(where: {
               $0.coverage.key.windowTitle == title
           }) {
            return match
        }
        return results.count == 1 ? results[0] : nil
    }

    private nonisolated static func textBlocks(
        in root: AXUIElement
    ) -> [ContextTextBlock] {
        var queue = [root]
        var index = 0
        var visited = 0
        var seen: Set<String> = []
        var blocks: [ContextTextBlock] = []
        while index < queue.count, visited < 500, blocks.count < 160 {
            if Task.isCancelled { break }
            let element = queue[index]
            index += 1
            visited += 1
            for attribute in [
                kAXTitleAttribute,
                kAXValueAttribute,
                kAXDescriptionAttribute,
                kAXHelpAttribute,
            ] {
                guard let text = stringAttribute(attribute, from: element)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text.count <= 8_000 else { continue }
                let normalized = ContextObservation.normalized(text)
                guard seen.insert(normalized).inserted else { continue }
                blocks.append(.init(text: text, source: .accessibility))
            }
            queue.append(contentsOf: elementsAttribute(
                kAXChildrenAttribute,
                from: element
            ))
        }
        return blocks
    }

    private nonisolated static func stringAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, name as CFString, &value
        ) == .success else { return nil }
        return value as? String
    }

    private nonisolated static func elementsAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, name as CFString, &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}

@MainActor
@Observable
public final class ScreenContextCoordinator: ScreenContextProviding {
    public private(set) var backgroundState: ContextBackgroundState = .idle
    public private(set) var missingPermission: PermissionKind?

    private static let maximumCaptureLongEdge = 1_600
    private static let workerIdleLifetime: Duration = .seconds(5 * 60)
    private let repository: ContextRepository
    private let ocr: any OCRProviding
    private let worker: ContextWorkerClient?
    private let policy: ContextBackgroundPolicy
    private let accessibility = AccessibilityContextSource()
    private let signposter = OSSignposter(
        subsystem: "com.emilianscheel.current",
        category: "ContextBackground"
    )
    private var ledger: RecentApplicationLedger
    private var schedulerTask: Task<Void, Never>?
    private var workerIdleTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var imageHashes: [String: UInt64] = [:]
    private var lastUserInputAt = Date.distantPast
    private var isRunning = false
    private var isSleeping = false
    private var foregroundInteractionActive = false

    public init(
        repository: ContextRepository,
        ocr: any OCRProviding,
        worker: ContextWorkerClient? = nil,
        policy: ContextBackgroundPolicy = .init()
    ) {
        self.repository = repository
        self.ocr = ocr
        self.worker = worker
        self.policy = policy
        ledger = RecentApplicationLedger(policy: policy)
        accessibility.onActivity = { [weak self] activity in
            Task { @MainActor [weak self] in
                await self?.recordActivity(activity)
            }
        }
        accessibility.onTermination = { [weak self] processIdentifier in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ledger.remove(processIdentifier: processIdentifier)
                await self.repository.applicationTerminated(
                    processIdentifier: processIdentifier
                )
                self.armScheduler()
            }
        }
        worker?.onStateChange = { [weak self] state in
            if state == .degraded, self?.missingPermission == nil {
                self?.backgroundState = .degraded
            }
        }
    }

    public func start() async throws {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            await suspendForPermissionLoss(.accessibility)
            throw CurrentError.permissionMissing(.accessibility)
        }
        guard CGPreflightScreenCaptureAccess() else {
            await suspendForPermissionLoss(.screenRecording)
            throw CurrentError.permissionMissing(.screenRecording)
        }
        guard CGPreflightListenEventAccess() else {
            await suspendForPermissionLoss(.inputMonitoring)
            throw CurrentError.permissionMissing(.inputMonitoring)
        }
        missingPermission = nil
        await repository.resumeBackgroundProcessing()
        isRunning = true
        isSleeping = false
        accessibility.start()
        installNotifications()
        armScheduler()
    }

    public func stop() async {
        await suspendBackgroundCapture()
        await worker?.cancelAll()
        await worker?.unload()
        await repository.stop()
        backgroundState = .idle
    }

    /// Stops scheduling and cancels only background work. Interactive requests
    /// already in flight are deliberately left alone and can finish safely.
    public func suspendBackgroundCapture() async {
        missingPermission = nil
        await suspendBackgroundCapture(state: .idle)
    }

    public func suspendForPermissionLoss(_ permission: PermissionKind) async {
        missingPermission = permission
        await suspendBackgroundCapture(state: .permissionRequired)
    }

    private func suspendBackgroundCapture(
        state: ContextBackgroundState
    ) async {
        isRunning = false
        schedulerTask?.cancel()
        schedulerTask = nil
        workerIdleTask?.cancel()
        workerIdleTask = nil
        accessibility.stop()
        removeNotifications()
        await repository.suspendBackgroundProcessing()
        await worker?.cancelBackgroundWork()
        backgroundState = state
    }

    public func scheduleCapture(
        trigger: ContextCaptureTrigger,
        target: ContextCaptureTarget?
    ) async {
        guard let target else { return }
        let kind: ContextActivityKind
        switch trigger {
        case .backgroundRefresh: kind = .accessibility
        case .typingSettled: kind = .typingSettled
        case .textCommitted: kind = .textCommitted
        }
        await recordActivity(.init(target: target, kind: kind))
    }

    public func recordActivity(
        _ activity: RecentApplicationActivity
    ) async {
        guard isRunning, !isSleeping,
              !isExcluded(activity.target) else { return }
        lastUserInputAt = activity.occurredAt
        guard ledger.record(activity) else { return }
        workerIdleTask?.cancel()
        workerIdleTask = nil
        let wasProcessing = backgroundState == .processing
        schedulerTask?.cancel()
        if wasProcessing {
            await worker?.cancelBackgroundWork()
        }
        armScheduler()
    }

    public func setForegroundInteractionActive(_ active: Bool) async {
        foregroundInteractionActive = active
        guard isRunning else { return }
        if active {
            let wasProcessing = backgroundState == .processing
            backgroundState = .suspendedDuringDictation
            schedulerTask?.cancel()
            schedulerTask = nil
            if wasProcessing {
                await worker?.cancelBackgroundWork()
            }
        } else {
            backgroundState = .waitingForIdle
            lastUserInputAt = Date()
            armScheduler()
        }
    }

    public func refreshForPrompt(
        target: ContextCaptureTarget
    ) async throws -> ContextObservation? {
        guard !isExcluded(target),
              let application = NSRunningApplication(
                  processIdentifier: target.processIdentifier
              ),
              !application.isTerminated,
              !application.isHidden,
              Self.isPinnedWindowAvailable(target) else {
            return nil
        }
        await worker?.cancelBackgroundWork()
        if target.windowIdentifier != nil, target.windowTitle == nil {
            guard CGPreflightScreenCaptureAccess() else { return nil }
            return try await captureWindow(
                target,
                priority: .interactive,
                deduplicateImage: false
            )
        }
        let decision = await accessibility.refreshCoverage(for: target)
        try Task.checkCancellation()
        switch decision {
        case let .accessibility(observation):
            return observation
        case .screenshotFallback:
            guard CGPreflightScreenCaptureAccess() else { return nil }
            return try await captureWindow(
                target,
                priority: .interactive,
                deduplicateImage: false
            )
        case .unavailable:
            return nil
        }
    }

    private func armScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
        guard isRunning, !isSleeping, !foregroundInteractionActive else {
            return
        }
        let now = Date()
        guard let ledgerDate = ledger.nextWakeDate(at: now) else {
            backgroundState = .idle
            scheduleWorkerUnload()
            accessibility.retainObservers(for: [])
            return
        }
        accessibility.retainObservers(for: Set(ledger.entries.keys))
        let idleDate = lastUserInputAt.addingTimeInterval(policy.userIdleDelay)
        let wakeDate = max(ledgerDate, idleDate)
        backgroundState = wakeDate > now ? .waitingForIdle : .idle
        schedulerTask = Task { [weak self] in
            let delay = max(0, wakeDate.timeIntervalSinceNow)
            try? await Task.sleep(for: .milliseconds(Int64(delay * 1_000)))
            guard !Task.isCancelled, let self else { return }
            await self.runNextJob()
        }
    }

    private func runNextJob() async {
        schedulerTask = nil
        guard isRunning, !isSleeping, !foregroundInteractionActive else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastUserInputAt) >= policy.userIdleDelay
        else {
            armScheduler()
            return
        }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ![.serious, .critical].contains(
                  ProcessInfo.processInfo.thermalState
              ) else {
            backgroundState = .deferredForPower
            if let entry = ledger.nextEligible(at: now) {
                ledger.markDeferred(
                    processIdentifier: entry.target.processIdentifier,
                    until: now.addingTimeInterval(30)
                )
            }
            armScheduler()
            return
        }
        guard let entry = ledger.nextEligible(at: now) else {
            armScheduler()
            return
        }
        guard let application = NSRunningApplication(
            processIdentifier: entry.target.processIdentifier
        ), !application.isTerminated, !application.isHidden,
              application.activationPolicy != .prohibited,
              !isExcluded(entry.target) else {
            ledger.remove(processIdentifier: entry.target.processIdentifier)
            armScheduler()
            return
        }

        backgroundState = .processing
        let state = signposter.beginInterval("Context app job")
        do {
            try await process(entry.target)
            try Task.checkCancellation()
            ledger.markCompleted(
                processIdentifier: entry.target.processIdentifier,
                at: Date()
            )
            backgroundState = .idle
        } catch is CancellationError {
            signposter.endInterval("Context app job", state)
            armScheduler()
            return
        } catch {
            ledger.markDeferred(
                processIdentifier: entry.target.processIdentifier,
                until: Date().addingTimeInterval(30)
            )
            backgroundState = .degraded
        }
        signposter.endInterval("Context app job", state)
        armScheduler()
    }

    private func process(_ target: ContextCaptureTarget) async throws {
        let decision = await accessibility.refreshCoverage(for: target)
        try Task.checkCancellation()
        switch decision {
        case let .accessibility(observation):
            await repository.acceptAndProcess(observation)
        case .screenshotFallback:
            if let observation = try await captureWindow(target) {
                await repository.acceptAndProcess(observation)
            }
        case .unavailable:
            return
        }
    }

    private func captureWindow(
        _ target: ContextCaptureTarget,
        priority: ContextWorkerRequestPriority = .background,
        deduplicateImage: Bool = true
    ) async throws -> ContextObservation? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = resolveWindow(target, windows: content.windows),
              let application = window.owningApplication,
              !ContextApplicationExclusions.contains(
                  processIdentifier: application.processID,
                  bundleIdentifier: application.bundleIdentifier
              ) else { return nil }
        let descriptor = WindowContextDescriptor(
            windowIdentifier: window.windowID,
            processIdentifier: application.processID,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.applicationName,
            title: window.title,
            frame: .init(
                x: window.frame.origin.x,
                y: window.frame.origin.y,
                width: window.frame.width,
                height: window.frame.height
            ),
            isFrontmost: NSWorkspace.shared.frontmostApplication?
                .processIdentifier == application.processID
        )
        let configuration = Self.configuration(
            width: Int(window.frame.width),
            height: Int(window.frame.height)
        )
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
        try Task.checkCancellation()
        let hash = await Task.detached(priority: .background) {
            PerceptualImageHasher.hash(image)
        }.value
        let hashKey = "\(application.processID):\(window.windowID)"
        if deduplicateImage,
           let hash, let previous = imageHashes[hashKey],
           PerceptualImageHasher.isVisuallyEquivalent(previous, hash) {
            imageHashes[hashKey] = hash
            return nil
        }
        if let hash { imageHashes[hashKey] = hash }
        let blocks: [ContextTextBlock]
        if priority == .interactive,
           let interactiveOCR = ocr as? any InteractiveOCRProviding {
            blocks = try await interactiveOCR.recognizeTextInteractively(
                in: image
            )
        } else {
            blocks = try await ocr.recognizeText(in: image)
        }
        try Task.checkCancellation()
        guard !blocks.isEmpty else { return nil }
        return ContextObservation(
            processIdentifier: descriptor.processIdentifier,
            bundleIdentifier: descriptor.bundleIdentifier,
            applicationName: descriptor.applicationName,
            windowIdentifier: descriptor.windowIdentifier,
            windowTitle: descriptor.title,
            displayIdentifier: content.displays.first(where: {
                $0.frame.intersects(window.frame)
            })?.displayID,
            isFrontmost: descriptor.isFrontmost,
            blocks: blocks
        )
    }

    private func resolveWindow(
        _ target: ContextCaptureTarget,
        windows: [SCWindow]
    ) -> SCWindow? {
        let candidates = windows.filter { window in
            guard window.isOnScreen, window.frame.width > 1,
                  window.frame.height > 1,
                  let application = window.owningApplication else {
                return false
            }
            return application.processID == target.processIdentifier
                && !ContextApplicationExclusions.contains(
                    processIdentifier: application.processID,
                    bundleIdentifier: application.bundleIdentifier
                )
        }
        if let identifier = target.windowIdentifier {
            return candidates.first { $0.windowID == identifier }
        }
        if let title = target.windowTitle,
           let exact = candidates.first(where: { $0.title == title }) {
            return exact
        }
        return candidates.first
    }

    private func isExcluded(_ target: ContextCaptureTarget) -> Bool {
        ContextApplicationExclusions.contains(
            processIdentifier: target.processIdentifier,
            bundleIdentifier: target.bundleIdentifier
        )
    }

    private nonisolated static func isPinnedWindowAvailable(
        _ target: ContextCaptureTarget
    ) -> Bool {
        guard let identifier = target.windowIdentifier else { return true }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        return windows.contains { window in
            (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                == identifier
                && (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == target.processIdentifier
        }
    }

    private static func configuration(
        width: Int,
        height: Int
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let longest = max(1, max(width, height))
        let scale = longest > maximumCaptureLongEdge
            ? Double(maximumCaptureLongEdge) / Double(longest) : 1
        configuration.width = max(1, Int(Double(width) * scale))
        configuration.height = max(1, Int(Double(height) * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }

    private func installNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        notificationTokens.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.suspendForSleep() }
        })
        notificationTokens.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeAfterWake() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: Notification.Name(
                "NSProcessInfoPowerStateDidChangeNotification"
            ),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.armScheduler() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.armScheduler() }
        })
    }

    private func removeNotifications() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func suspendForSleep() {
        isSleeping = true
        schedulerTask?.cancel()
        schedulerTask = nil
        Task { await worker?.cancelAll() }
    }

    private func resumeAfterWake() {
        isSleeping = false
        lastUserInputAt = Date()
        armScheduler()
    }

    private func scheduleWorkerUnload() {
        guard workerIdleTask == nil, let worker else { return }
        workerIdleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.workerIdleLifetime)
            guard !Task.isCancelled, let self, self.ledger.entries.isEmpty
            else { return }
            await worker.unload()
            self.workerIdleTask = nil
        }
    }
}
