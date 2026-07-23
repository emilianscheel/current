import AppKit
import CoreGraphics
import CurrentCore
import Observation
import SwiftUI

@MainActor
@Observable
final class OverlayModel {
    var phase: DictationPhase = .idle
    var presentationProgress: CGFloat = 0
    var targetApplication: InsertionService.TargetApplicationPresentation?
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
    private var presentationTask: Task<Void, Never>?
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

    func show(
        phase: DictationPhase,
        targetApplication: InsertionService.TargetApplicationPresentation?
    ) {
        guard settings.overlayEnabled else { collapse(); return }
        autoHideTask?.cancel()

        switch phase {
        case .idle, .paused:
            collapse()
        default:
            let wasVisible = panel?.isVisible == true
            model.phase = phase
            if phase == .armed || phase == .recording {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.targetApplication = targetApplication
                }
            }
            ensurePanel()
            if !wasVisible {
                sessionDisplayID = Self.preferredScreen().flatMap(Self.displayID(for:))
                repositionPanel()
            }
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
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hostingView = NSHostingView(
            rootView: NotchOverlayView(model: model, audio: audio, settings: settings)
        )
        // This panel has an explicitly managed, fixed frame. Prevent NSHostingView
        // from feeding its animated SwiftUI content size back into NSWindow, which
        // can create a recursive AppKit constraint-update cycle during presentation.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layerContentsRedrawPolicy = .duringViewResize
        panel.contentView = hostingView
        self.panel = panel
    }

    private func presentIfNeeded(wasVisible: Bool) {
        guard let panel else { return }
        orderOutTask?.cancel()
        orderOutTask = nil
        presentationTask?.cancel()
        if wasVisible {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduceMotion ? .linear(duration: 0.01) : expansionAnimation) {
                model.presentationProgress = 1
            }
            return
        }

        model.presentationProgress = 0
        panel.orderFrontRegardless()
        presentationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.panel?.isVisible == true else { return }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduceMotion ? .linear(duration: 0.01) : self.expansionAnimation) {
                self.model.presentationProgress = 1
            }
        }
    }

    private var expansionAnimation: Animation {
        let intensity = max(0, min(1, settings.animationIntensity))
        return .spring(
            response: 0.32 + (1 - intensity) * 0.05,
            dampingFraction: 0.9 - intensity * 0.06
        )
    }

    private func scheduleTerminalHide(for phase: DictationPhase) {
        let delay: Duration
        switch phase {
        case .success, .cancelled: delay = .milliseconds(700)
        case .error: delay = .milliseconds(1_100)
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
        presentationTask?.cancel()
        presentationTask = nil
        guard panel?.isVisible == true else {
            sessionDisplayID = nil
            model.targetApplication = nil
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.26)) {
            model.presentationProgress = 0
        }

        orderOutTask?.cancel()
        orderOutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 130 : 280))
            guard !Task.isCancelled, let self else { return }
            self.panel?.orderOut(nil)
            self.sessionDisplayID = nil
            self.model.targetApplication = nil
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
        panel.setFrame(layout.panelFrame, display: false)
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
        let contentProgress = min(1, max(0, (model.presentationProgress - 0.26) / 0.56))
        ZStack(alignment: .top) {
            NotchIslandShape(
                progress: model.presentationProgress,
                collapsedSize: model.layout.collapsedSize,
                expandedSize: model.layout.expandedSize,
                attachment: model.layout.attachment
            )
                .fill(.black)
                .overlay {
                    content
                        .padding(.horizontal, 20)
                        .frame(
                            width: model.layout.expandedSize.width,
                            height: model.layout.expandedSize.height
                        )
                        .opacity(contentProgress)
                        .scaleEffect(0.9 + contentProgress * 0.1)
                        .transaction { transaction in
                            if reduceMotion {
                                transaction.animation = .easeOut(duration: 0.12)
                            }
                        }
                }
                .frame(
                    width: model.layout.expandedSize.width,
                    height: model.layout.expandedSize.height,
                    alignment: .top
                )
                .compositingGroup()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, model.layout.topPadding)
    }

    private var content: some View {
        HStack(spacing: 16) {
            targetApplicationIcon
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

    @ViewBuilder
    private var targetApplicationIcon: some View {
        Group {
            if let target = model.targetApplication, let icon = target.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .accessibilityLabel(Text(target.localizedName))
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .padding(3)
                    .foregroundStyle(.white.opacity(0.82))
                    .accessibilityLabel(Text("Target application"))
            }
        }
        .id(model.targetApplication?.processIdentifier)
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.82)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.targetApplication?.processIdentifier)
    }
}

private struct NotchIslandShape: Shape {
    var progress: CGFloat
    let collapsedSize: CGSize
    let expandedSize: CGSize
    let attachment: OverlayAttachment

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let amount = min(1, max(0, progress))
        let width = collapsedSize.width + (expandedSize.width - collapsedSize.width) * amount
        let height = collapsedSize.height + (expandedSize.height - collapsedSize.height) * amount
        let shapeRect = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
        let topRadius: CGFloat = attachment == .notch ? 0 : min(24, height / 2)
        let bottomRadius = min(16, height / 2)
        return UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: topRadius,
                bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius,
                topTrailing: topRadius
            ),
            style: .continuous
        ).path(in: shapeRect)
    }
}

private struct PhaseActivity: View {
    let phase: DictationPhase
    let level: Float
    let intensity: Double
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            activity
                .id(kind)
                .transition(activityTransition)
        }
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: kind)
    }

    private var kind: ActivityKind {
        switch phase {
        case .armed, .recording: .recording
        case .transcribing, .inserting: .processing
        case .success: .success
        case .cancelled: .cancelled
        case .error: .error
        default: .waiting
        }
    }

    @ViewBuilder
    private var activity: some View {
        switch kind {
        case .recording:
            LevelBars(level: level, intensity: intensity, reduceMotion: reduceMotion)
        case .processing:
            ProcessingDots(reduceMotion: reduceMotion)
        case .success:
            Image(systemName: "checkmark")
        case .cancelled:
            Image(systemName: "xmark").opacity(0.86)
        case .error:
            Image(systemName: "exclamationmark")
        case .waiting:
            Image(systemName: "waveform").opacity(0.72)
        }
    }

    private var activityTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: ActivityTransitionModifier(opacity: 0, scale: 0.72, blur: 6),
                identity: ActivityTransitionModifier(opacity: 1, scale: 1, blur: 0)
            ),
            removal: .modifier(
                active: ActivityTransitionModifier(opacity: 0, scale: 1.18, blur: 6),
                identity: ActivityTransitionModifier(opacity: 1, scale: 1, blur: 0)
            )
        )
    }
}

private enum ActivityKind: Hashable {
    case waiting, recording, processing, success, cancelled, error
}

private struct ActivityTransitionModifier: ViewModifier {
    let opacity: Double
    let scale: CGFloat
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale)
            .blur(radius: blur)
    }
}

private struct LevelBars: View {
    let level: Float
    let intensity: Double
    let reduceMotion: Bool
    private let multipliers: [CGFloat] = [0.55, 0.82, 1, 0.82, 0.55]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(multipliers.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white)
                        .frame(width: 3, height: barHeight(index: index, time: time))
                }
            }
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let input = min(1, max(0, CGFloat(level)))
        let animationStrength = max(0.15, CGFloat(intensity))
        let breathing = reduceMotion
            ? 0
            : (sin(time * 2.4 + Double(index) * 0.72) + 1) * 0.75
        let detail = reduceMotion
            ? 1
            : 0.88 + 0.12 * CGFloat(sin(time * 8.5 + Double(index) * 1.13))
        let voice = input * 14 * animationStrength * multipliers[index] * detail
        return min(21, max(4, 4 + breathing + voice))
    }
}

private struct ProcessingDots: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            dots(time: 0)
        } else {
            TimelineView(.animation) { context in
                dots(time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func dots(time: TimeInterval) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let wave = reduceMotion
                    ? (index == 1 ? 1.0 : 0.35)
                    : 0.5 + 0.5 * sin(time * 5.2 - Double(index) * 1.15)
                Circle()
                    .fill(.white.opacity(0.3 + wave * 0.7))
                    .frame(width: 4, height: 4)
                    .scaleEffect(0.9 + wave * 0.3)
            }
        }
    }
}
