import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import CoreImage.CIFilterBuiltins
import CurrentCore
import Observation
import QuartzCore
import SwiftUI

@MainActor
@Observable
private final class PermissionGuidanceModel {
    var dropAccepted = false
    @ObservationIgnored let applicationURL: URL?
    @ObservationIgnored let applicationIcon: NSImage

    init(applicationURL: URL?, applicationIcon: NSImage) {
        self.applicationURL = applicationURL
        self.applicationIcon = applicationIcon
    }
}

@MainActor
final class PermissionGuidanceOverlayController: NSObject {
    private struct WindowObservation {
        let id: CGWindowID
        let frame: CGRect
        let processIdentifier: pid_t
        let ownerName: String
    }

    private struct PresentationGeometry: Equatable {
        let guideFrame: CGRect
        let focusFrames: [CGRect]
        let outlineFrame: CGRect?
        let guideVisible: Bool
        let grayscaleEnabled: Bool
        let behindWindowID: CGWindowID?

        func canInterpolate(to other: Self) -> Bool {
            focusFrames.count == other.focusFrames.count
                && (outlineFrame == nil) == (other.outlineFrame == nil)
                && guideVisible == other.guideVisible
                && grayscaleEnabled == other.grayscaleEnabled
                && behindWindowID == other.behindWindowID
        }

        func interpolated(to other: Self, progress: CGFloat) -> Self {
            Self(
                guideFrame: PermissionGuidanceMotion.interpolate(
                    from: guideFrame,
                    to: other.guideFrame,
                    progress: progress
                ),
                focusFrames: zip(focusFrames, other.focusFrames).map { pair in
                    PermissionGuidanceMotion.interpolate(
                        from: pair.0,
                        to: pair.1,
                        progress: progress
                    )
                },
                outlineFrame: outlineFrame.flatMap { start in
                    other.outlineFrame.map {
                        PermissionGuidanceMotion.interpolate(
                            from: start,
                            to: $0,
                            progress: progress
                        )
                    }
                },
                guideVisible: other.guideVisible,
                grayscaleEnabled: other.grayscaleEnabled,
                behindWindowID: other.behindWindowID
            )
        }
    }

    private let permissionSnapshot: () -> PermissionSnapshot
    private let dropAccepted: () -> Void
    private var kind: PermissionKind?
    private var trackingTask: Task<Void, Never>?
    private var blurPanels: [CGDirectDisplayID: PermissionBlurPanel] = [:]
    private var guidePanel: NSPanel?
    private var model: PermissionGuidanceModel?
    private var trackedWindowID: CGWindowID?
    private var startedAt = ContinuousClock.now
    private var missingSince: ContinuousClock.Instant?
    private var detectedListFrame: CGRect?
    private var lastListLookupAt: ContinuousClock.Instant?
    private var lastListLookupSettingsFrame: CGRect?
    private var lastSettingsGeometryChangeAt: ContinuousClock.Instant?
    private var displayLink: CADisplayLink?
    private var motionFrom: PresentationGeometry?
    private var motionTarget: PresentationGeometry?
    private var motionStartedAt: CFTimeInterval?
    private var presentedGeometry: PresentationGeometry?
    private var requiresGeometrySnap = true
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    init(
        permissionSnapshot: @escaping () -> PermissionSnapshot,
        dropAccepted: @escaping () -> Void
    ) {
        self.permissionSnapshot = permissionSnapshot
        self.dropAccepted = dropAccepted
        super.init()
    }

    func present(for kind: PermissionKind) {
        guard kind == .accessibility
                || kind == .screenRecording
                || kind == .inputMonitoring else {
            dismiss()
            return
        }

        dismiss()
        self.kind = kind
        startedAt = .now
        model = makeModel()
        installEventMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.trackedWindowID = nil
                self?.detectedListFrame = nil
                self?.lastListLookupAt = nil
                self?.lastListLookupSettingsFrame = nil
                self?.lastSettingsGeometryChangeAt = nil
                self?.resetMotion()
            }
        }
        trackingTask = Task { @MainActor [weak self] in
            await self?.trackSystemSettings()
        }
    }

    func dismiss() {
        trackingTask?.cancel()
        trackingTask = nil
        displayLink?.invalidate()
        displayLink = nil
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        blurPanels.values.forEach { $0.hide() }
        blurPanels.removeAll()
        guidePanel?.orderOut(nil)
        guidePanel = nil
        model = nil
        kind = nil
        trackedWindowID = nil
        missingSince = nil
        detectedListFrame = nil
        lastListLookupAt = nil
        lastListLookupSettingsFrame = nil
        lastSettingsGeometryChangeAt = nil
        motionFrom = nil
        motionTarget = nil
        motionStartedAt = nil
        presentedGeometry = nil
        requiresGeometrySnap = true
    }

    private func trackSystemSettings() async {
        while !Task.isCancelled {
            guard let kind else { return }
            if permissionSnapshot()[kind].isGranted {
                if model?.dropAccepted == true {
                    let windows = Self.visibleWindows()
                    if let observation = systemSettingsWindow(in: windows) {
                        let authenticationWindows = Self.authenticationWindows(
                            in: windows,
                            systemSettings: observation
                        )
                        if !authenticationWindows.isEmpty {
                            updatePanels(
                                for: observation,
                                authenticationWindows: authenticationWindows
                            )
                            try? await Task.sleep(for: .milliseconds(100))
                            continue
                        }
                    }
                    finishAcceptedDrop()
                } else {
                    dismiss()
                }
                return
            }

            let windows = Self.visibleWindows()
            if let observation = systemSettingsWindow(in: windows) {
                missingSince = nil
                let authenticationWindows = Self.authenticationWindows(
                    in: windows,
                    systemSettings: observation
                )
                if Self.isRelatedApplicationFrontmost(
                    systemSettings: observation,
                    authenticationWindows: authenticationWindows
                ) {
                    updatePanels(
                        for: observation,
                        authenticationWindows: authenticationWindows
                    )
                } else {
                    hidePanelsForFocusLoss()
                }
            } else if trackedWindowID == nil {
                if ContinuousClock.now - startedAt >= .seconds(8) {
                    dismiss()
                    return
                }
            } else {
                if missingSince == nil { missingSince = .now }
                if let missingSince,
                   ContinuousClock.now - missingSince >= .seconds(1) {
                    dismiss()
                    return
                }
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func systemSettingsWindow(
        in windows: [[String: Any]]
    ) -> WindowObservation? {
        if let trackedWindowID,
           let window = windows.first(where: {
               ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                   == trackedWindowID
           }), let observation = Self.observation(from: window) {
            return observation
        }

        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        ).first else { return nil }
        let processIdentifier = application.processIdentifier
        let candidates = windows.compactMap { window -> WindowObservation? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let observation = Self.observation(from: window),
                  observation.frame.width >= 500,
                  observation.frame.height >= 400 else {
                return nil
            }
            return observation
        }
        let match = candidates.max {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }
        trackedWindowID = match?.id
        return match
    }

    private func updatePanels(
        for systemSettings: WindowObservation,
        authenticationWindows: [WindowObservation]
    ) {
        let settingsFrame = systemSettings.frame
        let exactListFrame = refreshedDetectedListFrame(
            processIdentifier: systemSettings.processIdentifier,
            settingsFrame: settingsFrame
        )
        let layout = PermissionGuidanceLayout(
            settingsFrame: settingsFrame,
            detectedListFrame: exactListFrame
        )
        let clampedGuideFrame = clampedGuideFrame(
            layout.guideFrame,
            near: settingsFrame
        )
        let authenticationFrames = authenticationWindows.map(\.frame)
        let hasSeparateAuthenticationWindow = !authenticationFrames.isEmpty
        let dropAccepted = model?.dropAccepted == true
        let focusEntireSettingsWindow = hasSeparateAuthenticationWindow
        let globalFocusFrames = dropAccepted
            ? []
            : focusEntireSettingsWindow
                ? [settingsFrame] + authenticationFrames
                : [layout.listFrame]
        ensureBlurPanels()
        ensureGuidePanel()
        setPresentationTarget(
            PresentationGeometry(
                guideFrame: clampedGuideFrame,
                focusFrames: globalFocusFrames,
                outlineFrame: dropAccepted || focusEntireSettingsWindow
                    ? nil
                    : layout.listFrame,
                guideVisible: !hasSeparateAuthenticationWindow,
                grayscaleEnabled: !dropAccepted,
                behindWindowID: dropAccepted ? systemSettings.id : nil
            )
        )
    }

    private func refreshedDetectedListFrame(
        processIdentifier: pid_t,
        settingsFrame: CGRect
    ) -> CGRect? {
        guard AXIsProcessTrusted() else {
            detectedListFrame = nil
            lastListLookupSettingsFrame = settingsFrame
            return nil
        }

        let now = ContinuousClock.now
        if let previousSettingsFrame = lastListLookupSettingsFrame,
           previousSettingsFrame != settingsFrame {
            lastListLookupSettingsFrame = settingsFrame
            lastSettingsGeometryChangeAt = now
            if let detectedListFrame,
               let translated = PermissionGuidanceLayout
                .translatedDetectedListFrame(
                    detectedListFrame,
                    from: previousSettingsFrame,
                    to: settingsFrame
                ) {
                self.detectedListFrame = translated
                return translated
            }

            detectedListFrame = nil
            lastListLookupAt = nil
            return nil
        }

        if lastListLookupSettingsFrame == nil {
            lastListLookupSettingsFrame = settingsFrame
        }
        if let detectedListFrame {
            return detectedListFrame
        }

        let geometryIsSettled = lastSettingsGeometryChangeAt.map {
            now - $0 >= .milliseconds(250)
        } ?? true
        let lookupIsReady = lastListLookupAt.map {
            now - $0 >= .milliseconds(500)
        } ?? true
        guard geometryIsSettled, lookupIsReady else { return nil }

        lastListLookupAt = now
        detectedListFrame = SystemSettingsPermissionListLocator.listFrame(
            processIdentifier: processIdentifier,
            settingsFrame: settingsFrame,
            convertToAppKit: Self.appKitFrame(from:)
        )
        return detectedListFrame
    }

    private func setPresentationTarget(_ target: PresentationGeometry) {
        let now = CACurrentMediaTime()
        if motionTarget == target, motionFrom != nil {
            reassertBlurPanelOrdering()
            return
        }
        if motionFrom == nil, presentedGeometry == target,
           !requiresGeometrySnap {
            reassertBlurPanelOrdering()
            return
        }

        let current = currentPresentation(at: now) ?? target
        let reduceMotion = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
        guard !requiresGeometrySnap,
              !reduceMotion,
              current != target,
              current.canInterpolate(to: target) else {
            stopMotion()
            requiresGeometrySnap = false
            presentedGeometry = target
            render(target)
            return
        }

        motionFrom = current
        motionTarget = target
        motionStartedAt = now
        presentedGeometry = current
        ensureDisplayLink()
        guard let displayLink else {
            stopMotion()
            presentedGeometry = target
            render(target)
            return
        }
        displayLink.isPaused = false
    }

    private func reassertBlurPanelOrdering() {
        blurPanels.values.forEach { $0.reassertOrdering() }
    }

    private func currentPresentation(
        at timestamp: CFTimeInterval
    ) -> PresentationGeometry? {
        guard let motionFrom, let motionTarget, let motionStartedAt else {
            return presentedGeometry
        }
        let progress = CGFloat(
            (timestamp - motionStartedAt) / PermissionGuidanceMotion.duration
        )
        return motionFrom.interpolated(to: motionTarget, progress: progress)
    }

    private func ensureDisplayLink() {
        guard displayLink == nil,
              let screen = guidePanel?.screen ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        let displayLink = screen.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        displayLink.add(to: .main, forMode: .common)
        displayLink.isPaused = true
        self.displayLink = displayLink
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard let motionFrom, let motionTarget, let motionStartedAt else {
            displayLink.isPaused = true
            return
        }
        let linearProgress = CGFloat(
            (displayLink.timestamp - motionStartedAt)
                / PermissionGuidanceMotion.duration
        )
        let geometry = motionFrom.interpolated(
            to: motionTarget,
            progress: linearProgress
        )
        presentedGeometry = geometry
        render(geometry)

        guard linearProgress >= 1 else { return }
        presentedGeometry = motionTarget
        self.motionFrom = nil
        self.motionTarget = nil
        self.motionStartedAt = nil
        displayLink.isPaused = true
    }

    private func render(_ geometry: PresentationGeometry) {
        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(for: screen),
                  let blurPanel = blurPanels[displayID] else { continue }
            let focusFrames = geometry.focusFrames.compactMap {
                PermissionGuidanceLayout.localIntersection(
                    of: $0,
                    in: screen.frame
                )
            }
            let outlineFrame = geometry.outlineFrame.flatMap {
                PermissionGuidanceLayout.localIntersection(
                    of: $0,
                    in: screen.frame
                )
            }
            blurPanel.update(
                screenFrame: screen.frame,
                focusFrames: focusFrames,
                outlineFrame: outlineFrame,
                grayscaleEnabled: geometry.grayscaleEnabled,
                behindWindowID: geometry.behindWindowID
            )
            blurPanel.present()
        }

        if geometry.guideVisible {
            guidePanel?.setFrame(geometry.guideFrame, display: false)
            if guidePanel?.isVisible != true {
                guidePanel?.orderFrontRegardless()
            }
        } else {
            guidePanel?.orderOut(nil)
        }
    }

    private func stopMotion() {
        displayLink?.isPaused = true
        motionFrom = nil
        motionTarget = nil
        motionStartedAt = nil
    }

    private func ensureBlurPanels() {
        let currentIDs = Set(NSScreen.screens.compactMap(Self.displayID(for:)))
        let removedIDs = blurPanels.keys.filter { !currentIDs.contains($0) }
        for id in removedIDs {
            blurPanels.removeValue(forKey: id)?.hide()
        }
        for screen in NSScreen.screens {
            guard let id = Self.displayID(for: screen), blurPanels[id] == nil else {
                continue
            }
            blurPanels[id] = PermissionBlurPanel(screenFrame: screen.frame)
        }
    }

    private func ensureGuidePanel() {
        guard guidePanel == nil, let model else { return }
        let panel = PermissionGuidePanel(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 168)
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hostingView = NSHostingView(
            rootView: PermissionGuidanceView(
                model: model,
                dismiss: { [weak self] in self?.dismiss() },
                accepted: { [weak self] in self?.handleAcceptedDrop() }
            )
        )
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        guidePanel = panel
    }

    private func installEventMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.dismiss() }
        }
    }

    private func resetMotion() {
        stopMotion()
        displayLink?.invalidate()
        displayLink = nil
        presentedGeometry = nil
        requiresGeometrySnap = true
    }

    private func hidePanelsForFocusLoss() {
        resetMotion()
        blurPanels.values.forEach { $0.hide() }
        guidePanel?.orderOut(nil)
    }

    private func handleAcceptedDrop() {
        guard model?.dropAccepted != true else { return }
        model?.dropAccepted = true
    }

    private func finishAcceptedDrop() {
        let settingsApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        ).first
        let settingsProcessIdentifier = settingsApplication?.processIdentifier
        dismiss()
        if let settingsProcessIdentifier {
            _ = Self.closeSystemSettingsWindow(
                processIdentifier: settingsProcessIdentifier
            )
        }
        dropAccepted()
    }

    private static func closeSystemSettingsWindow(
        processIdentifier: pid_t
    ) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
              let window = (windowsValue as? [AXUIElement])?.first else {
            return false
        }

        var closeButtonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXCloseButtonAttribute as CFString,
            &closeButtonValue
        ) == .success,
              let closeButtonValue else {
            return false
        }
        let closeButton = closeButtonValue as! AXUIElement
        return AXUIElementPerformAction(
            closeButton,
            kAXPressAction as CFString
        ) == .success
    }

    private func makeModel() -> PermissionGuidanceModel {
        let applicationURL = Self.applicationBundleURL()
        let icon = applicationURL.map {
            NSWorkspace.shared.icon(forFile: $0.path)
        } ?? NSApp.applicationIconImage
            ?? NSImage(systemSymbolName: "alternatingcurrent", accessibilityDescription: "Current")
            ?? NSImage(size: NSSize(width: 36, height: 36))
        icon.size = NSSize(width: 36, height: 36)
        return PermissionGuidanceModel(
            applicationURL: applicationURL,
            applicationIcon: icon
        )
    }

    private func clampedGuideFrame(
        _ frame: CGRect,
        near settingsFrame: CGRect
    ) -> CGRect {
        guard let screen = NSScreen.screens.max(by: { lhs, rhs in
            lhs.frame.intersection(settingsFrame).area
                < rhs.frame.intersection(settingsFrame).area
        }) else { return frame }
        var result = frame
        if result.minX < screen.frame.minX + 12 {
            result.origin.x = screen.frame.minX + 12
        }
        if result.maxX > screen.frame.maxX - 12 {
            result.origin.x = screen.frame.maxX - 12 - result.width
        }
        if result.minY < screen.frame.minY + 12 {
            result.origin.y = screen.frame.minY + 12
        }
        if result.maxY > screen.frame.maxY - 12 {
            result.origin.y = screen.frame.maxY - 12 - result.height
        }
        return result
    }

    private static func visibleWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
    }

    private static func authenticationWindows(
        in windows: [[String: Any]],
        systemSettings: WindowObservation
    ) -> [WindowObservation] {
        let authorizationOwners = Set([
            "SecurityAgent",
            "CoreServicesUIAgent",
            "authorizationhost",
            "LocalAuthenticationRemoteService",
            "CoreAuthUI",
            "AuthenticationServicesAgent",
        ])
        return windows.compactMap { window in
            guard let observation = observation(from: window),
                  observation.id != systemSettings.id,
                  observation.frame.width >= 120,
                  observation.frame.height >= 80,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  observation.processIdentifier == systemSettings.processIdentifier
                    || authorizationOwners.contains(observation.ownerName) else {
                return nil
            }
            return observation
        }
    }

    private static func isRelatedApplicationFrontmost(
        systemSettings: WindowObservation,
        authenticationWindows: [WindowObservation]
    ) -> Bool {
        guard let frontmostProcessIdentifier = NSWorkspace.shared
            .frontmostApplication?.processIdentifier else {
            return false
        }
        return frontmostProcessIdentifier == systemSettings.processIdentifier
            || authenticationWindows.contains {
                $0.processIdentifier == frontmostProcessIdentifier
            }
    }

    private static func observation(
        from window: [String: Any]
    ) -> WindowObservation? {
        guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let processIdentifier = (window[kCGWindowOwnerPID as String]
                  as? NSNumber)?.int32Value,
              let ownerName = window[kCGWindowOwnerName as String] as? String,
              let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let cgFrame = CGRect(dictionaryRepresentation: dictionary),
              let frame = appKitFrame(from: cgFrame) else { return nil }
        return WindowObservation(
            id: id,
            frame: frame,
            processIdentifier: processIdentifier,
            ownerName: ownerName
        )
    }

    private static func appKitFrame(from cgFrame: CGRect) -> CGRect? {
        guard let match = NSScreen.screens.compactMap({ screen -> (
            screen: NSScreen,
            displayBounds: CGRect,
            area: CGFloat
        )? in
            guard let displayID = displayID(for: screen) else { return nil }
            let displayBounds = CGDisplayBounds(displayID)
            let intersection = displayBounds.intersection(cgFrame)
            let area = intersection.isNull ? 0 : intersection.area
            return (screen, displayBounds, area)
        }).max(by: { $0.area < $1.area }), match.area > 0 else {
            return nil
        }
        let scaleX = match.screen.frame.width / match.displayBounds.width
        let scaleY = match.screen.frame.height / match.displayBounds.height
        return CGRect(
            x: match.screen.frame.minX
                + (cgFrame.minX - match.displayBounds.minX) * scaleX,
            y: match.screen.frame.maxY
                - (cgFrame.maxY - match.displayBounds.minY) * scaleY,
            width: cgFrame.width * scaleX,
            height: cgFrame.height * scaleY
        )
    }

    private static func applicationBundleURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension.lowercased() == "app" { return bundleURL }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.emilianscheel.current"
        )
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber)?.uint32Value
    }
}

@MainActor
private final class PermissionGuidePanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
private final class PermissionBlurPanel {
    private enum Placement: Equatable {
        case foreground
        case behind(CGWindowID)
    }

    private struct Configuration {
        let focusFrames: [CGRect]
        let outlineFrame: CGRect?
        let grayscaleEnabled: Bool
        let placement: Placement
    }

    let panel: NSPanel
    private let focusView: PermissionFocusView
    private var hasPresented = false
    private var desiredVisible = false
    private var desiredConfiguration: Configuration?
    private var appliedConfiguration: Configuration?
    private var appliedPlacement: Placement?
    private var isChangingPlacement = false
    private var transitionGeneration = 0

    init(screenFrame: CGRect) {
        panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]
        focusView = PermissionFocusView(frame: CGRect(origin: .zero, size: screenFrame.size))
        focusView.autoresizingMask = [.width, .height]
        panel.contentView = focusView
    }

    func update(
        screenFrame: CGRect,
        focusFrames: [CGRect],
        outlineFrame: CGRect?,
        grayscaleEnabled: Bool,
        behindWindowID: CGWindowID?
    ) {
        if panel.frame != screenFrame {
            panel.setFrame(screenFrame, display: false)
        }
        let configuration = Configuration(
            focusFrames: focusFrames,
            outlineFrame: outlineFrame,
            grayscaleEnabled: grayscaleEnabled,
            placement: behindWindowID.map(Placement.behind) ?? .foreground
        )
        desiredConfiguration = configuration

        guard let appliedPlacement else {
            apply(configuration, animated: false)
            self.appliedPlacement = configuration.placement
            return
        }

        if appliedPlacement != configuration.placement {
            beginPlacementTransitionIfNeeded()
        } else if !isChangingPlacement {
            apply(configuration, animated: hasPresented)
            if desiredVisible, !panel.isVisible {
                orderPanel(for: configuration.placement)
            }
        }
    }

    func present() {
        guard let desiredConfiguration else { return }
        if desiredVisible {
            if !isChangingPlacement, !panel.isVisible {
                orderPanel(for: appliedPlacement ?? desiredConfiguration.placement)
            }
            return
        }

        desiredVisible = true
        transitionGeneration += 1
        let generation = transitionGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible {
            panel.alphaValue = reduceMotion ? 1 : 0
        }
        orderPanel(for: appliedPlacement ?? desiredConfiguration.placement)
        hasPresented = true
        guard !reduceMotion else {
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.transitionGeneration == generation,
                      self.desiredVisible else { return }
                self.panel.alphaValue = 1
            }
        }
    }

    func hide() {
        guard desiredVisible || panel.isVisible else { return }
        desiredVisible = false
        isChangingPlacement = false
        transitionGeneration += 1
        let generation = transitionGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard panel.isVisible, !reduceMotion else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [self] in
            Task { @MainActor [self] in
                guard transitionGeneration == generation,
                      !desiredVisible else { return }
                panel.alphaValue = 0
                panel.orderOut(nil)
            }
        }
    }

    func reassertOrdering() {
        guard desiredVisible, !isChangingPlacement,
              let appliedPlacement,
              case .behind = appliedPlacement else { return }
        orderPanel(for: appliedPlacement)
    }

    private func beginPlacementTransitionIfNeeded() {
        guard !isChangingPlacement, desiredVisible,
              panel.isVisible else {
            if !desiredVisible || !panel.isVisible,
               let desiredConfiguration {
                apply(desiredConfiguration, animated: false)
                appliedPlacement = desiredConfiguration.placement
            }
            return
        }

        isChangingPlacement = true
        transitionGeneration += 1
        let generation = transitionGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let appliedConfiguration,
           appliedConfiguration.grayscaleEnabled
                != desiredConfiguration?.grayscaleEnabled {
            focusView.update(
                focusFrames: appliedConfiguration.focusFrames,
                outlineFrame: appliedConfiguration.outlineFrame,
                grayscaleEnabled: desiredConfiguration?.grayscaleEnabled ?? false,
                animated: true
            )
        }
        guard !reduceMotion else {
            completePlacementTransition(generation: generation)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.completePlacementTransition(generation: generation)
            }
        }
    }

    private func completePlacementTransition(generation: Int) {
        guard transitionGeneration == generation,
              let desiredConfiguration else { return }
        apply(desiredConfiguration, animated: false)
        appliedPlacement = desiredConfiguration.placement
        isChangingPlacement = false

        guard desiredVisible else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }

        orderPanel(for: desiredConfiguration.placement)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.transitionGeneration == generation,
                      self.desiredVisible else { return }
                self.panel.alphaValue = 1
            }
        }
    }

    private func apply(_ configuration: Configuration, animated: Bool) {
        focusView.update(
            focusFrames: configuration.focusFrames,
            outlineFrame: configuration.outlineFrame,
            grayscaleEnabled: configuration.grayscaleEnabled,
            animated: animated
        )
        appliedConfiguration = configuration
    }

    private func orderPanel(for placement: Placement) {
        switch placement {
        case .foreground:
            panel.level = .floating
            panel.orderFrontRegardless()
        case let .behind(windowID):
            panel.level = .normal
            panel.order(.below, relativeTo: Int(windowID))
        }
    }
}

private final class PermissionFocusView: NSView {
    private let effectView = NSVisualEffectView()
    private let grayscaleView = NSView()
    private let grayscaleEffectView = NSVisualEffectView()
    private let effectMaskLayer = CAShapeLayer()
    private let grayscaleMaskLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private var grayscaleEnabled: Bool?
    private var focusFrames: [CGRect] = []
    private var outlineFrame: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        effectView.wantsLayer = true
        effectView.blendingMode = .behindWindow
        effectView.material = .fullScreenUI
        effectView.state = .active
        effectView.alphaValue = 0.9
        addSubview(effectView)

        grayscaleView.frame = bounds
        grayscaleView.autoresizingMask = [.width, .height]
        grayscaleView.wantsLayer = true
        grayscaleView.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(0.001).cgColor
        grayscaleView.layer?.masksToBounds = true
        let colorControls = CIFilter.colorControls()
        colorControls.saturation = 0
        colorControls.brightness = 0
        colorControls.contrast = 1
        grayscaleView.backgroundFilters = [colorControls]
        grayscaleEffectView.frame = grayscaleView.bounds
        grayscaleEffectView.autoresizingMask = [.width, .height]
        grayscaleEffectView.wantsLayer = true
        grayscaleEffectView.blendingMode = .behindWindow
        grayscaleEffectView.material = .fullScreenUI
        grayscaleEffectView.state = .active
        let grayscaleBlurControls = CIFilter.colorControls()
        grayscaleBlurControls.saturation = 0
        grayscaleBlurControls.brightness = 0
        grayscaleBlurControls.contrast = 1
        grayscaleEffectView.contentFilters = [grayscaleBlurControls]
        grayscaleView.addSubview(grayscaleEffectView)
        addSubview(grayscaleView)

        for maskLayer in [effectMaskLayer, grayscaleMaskLayer] {
            maskLayer.fillColor = NSColor.black.cgColor
            maskLayer.fillRule = .evenOdd
        }
        effectView.layer?.mask = effectMaskLayer
        grayscaleEffectView.layer?.mask = grayscaleMaskLayer

        layer?.addSublayer(outlineLayer)
        outlineLayer.fillColor = NSColor.black.withAlphaComponent(0.045).cgColor
        outlineLayer.strokeColor = NSColor.black.withAlphaComponent(0.78).cgColor
        outlineLayer.lineWidth = 2
        outlineLayer.lineDashPattern = [6, 6]
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateGeometryLayers()
    }

    func update(
        focusFrames: [CGRect],
        outlineFrame: CGRect?,
        grayscaleEnabled: Bool,
        animated: Bool
    ) {
        self.focusFrames = focusFrames
        self.outlineFrame = outlineFrame
        updateGeometryLayers()
        updateGrayscale(
            enabled: grayscaleEnabled,
            animated: animated
        )
    }

    private func updateGeometryLayers() {
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds)
        for frame in focusFrames {
            maskPath.addRoundedRect(
                in: frame.insetBy(dx: -3, dy: -3),
                cornerWidth: 16,
                cornerHeight: 16
            )
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for maskLayer in [effectMaskLayer, grayscaleMaskLayer] {
            maskLayer.frame = bounds
            maskLayer.path = maskPath
        }
        outlineLayer.frame = bounds
        if let outlineFrame {
            outlineLayer.path = CGPath(
                roundedRect: outlineFrame.insetBy(dx: 1, dy: 1),
                cornerWidth: 14,
                cornerHeight: 14,
                transform: nil
            )
            outlineLayer.isHidden = false
        } else {
            outlineLayer.isHidden = true
            outlineLayer.path = nil
        }
        CATransaction.commit()
    }

    private func updateGrayscale(enabled: Bool, animated: Bool) {
        guard grayscaleEnabled != enabled else { return }
        let isInitialState = grayscaleEnabled == nil
        grayscaleEnabled = enabled
        let targetAlpha: CGFloat = enabled ? 1 : 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !isInitialState, !reduceMotion else {
            grayscaleView.alphaValue = targetAlpha
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            grayscaleView.animator().alphaValue = targetAlpha
        }
    }

}

private struct PermissionGuidanceView: View {
    @Bindable var model: PermissionGuidanceModel
    let dismiss: () -> Void
    let accepted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: model.dropAccepted ? "checkmark" : "arrow.up")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.bottom, 12)
            Text(
                model.dropAccepted
                    ? "Now turn on Current in the list"
                    : "Drag and drop this row into the list"
            )
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.bottom, 20)
            applicationRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .background(.white.opacity(0.97), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close permission guidance")
            .padding(10)
        }
        .preferredColorScheme(.light)
    }

    private var applicationRow: some View {
        HStack(spacing: 12) {
            Image(nsImage: model.applicationIcon)
                .resizable()
                .frame(width: 36, height: 36)
            Text("Current")
                .font(.title3.weight(.medium))
            Spacer()
            if model.applicationURL == nil {
                Text("Open the installed app to drag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(.white, in: .rect(cornerRadius: 13))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(
                    .black,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                )
        }
        .overlay {
            if let applicationURL = model.applicationURL {
                ApplicationDragSource(
                    applicationURL: applicationURL,
                    applicationIcon: model.applicationIcon
                ) {
                    accepted()
                }
            }
        }
    }
}

private struct ApplicationDragSource: NSViewRepresentable {
    let applicationURL: URL
    let applicationIcon: NSImage
    let accepted: () -> Void

    func makeNSView(context: Context) -> ApplicationDragView {
        ApplicationDragView(
            applicationURL: applicationURL,
            applicationIcon: applicationIcon,
            accepted: accepted
        )
    }

    func updateNSView(_ nsView: ApplicationDragView, context: Context) {}
}

private final class ApplicationDragView: NSView, NSDraggingSource {
    private let applicationURL: URL
    private let applicationIcon: NSImage
    private let accepted: () -> Void
    private var mouseDownEvent: NSEvent?
    private var startedDragging = false

    init(
        applicationURL: URL,
        applicationIcon: NSImage,
        accepted: @escaping () -> Void
    ) {
        self.applicationURL = applicationURL
        self.applicationIcon = applicationIcon
        self.accepted = accepted
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel("Current application row. Drag into the list.")
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        startedDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging, mouseDownEvent != nil else { return }
        startedDragging = true
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        let size = NSSize(width: 44, height: 44)
        item.setDraggingFrame(
            NSRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            contents: applicationIcon
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        startedDragging = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        mouseDownEvent = nil
        startedDragging = false
        guard operation.contains(.copy) else { return }
        Task { @MainActor [accepted] in accepted() }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
