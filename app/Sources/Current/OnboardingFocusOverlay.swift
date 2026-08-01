@preconcurrency import AppKit
import CoreGraphics
import CurrentCore
import QuartzCore

@MainActor
final class OnboardingFocusOverlayController {
    private enum Mode {
        case idle
        case stage(window: NSWindow)
        case microphone
    }

    private var panels: [CGDirectDisplayID: FocusOverlayPanel] = [:]
    private var mode = Mode.idle
    private var stageTask: Task<Void, Never>?
    private var microphoneTask: Task<Void, Never>?
    private var generation = FocusPresentationGeneration()
    private var latestStageSample = StageLightAnimation.sample(
        elapsed: 0,
        reduceMotion: false
    )
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screensDidChange()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func presentStage(around window: NSWindow) {
        cancelMicrophoneTracking(hidePanels: true)
        cancelStage(hidePanels: true)
        let presentationGeneration = generation.next()
        mode = .stage(window: window)
        ensurePanels()

        let reduceMotion = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
        latestStageSample = StageLightAnimation.sample(
            elapsed: 0,
            reduceMotion: reduceMotion
        )
        renderStage(window: window, sample: latestStageSample, begin: true)

        stageTask = Task { @MainActor [weak self, weak window] in
            let startedAt = CACurrentMediaTime()
            while !Task.isCancelled {
                guard let self, let window,
                      self.generation.matches(presentationGeneration),
                      window.isVisible, window.isKeyWindow else { break }
                let elapsed = CACurrentMediaTime() - startedAt
                let sample = StageLightAnimation.sample(
                    elapsed: elapsed,
                    reduceMotion: reduceMotion
                )
                self.latestStageSample = sample
                self.renderStage(window: window, sample: sample, begin: false)
                if elapsed >= StageLightAnimation.duration { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard let self,
                  self.generation.matches(presentationGeneration) else {
                return
            }
            self.finishStagePresentation()
        }
    }

    func dismissStage() {
        guard case .stage = mode else { return }
        cancelStage(hidePanels: true)
        mode = .idle
    }

    func refreshWindowGeometry() {
        guard case .stage(let window) = mode else { return }
        renderStage(window: window, sample: latestStageSample, begin: false)
    }

    func beginMicrophonePrompt(excluding onboardingWindow: NSWindow?) {
        cancelStage(hidePanels: true)
        cancelMicrophoneTracking(hidePanels: true)
        let presentationGeneration = generation.next()
        mode = .microphone
        ensurePanels()

        let baseline = Set(Self.windowObservations().map(\.id))
        let applicationPID = ProcessInfo.processInfo.processIdentifier
        let onboardingWindowNumber = onboardingWindow?.windowNumber ?? 0
        let excludedWindowID = onboardingWindowNumber > 0
            ? CGWindowID(onboardingWindowNumber) : nil

        microphoneTask = Task { @MainActor [weak self, weak onboardingWindow] in
            while !Task.isCancelled {
                guard let self,
                      self.generation.matches(presentationGeneration) else {
                    return
                }
                let promptFrame = self.appKitPromptFrame(
                    excluding: onboardingWindow
                ) ?? MicrophonePromptMatcher.candidate(
                    baselineWindowIDs: baseline,
                    observations: Self.windowObservations(),
                    applicationProcessIdentifier: applicationPID,
                    excludedWindowID: excludedWindowID
                )?.frame

                if let promptFrame {
                    self.renderPermissionPrompt(frame: promptFrame)
                } else {
                    self.panels.values.forEach { $0.hide() }
                }
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    func endMicrophonePrompt() {
        guard case .microphone = mode else { return }
        cancelMicrophoneTracking(hidePanels: true)
        mode = .idle
    }

    func dismissAll() {
        _ = generation.next()
        stageTask?.cancel()
        stageTask = nil
        microphoneTask?.cancel()
        microphoneTask = nil
        mode = .idle
        panels.values.forEach { $0.hide() }
    }

    private func renderStage(
        window: NSWindow,
        sample: StageLightSample,
        begin: Bool
    ) {
        ensurePanels()
        let beamDisplayID = window.screen.flatMap(Self.displayID(for:))
        for screen in NSScreen.screens {
            guard let id = Self.displayID(for: screen),
                  let panel = panels[id] else { continue }
            let focusFrame = PermissionGuidanceLayout.localIntersection(
                of: window.frame,
                in: screen.frame
            )
            panel.update(
                screenFrame: screen.frame,
                focusFrames: focusFrame.map { [$0] } ?? [],
                outlineFrame: nil,
                appearance: .stageLight(
                    sample,
                    showsBeam: id == beamDisplayID
                ),
                behindWindowID: CGWindowID(window.windowNumber)
            )
            if begin { panel.beginManualPresentation() }
            panel.setManualPresentationAlpha(sample.overlayOpacity)
        }
    }

    private func renderPermissionPrompt(frame: CGRect) {
        ensurePanels()
        for screen in NSScreen.screens {
            guard let id = Self.displayID(for: screen),
                  let panel = panels[id] else { continue }
            let focusFrame = PermissionGuidanceLayout.localIntersection(
                of: frame,
                in: screen.frame
            )
            panel.update(
                screenFrame: screen.frame,
                focusFrames: focusFrame.map { [$0] } ?? [],
                outlineFrame: nil,
                appearance: .permission(grayscaleEnabled: true),
                behindWindowID: nil
            )
            panel.present()
        }
    }

    private func finishStagePresentation() {
        stageTask = nil
        panels.values.forEach { $0.endManualPresentation() }
        if case .stage = mode { mode = .idle }
    }

    private func cancelStage(hidePanels: Bool) {
        _ = generation.next()
        stageTask?.cancel()
        stageTask = nil
        if hidePanels {
            panels.values.forEach { $0.cancelManualPresentation() }
        }
    }

    private func cancelMicrophoneTracking(hidePanels: Bool) {
        _ = generation.next()
        microphoneTask?.cancel()
        microphoneTask = nil
        if hidePanels { panels.values.forEach { $0.hide() } }
    }

    private func screensDidChange() {
        ensurePanels()
        switch mode {
        case .stage(let window):
            renderStage(window: window, sample: latestStageSample, begin: false)
        case .microphone, .idle:
            break
        }
    }

    private func ensurePanels() {
        let currentIDs = Set(NSScreen.screens.compactMap(Self.displayID(for:)))
        for id in panels.keys where !currentIDs.contains(id) {
            panels.removeValue(forKey: id)?.hide()
        }
        for screen in NSScreen.screens {
            guard let id = Self.displayID(for: screen), panels[id] == nil else {
                continue
            }
            panels[id] = FocusOverlayPanel(screenFrame: screen.frame)
        }
    }

    private func appKitPromptFrame(excluding window: NSWindow?) -> CGRect? {
        let candidates = [window?.attachedSheet, NSApp.modalWindow]
            .compactMap { $0 }
            .filter { candidate in
                candidate !== window && candidate.isVisible
                    && candidate.frame.width >= 220
                    && candidate.frame.height >= 100
            }
        return candidates.min {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }?.frame
    }

    private static func windowObservations() -> [FocusWindowObservation] {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard let id = (window[kCGWindowNumber as String] as? NSNumber)?
                    .uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?
                    .int32Value,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  let dictionary = window[kCGWindowBounds as String]
                    as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: dictionary),
                  let frame = appKitFrame(from: cgFrame) else { return nil }
            return FocusWindowObservation(
                id: id,
                processIdentifier: pid,
                ownerName: owner,
                frame: frame,
                layer: (window[kCGWindowLayer as String] as? NSNumber)?
                    .intValue ?? 0,
                alpha: (window[kCGWindowAlpha as String] as? NSNumber)?
                    .doubleValue ?? 1
            )
        }
    }

    private static func appKitFrame(from cgFrame: CGRect) -> CGRect? {
        guard let match = NSScreen.screens.compactMap({ screen -> (
            screen: NSScreen, displayBounds: CGRect, area: CGFloat
        )? in
            guard let displayID = displayID(for: screen) else { return nil }
            let bounds = CGDisplayBounds(displayID)
            let intersection = bounds.intersection(cgFrame)
            let area = intersection.isNull || intersection.isEmpty
                ? 0 : intersection.width * intersection.height
            return (screen, bounds, area)
        }).max(by: { $0.area < $1.area }), match.area > 0 else { return nil }
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

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber)?.uint32Value
    }
}
