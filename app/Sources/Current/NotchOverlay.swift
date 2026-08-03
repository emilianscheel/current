import AppKit
import CoreGraphics
import CurrentCore
import Observation
import QuartzCore
import SwiftUI

@MainActor
@Observable
final class OverlayModel {
    var phase: DictationPhase = .idle
    var targetApplication: InsertionService.TargetApplicationPresentation?
    var editingWordCount = 0
    var partialTranscript = ""
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
    private var surfaceView: NotchOverlaySurfaceView?
    private var autoHideTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var sessionDisplayID: CGDirectDisplayID?
    private var presentation = OverlayPresentationMachine()
    private lazy var waveform = WaveformLevelDriver(audio: audio)

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
        targetApplication: InsertionService.TargetApplicationPresentation?,
        editingWordCount: Int = 0,
        partialTranscript: String = ""
    ) {
        guard settings.overlayEnabled else { collapse(); return }
        autoHideTask?.cancel()

        switch phase {
        case .idle, .paused:
            collapse()
        default:
            ensurePanel()
            surfaceView?.updateContent(
                phase: phase,
                targetApplication: targetApplication,
                editingWordCount: editingWordCount,
                partialTranscript: partialTranscript
            )
            waveform.setActive(
                phase == .armed || phase == .recording,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            if presentation.state == .hidden {
                sessionDisplayID = Self.preferredScreen().flatMap(Self.displayID(for:))
                repositionPanel()
            }
            presentIfNeeded()
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
        let surfaceView = NotchOverlaySurfaceView(
            model: model,
            waveform: waveform,
            settings: settings
        )
        surfaceView.autoresizingMask = [.width, .height]
        panel.contentView = surfaceView
        self.surfaceView = surfaceView
        self.panel = panel
    }

    private func presentIfNeeded() {
        guard let panel, let surfaceView,
              case let .present(generation) = presentation.requestVisible(true) else { return }
        panel.orderFrontRegardless()
        surfaceView.present(
            intensity: settings.animationIntensity,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) { [weak self] in
            _ = self?.presentation.completePresentation(generation: generation)
        }
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
        waveform.setActive(false, reduceMotion: true)
        guard let panel, let surfaceView,
              case let .dismiss(generation) = presentation.requestVisible(false) else {
            if presentation.state == .hidden { clearContent() }
            return
        }
        surfaceView.dismiss(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) { [weak self, weak panel] in
            guard let self,
                  self.presentation.completeDismissal(generation: generation) else { return }
            panel?.orderOut(nil)
            sessionDisplayID = nil
            clearContent()
        }
    }

    private func clearContent() {
        model.targetApplication = nil
        model.editingWordCount = 0
        model.partialTranscript = ""
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
        surfaceView?.updateLayout(layout)
        waveform.updateScreen(screen)
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

@MainActor
@Observable
private final class WaveformLevelDriver {
    private(set) var level: Float = 0
    private(set) var timestamp: CFTimeInterval = 0
    @ObservationIgnored private let audio: AudioCaptureService
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var smoother = WaveformLevelSmoother()
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var reduceMotion = false
    @ObservationIgnored private var screenNumber: NSNumber?

    init(audio: AudioCaptureService) {
        self.audio = audio
    }

    func updateScreen(_ screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard displayLink == nil || number != screenNumber else { return }
        displayLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = !isActive || reduceMotion
        displayLink = link
        screenNumber = number
        lastTimestamp = nil
    }

    func setActive(_ active: Bool, reduceMotion: Bool) {
        isActive = active
        self.reduceMotion = reduceMotion
        lastTimestamp = nil
        if !active {
            displayLink?.isPaused = true
            smoother.reset()
            level = 0
            timestamp = 0
        } else if reduceMotion {
            displayLink?.isPaused = true
            level = audio.currentMeterLevel
        } else {
            displayLink?.isPaused = false
        }
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard isActive, !reduceMotion else {
            displayLink.isPaused = true
            return
        }
        let deltaTime = lastTimestamp.map { displayLink.timestamp - $0 } ?? (1.0 / 60.0)
        lastTimestamp = displayLink.timestamp
        timestamp = displayLink.timestamp
        level = smoother.update(target: audio.currentMeterLevel, deltaTime: deltaTime)
    }
}

@MainActor
private final class NotchOverlaySurfaceView: NSView {
    private let model: OverlayModel
    private let shapeLayer = CAShapeLayer()
    private let hostingView: NSHostingView<NotchOverlayContentView>
    private var layoutValue: OverlayLayout

    override var isFlipped: Bool { true }

    init(model: OverlayModel, waveform: WaveformLevelDriver, settings: SettingsStore) {
        self.model = model
        layoutValue = model.layout
        hostingView = NSHostingView(
            rootView: NotchOverlayContentView(
                model: model,
                waveform: waveform,
                settings: settings
            )
        )
        super.init(frame: model.layout.panelFrame)

        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        shapeLayer.fillColor = NSColor.black.cgColor
        shapeLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shapeLayer)

        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.opacity = 0
        hostingView.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.9, y: 0.9))
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
        shapeLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shapeLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    func updateLayout(_ layout: OverlayLayout) {
        layoutValue = layout
        needsLayout = true
        layoutSubtreeIfNeeded()
        let expanded = hostingView.layer?.opacity == 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.path = path(expanded: expanded)
        CATransaction.commit()
    }

    func updateContent(
        phase: DictationPhase,
        targetApplication: InsertionService.TargetApplicationPresentation?,
        editingWordCount: Int,
        partialTranscript: String
    ) {
        model.phase = phase
        model.partialTranscript = partialTranscript
        guard phase == .armed || phase == .recording else { return }
        let targetChanged = model.targetApplication?.processIdentifier
            != targetApplication?.processIdentifier
        let wordCountChanged = model.editingWordCount != editingWordCount
        guard targetChanged || wordCountChanged else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            model.targetApplication = targetApplication
            model.editingWordCount = editingWordCount
        }
    }

    func present(intensity: Double, reduceMotion: Bool, completion: @escaping () -> Void) {
        animate(
            expanded: true,
            intensity: intensity,
            reduceMotion: reduceMotion,
            completion: completion
        )
    }

    func dismiss(reduceMotion: Bool, completion: @escaping () -> Void) {
        animate(
            expanded: false,
            intensity: 0,
            reduceMotion: reduceMotion,
            completion: completion
        )
    }

    private func animate(
        expanded: Bool,
        intensity: Double,
        reduceMotion: Bool,
        completion: @escaping () -> Void
    ) {
        layoutSubtreeIfNeeded()
        let policy = OverlayAnimationPolicy(reduceMotion: reduceMotion)
        let currentPath = shapeLayer.presentation()?.path ?? shapeLayer.path ?? path(expanded: !expanded)
        let currentOpacity = hostingView.layer?.presentation()?.opacity
            ?? hostingView.layer?.opacity ?? (expanded ? 0 : 1)
        let currentTransform = hostingView.layer?.presentation()?.affineTransform()
            ?? hostingView.layer?.affineTransform() ?? .identity
        let targetPath = path(expanded: expanded)
        let targetOpacity: Float = expanded ? 1 : 0
        let targetTransform = expanded
            ? CGAffineTransform.identity
            : CGAffineTransform(scaleX: 0.9, y: 0.9)

        shapeLayer.removeAllAnimations()
        hostingView.layer?.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        shapeLayer.path = targetPath
        hostingView.layer?.opacity = targetOpacity
        hostingView.layer?.setAffineTransform(targetTransform)

        if policy.animatesShape {
            let pathAnimation: CABasicAnimation
            if expanded {
                let clampedIntensity = max(0, min(1, intensity))
                let response = 0.32 + (1 - clampedIntensity) * 0.05
                let dampingFraction = 0.9 - clampedIntensity * 0.06
                let angularFrequency = (2 * Double.pi) / response
                let spring = CASpringAnimation(keyPath: "path")
                spring.mass = 1
                spring.stiffness = angularFrequency * angularFrequency
                spring.damping = 2 * dampingFraction * angularFrequency
                spring.duration = spring.settlingDuration
                pathAnimation = spring
            } else {
                let basic = CABasicAnimation(keyPath: "path")
                basic.duration = 0.26
                basic.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pathAnimation = basic
            }
            pathAnimation.fromValue = currentPath
            shapeLayer.add(pathAnimation, forKey: "notchMorph")
        }

        let contentAnimation = CABasicAnimation(keyPath: "opacity")
        contentAnimation.fromValue = currentOpacity
        contentAnimation.duration = expanded
            ? policy.presentationContentDuration
            : policy.dismissalContentDuration
        contentAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hostingView.layer?.add(contentAnimation, forKey: "contentOpacity")

        if policy.animatesShape {
            let transformAnimation = CABasicAnimation(keyPath: "transform")
            transformAnimation.fromValue = CATransform3DMakeAffineTransform(currentTransform)
            transformAnimation.duration = expanded ? 0.18 : 0.12
            transformAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hostingView.layer?.add(transformAnimation, forKey: "contentTransform")
        }
        CATransaction.commit()
    }

    private func path(expanded: Bool) -> CGPath {
        let size = expanded ? layoutValue.expandedSize : layoutValue.collapsedSize
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: layoutValue.topPadding,
            width: size.width,
            height: size.height
        )
        let topRadius: CGFloat = layoutValue.attachment == .notch ? 0 : min(24, size.height / 2)
        return Self.roundedPath(
            rect: rect,
            topRadius: topRadius,
            bottomRadius: min(16, size.height / 2)
        )
    }

    private static func roundedPath(
        rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let kappa: CGFloat = 0.552_284_75
        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY
        let top = min(topRadius, rect.width / 2, rect.height / 2)
        let bottom = min(bottomRadius, rect.width / 2, rect.height / 2)

        path.move(to: CGPoint(x: minX + top, y: minY))
        path.addLine(to: CGPoint(x: maxX - top, y: minY))
        path.addCurve(
            to: CGPoint(x: maxX, y: minY + top),
            control1: CGPoint(x: maxX - top + top * kappa, y: minY),
            control2: CGPoint(x: maxX, y: minY + top - top * kappa)
        )
        path.addLine(to: CGPoint(x: maxX, y: maxY - bottom))
        path.addCurve(
            to: CGPoint(x: maxX - bottom, y: maxY),
            control1: CGPoint(x: maxX, y: maxY - bottom + bottom * kappa),
            control2: CGPoint(x: maxX - bottom + bottom * kappa, y: maxY)
        )
        path.addLine(to: CGPoint(x: minX + bottom, y: maxY))
        path.addCurve(
            to: CGPoint(x: minX, y: maxY - bottom),
            control1: CGPoint(x: minX + bottom - bottom * kappa, y: maxY),
            control2: CGPoint(x: minX, y: maxY - bottom + bottom * kappa)
        )
        path.addLine(to: CGPoint(x: minX, y: minY + top))
        path.addCurve(
            to: CGPoint(x: minX + top, y: minY),
            control1: CGPoint(x: minX, y: minY + top - top * kappa),
            control2: CGPoint(x: minX + top - top * kappa, y: minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct NotchOverlayContentView: View {
    @Bindable var model: OverlayModel
    let waveform: WaveformLevelDriver
    let settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(.horizontal, 20)
            .frame(
                width: model.layout.expandedSize.width,
                height: model.layout.expandedSize.height
            )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, model.layout.topPadding)
    }

    private var content: some View {
        HStack(spacing: 16) {
            targetApplicationIcon
            if model.editingWordCount > 0 {
                Text("Editing \(model.editingWordCount) \(model.editingWordCount == 1 ? "word" : "words")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            } else if !model.partialTranscript.isEmpty {
                Text(model.partialTranscript)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .transition(.opacity)
            }
            Spacer(minLength: 20)
            PhaseActivity(
                phase: model.phase,
                waveform: waveform,
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

private struct PhaseActivity: View {
    let phase: DictationPhase
    let waveform: WaveformLevelDriver
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
        case .transcribing, .classifying, .gatheringContext, .generating,
             .inserting: .processing
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
            LevelBars(waveform: waveform, intensity: intensity, reduceMotion: reduceMotion)
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
                active: ActivityTransitionModifier(opacity: 0, scale: 0.78),
                identity: ActivityTransitionModifier(opacity: 1, scale: 1)
            ),
            removal: .modifier(
                active: ActivityTransitionModifier(opacity: 0, scale: 1.12),
                identity: ActivityTransitionModifier(opacity: 1, scale: 1)
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

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale)
    }
}

private struct LevelBars: View {
    @Bindable var waveform: WaveformLevelDriver
    let intensity: Double
    let reduceMotion: Bool
    private let multipliers: [CGFloat] = [0.55, 0.82, 1, 0.82, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(multipliers.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(
                        width: 3,
                        height: barHeight(index: index, time: waveform.timestamp)
                    )
            }
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let input = min(1, max(0, CGFloat(waveform.level)))
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
