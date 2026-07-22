import AppKit
import CoreGraphics
import CurrentCore
import Observation
import SwiftUI

@MainActor
@Observable
final class OverlayModel {
    var phase: DictationPhase = .idle
    var isExpanded = false
    var contentVisible = false
    var layout = OverlayLayout(
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        safeAreaTop: 0,
        notchBounds: nil
    )
}

@MainActor
final class NotchOverlayController {
    private let model = OverlayModel()
    private let audio: AudioCaptureService
    private let settings: SettingsStore
    private var panel: NSPanel?
    private var autoHideTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var sessionDisplayID: CGDirectDisplayID?

    init(audio: AudioCaptureService, settings: SettingsStore) {
        self.audio = audio
        self.settings = settings
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.repositionPanel() }
        }
    }

    func show(phase: DictationPhase) {
        guard settings.overlayEnabled else { collapse(); return }
        autoHideTask?.cancel()

        switch phase {
        case .idle, .paused:
            collapse()
        default:
            let wasVisible = panel?.isVisible == true
            model.phase = phase
            ensurePanel()
            if !wasVisible {
                sessionDisplayID = Self.preferredScreen().flatMap(Self.displayID(for:))
            }
            repositionPanel()
            presentIfNeeded(wasVisible: wasVisible)
            scheduleTerminalHide(for: phase)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: NotchOverlayView(model: model, audio: audio, settings: settings)
        )
        self.panel = panel
    }

    private func presentIfNeeded(wasVisible: Bool) {
        guard let panel else { return }
        orderOutTask?.cancel()
        panel.orderFrontRegardless()
        guard !wasVisible else { return }

        model.isExpanded = false
        model.contentVisible = false
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.panel?.isVisible == true else { return }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let intensity = max(0, min(1, self.settings.animationIntensity))
            let expansion: Animation = reduceMotion
                ? .linear(duration: 0.01)
                : .spring(response: 0.32 + (1 - intensity) * 0.06, dampingFraction: 0.9 - intensity * 0.08)
            withAnimation(expansion) {
                self.model.isExpanded = true
            }
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.18)) {
                self.model.contentVisible = true
            }
        }
    }

    private func scheduleTerminalHide(for phase: DictationPhase) {
        let delay: Duration
        switch phase {
        case .success, .cancelled: delay = .milliseconds(950)
        case .error: delay = .milliseconds(1_500)
        default: return
        }
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    private func collapse() {
        autoHideTask?.cancel()
        autoHideTask = nil
        guard panel?.isVisible == true else {
            sessionDisplayID = nil
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.16)) { model.contentVisible = false }
        withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.26)) {
            model.isExpanded = false
        }

        orderOutTask?.cancel()
        orderOutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 130 : 280))
            guard !Task.isCancelled, let self else { return }
            self.panel?.orderOut(nil)
            self.sessionDisplayID = nil
        }
    }

    private func repositionPanel() {
        guard let panel else { return }
        let screen = sessionDisplayID.flatMap(Self.screen(for:)) ?? Self.preferredScreen()
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        sessionDisplayID = Self.displayID(for: screen)

        let notchBounds: CGRect?
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX,
           screen.safeAreaInsets.top > 0 {
            notchBounds = CGRect(
                x: left.maxX,
                y: screen.frame.maxY - screen.safeAreaInsets.top,
                width: right.minX - left.maxX,
                height: screen.safeAreaInsets.top
            )
        } else {
            notchBounds = nil
        }

        let layout = OverlayLayout(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            notchBounds: notchBounds
        )
        model.layout = layout
        panel.setFrame(layout.panelFrame, display: true)
    }

    private static func preferredScreen() -> NSScreen? {
        if let application = NSWorkspace.shared.frontmostApplication,
           let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]],
           let bounds = windows.first(where: { info in
               (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier
                   && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                   && (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0
           }).flatMap({ info in
               (info[kCGWindowBounds as String] as? NSDictionary)
                   .flatMap { CGRect(dictionaryRepresentation: $0) }
           }) {
            let match = NSScreen.screens.max { lhs, rhs in
                intersectionArea(of: bounds, with: cgBounds(for: lhs))
                    < intersectionArea(of: bounds, with: cgBounds(for: rhs))
            }
            if let match, intersectionArea(of: bounds, with: cgBounds(for: match)) > 0 {
                return match
            }
        }

        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
    }

    private static func intersectionArea(of lhs: CGRect, with rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func cgBounds(for screen: NSScreen) -> CGRect {
        guard let id = displayID(for: screen) else { return .null }
        return CGDisplayBounds(id)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(for: $0) == displayID }
    }
}

private struct NotchOverlayView: View {
    @Bindable var model: OverlayModel
    @Bindable var audio: AudioCaptureService
    @Bindable var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = model.isExpanded ? model.layout.expandedSize : model.layout.collapsedSize
        ZStack(alignment: .top) {
            islandShape
                .fill(.black)
                .frame(width: size.width, height: size.height)
                .overlay {
                    content
                        .padding(.horizontal, 20)
                        .opacity(model.contentVisible ? 1 : 0)
                        .scaleEffect(model.contentVisible ? 1 : 0.88)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, model.layout.topPadding)
        .transaction { transaction in
            if reduceMotion { transaction.animation = .easeOut(duration: 0.12) }
        }
    }

    private var islandShape: UnevenRoundedRectangle {
        let topRadius: CGFloat = model.layout.attachment == .notch ? 0 : 24
        return UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: topRadius,
                bottomLeading: 16,
                bottomTrailing: 16,
                topTrailing: topRadius
            ),
            style: .continuous
        )
    }

    private var content: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Spacer(minLength: 20)
            PhaseActivity(
                phase: model.phase,
                level: audio.level,
                intensity: settings.animationIntensity,
                reduceMotion: reduceMotion
            )
            .frame(width: 44, height: 22)
        }
        .foregroundStyle(.white)
    }
}

private struct PhaseActivity: View {
    let phase: DictationPhase
    let level: Float
    let intensity: Double
    let reduceMotion: Bool

    var body: some View {
        Group {
            switch phase {
            case .recording: LevelBars(level: level, intensity: intensity)
            case .transcribing, .inserting: ProcessingDots(reduceMotion: reduceMotion)
            case .success: Image(systemName: "checkmark").foregroundStyle(.green)
            case .cancelled: Image(systemName: "xmark").foregroundStyle(.white.opacity(0.8))
            case .error: Image(systemName: "exclamationmark").foregroundStyle(.orange)
            default: Image(systemName: "waveform").foregroundStyle(.white.opacity(0.7))
            }
        }
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .contentTransition(.symbolEffect(.replace))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: phase)
    }
}

private struct LevelBars: View {
    let level: Float
    let intensity: Double
    private let multipliers: [CGFloat] = [0.55, 0.82, 1, 0.76, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(multipliers.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: barHeight(multiplier: multipliers[index]))
            }
        }
        .animation(.smooth(duration: 0.1), value: level)
    }

    private func barHeight(multiplier: CGFloat) -> CGFloat {
        let response = max(0.08, min(1, CGFloat(level)))
        let amplitude = 6 + response * 14 * max(0.15, CGFloat(intensity))
        return max(4, amplitude * multiplier)
    }
}

private struct ProcessingDots: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            staticDots(phase: 1)
        } else {
            TimelineView(.periodic(from: .now, by: 0.18)) { context in
                staticDots(phase: Int(context.date.timeIntervalSinceReferenceDate / 0.18) % 3)
            }
        }
    }

    private func staticDots(phase: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index == phase ? 1 : 0.35))
                    .frame(width: 4, height: 4)
                    .scaleEffect(index == phase ? 1.25 : 1)
            }
        }
    }
}
