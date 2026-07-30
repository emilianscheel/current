import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import CoreImage.CIFilterBuiltins
import CurrentCore
import Observation
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
final class PermissionGuidanceOverlayController {
    private struct WindowObservation {
        let id: CGWindowID
        let frame: CGRect
        let processIdentifier: pid_t
        let ownerName: String
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
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    init(
        permissionSnapshot: @escaping () -> PermissionSnapshot,
        dropAccepted: @escaping () -> Void
    ) {
        self.permissionSnapshot = permissionSnapshot
        self.dropAccepted = dropAccepted
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
            }
        }
        trackingTask = Task { @MainActor [weak self] in
            await self?.trackSystemSettings()
        }
    }

    func dismiss() {
        trackingTask?.cancel()
        trackingTask = nil
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
        blurPanels.values.forEach { $0.panel.orderOut(nil) }
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
        let focusEntireSettingsWindow = model?.dropAccepted == true
            || hasSeparateAuthenticationWindow
        let globalFocusFrames = focusEntireSettingsWindow
            ? [settingsFrame] + authenticationFrames
            : [layout.listFrame]
        ensureBlurPanels()
        ensureGuidePanel()

        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(for: screen),
                  let blurPanel = blurPanels[displayID] else { continue }
            let focusFrames = globalFocusFrames.compactMap {
                PermissionGuidanceLayout.localIntersection(
                    of: $0,
                    in: screen.frame
                )
            }
            let outlineFrame = focusEntireSettingsWindow ? nil
                : PermissionGuidanceLayout.localIntersection(
                    of: layout.listFrame,
                    in: screen.frame
                )
            blurPanel.update(
                screenFrame: screen.frame,
                focusFrames: focusFrames,
                outlineFrame: outlineFrame,
                grayscaleEnabled: model?.dropAccepted != true
            )
            if !blurPanel.panel.isVisible {
                blurPanel.present()
            }
        }

        if hasSeparateAuthenticationWindow {
            guidePanel?.orderOut(nil)
        } else {
            guidePanel?.setFrame(clampedGuideFrame, display: true)
            if guidePanel?.isVisible != true {
                guidePanel?.orderFrontRegardless()
            }
        }
    }

    private func refreshedDetectedListFrame(
        processIdentifier: pid_t,
        settingsFrame: CGRect
    ) -> CGRect? {
        guard AXIsProcessTrusted() else {
            detectedListFrame = nil
            return nil
        }

        let settingsMoved = lastListLookupSettingsFrame != settingsFrame
        let lookupIsStale = lastListLookupAt.map {
            ContinuousClock.now - $0 >= .milliseconds(500)
        } ?? true
        guard settingsMoved || lookupIsStale else {
            return detectedListFrame
        }

        lastListLookupAt = .now
        lastListLookupSettingsFrame = settingsFrame
        detectedListFrame = SystemSettingsPermissionListLocator.listFrame(
            processIdentifier: processIdentifier,
            settingsFrame: settingsFrame,
            convertToAppKit: Self.appKitFrame(from:)
        )
        return detectedListFrame
    }

    private func ensureBlurPanels() {
        let currentIDs = Set(NSScreen.screens.compactMap(Self.displayID(for:)))
        let removedIDs = blurPanels.keys.filter { !currentIDs.contains($0) }
        for id in removedIDs {
            blurPanels.removeValue(forKey: id)?.panel.orderOut(nil)
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

    private func hidePanelsForFocusLoss() {
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
    let panel: NSPanel
    private let focusView: PermissionFocusView
    private var hasPresented = false

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
        grayscaleEnabled: Bool
    ) {
        panel.setFrame(screenFrame, display: false)
        focusView.update(
            focusFrames: focusFrames,
            outlineFrame: outlineFrame,
            grayscaleEnabled: grayscaleEnabled,
            animated: hasPresented
        )
    }

    func present() {
        guard !panel.isVisible else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        hasPresented = true
        guard !reduceMotion else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class PermissionFocusView: NSView {
    private let effectView = NSVisualEffectView()
    private let grayscaleView = NSView()
    private let grayscaleEffectView = NSVisualEffectView()
    private let outlineLayer = CAShapeLayer()
    private var grayscaleEnabled: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
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

        layer?.addSublayer(outlineLayer)
        outlineLayer.fillColor = NSColor.black.withAlphaComponent(0.045).cgColor
        outlineLayer.strokeColor = NSColor.black.withAlphaComponent(0.78).cgColor
        outlineLayer.lineWidth = 2
        outlineLayer.lineDashPattern = [6, 6]
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        outlineLayer.frame = bounds
    }

    func update(
        focusFrames: [CGRect],
        outlineFrame: CGRect?,
        grayscaleEnabled: Bool,
        animated: Bool
    ) {
        let focusMask = maskImage(cuttingOut: focusFrames)
        effectView.maskImage = focusMask
        grayscaleEffectView.maskImage = focusMask
        updateGrayscale(
            enabled: grayscaleEnabled,
            animated: animated
        )
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
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            grayscaleView.animator().alphaValue = targetAlpha
        }
    }

    private func maskImage(cuttingOut holes: [CGRect]) -> NSImage {
        NSImage(size: bounds.size, flipped: false) { [bounds] _ in
            NSColor.white.setFill()
            bounds.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            for hole in holes {
                NSBezierPath(
                    roundedRect: hole.insetBy(dx: -3, dy: -3),
                    xRadius: 16,
                    yRadius: 16
                ).fill()
            }
            return true
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
