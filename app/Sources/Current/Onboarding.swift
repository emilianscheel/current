import AppKit
import ConfettiSwiftUI
import CurrentCore
import Observation
import SwiftUI

enum OnboardingNavigationDirection {
    case forward
    case backward
}

@MainActor
@Observable
final class OnboardingController: NSObject, NSWindowDelegate {
    private unowned let runtime: AppRuntime
    private let auxiliaryWindowID = UUID()
    private var window: NSWindow?
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored private lazy var permissionGuidance =
        PermissionGuidanceOverlayController(
            permissionSnapshot: { [unowned self] in
                self.runtime.permissions.snapshot()
            },
            dropAccepted: { [unowned self] in
                self.focusAfterPermissionDrop()
            }
        )
    @ObservationIgnored private lazy var focusOverlay =
        OnboardingFocusOverlayController()
    var step: OnboardingStep
    var permissions = PermissionSnapshot()
    var practiceText = ""
    var requestedInputMonitoring = false
    var requestedScreenRecording = false
    var navigationDirection = OnboardingNavigationDirection.forward
    var completionCelebration = 0
    private var hasCelebratedCompletion = false

    var restartRequired: Bool {
        runtime.inputMonitoringRestartRequired
            || (requestedInputMonitoring
                && !permissions.inputMonitoring.isGranted)
            || (runtime.settings.contextWorkerEnabled
                && requestedScreenRecording
                && !permissions.screenRecording.isGranted)
    }

    init(runtime: AppRuntime) {
        self.runtime = runtime
        self.step = runtime.settings.onboardingStep
        super.init()
        refreshPermissions()
    }

    func show() {
        step = OnboardingFlow.initialStep(
            saved: step,
            completed: runtime.settings.onboardingComplete,
            permissions: permissions,
            modelInstalled: runtime.model.hasInstalledSnapshot
                && (!runtime.settings.contextWorkerEnabled
                    || runtime.contextModel.hasInstalledSnapshot),
            contextWorkerEnabled: runtime.settings.contextWorkerEnabled,
            restartRequired: restartRequired
        )
        runtime.settings.onboardingStep = step
        if window == nil {
            let view = OnboardingView(controller: self, runtime: runtime)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "Welcome to Current"
            window.styleMask = [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
            ]
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .visible
            let toolbar = NSToolbar(identifier: "Onboarding")
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            window.toolbarStyle = .unified
            window.toolbar = toolbar
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 720, height: 560))
            window.contentMinSize = NSSize(width: 720, height: 560)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: true)
        NSApp.activate(ignoringOtherApps: true)
        let wasAlreadyKey = window?.isKeyWindow == true
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        if wasAlreadyKey, step == .welcome, let window {
            focusOverlay.presentStage(around: window)
        }
        startPolling()
    }

    func showUnsupported() {
        step = .welcome
        show()
    }

    func close() {
        permissionGuidance.dismiss()
        focusOverlay.dismissAll()
        window?.orderOut(nil)
        onboardingDidHide()
    }

    func windowWillClose(_ notification: Notification) {
        onboardingDidHide()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard step == .welcome, let window else { return }
        focusOverlay.presentStage(around: window)
    }

    func windowDidResignKey(_ notification: Notification) {
        focusOverlay.dismissStage()
    }

    func windowDidMove(_ notification: Notification) {
        focusOverlay.refreshWindowGeometry()
    }

    func windowDidResize(_ notification: Notification) {
        focusOverlay.refreshWindowGeometry()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        focusOverlay.refreshWindowGeometry()
    }

    func refreshPermissions() {
        permissions = runtime.effectivePermissionSnapshot()
        if step == .restart, !restartRequired {
            setStep(.model, direction: .forward)
        }
    }

    func requireInputMonitoringRestart() {
        requestedInputMonitoring = true
        refreshPermissions()
    }

    func request(_ kind: PermissionKind) {
        if kind == .inputMonitoring { requestedInputMonitoring = true }
        if kind == .screenRecording { requestedScreenRecording = true }
        if kind != .microphone {
            openSettings(kind)
            return
        }
        let expectsNativePrompt = permissions.microphone == .notDetermined
        if expectsNativePrompt {
            permissionGuidance.dismiss()
            focusOverlay.beginMicrophonePrompt(excluding: window)
        }
        Task {
            _ = await runtime.permissions.request(kind)
            refreshPermissions()
            if expectsNativePrompt {
                focusOverlay.endMicrophonePrompt()
            }
            if !permissions[kind].isGranted { openSettings(kind) }
        }
    }

    func openSettings(_ kind: PermissionKind) {
        focusOverlay.dismissAll()
        runtime.permissions.openSettings(for: kind)
        permissionGuidance.present(for: kind)
    }

    func next() {
        guard let next = OnboardingFlow.adjacentStep(
            from: step,
            direction: 1,
            permissions: permissions,
            contextWorkerEnabled: runtime.settings.contextWorkerEnabled,
            restartRequired: restartRequired
        ) else { return }
        setStep(next, direction: .forward)
    }

    func back() {
        guard let previous = OnboardingFlow.adjacentStep(
            from: step,
            direction: -1,
            permissions: permissions,
            contextWorkerEnabled: runtime.settings.contextWorkerEnabled,
            restartRequired: restartRequired
        ) else { return }
        setStep(previous, direction: .backward)
    }

    func restart() {
        permissionGuidance.dismiss()
        focusOverlay.dismissAll()
        runtime.relaunch()
    }

    func finish() {
        runtime.settings.onboardingComplete = true
        runtime.settings.onboardingStep = .complete
        runtime.applyLaunchAtLogin()
        close()
        runtime.coordinator.startMonitoring()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(650))
                self?.refreshPermissions()
            }
        }
    }

    private func onboardingDidHide() {
        permissionGuidance.dismiss()
        focusOverlay.dismissAll()
        pollTask?.cancel()
        pollTask = nil
        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: false)
    }

    private func focusAfterPermissionDrop() {
        refreshPermissions()
        guard window?.isVisible == true else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func setStep(
        _ step: OnboardingStep,
        direction: OnboardingNavigationDirection
    ) {
        permissionGuidance.dismiss()
        focusOverlay.dismissStage()
        navigationDirection = direction
        let shouldCelebrate = self.step == .preferences
            && step == .complete
            && !hasCelebratedCompletion
            && !runtime.settings.onboardingComplete
        self.step = step
        if shouldCelebrate {
            hasCelebratedCompletion = true
            completionCelebration += 1
        }
        runtime.settings.onboardingStep = step
        if step == .welcome, window?.isKeyWindow == true, let window {
            focusOverlay.presentStage(around: window)
        }
    }

}

struct OnboardingView: View {
    @Bindable var controller: OnboardingController
    @Bindable var runtime: AppRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedStep: OnboardingStep
    @State private var outgoingStep: OnboardingStep?
    @State private var transitionDirection = OnboardingNavigationDirection.forward
    @State private var pageTransitionProgress = CGFloat(1)
    @State private var pageTransitionGeneration = 0

    init(controller: OnboardingController, runtime: AppRuntime) {
        self.controller = controller
        self.runtime = runtime
        _displayedStep = State(initialValue: controller.step)
    }

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    ZStack {
                        if let outgoingStep {
                            content(for: outgoingStep)
                                .padding(40)
                                .opacity(1 - pageTransitionProgress)
                                .offset(
                                    x: pageOffset(
                                        width: geometry.size.width,
                                        outgoing: true
                                    )
                                )
                                .allowsHitTesting(false)
                        }
                        content(for: displayedStep)
                            .padding(40)
                            .opacity(
                                outgoingStep == nil ? 1 : pageTransitionProgress
                            )
                            .offset(
                                x: pageOffset(
                                    width: geometry.size.width,
                                    outgoing: false
                                )
                            )
                        if !reduceMotion {
                            CompletionConfetti(
                                trigger: controller.completionCelebration
                            )
                                .opacity(controller.step == .complete ? 1 : 0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                .onChange(of: controller.step) { _, newStep in
                    animatePageChange(to: newStep)
                }
                Divider().opacity(0.5)
                HStack {
                    if canGoBack {
                        Button("Back") { controller.back() }
                            .buttonStyle(.plain)
                    }
                    Spacer()
                    Button(nextTitle) { advance() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdvance)
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.light)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { keyPress in
            let key: OnboardingArrowKey
            switch keyPress.key {
            case .leftArrow: key = .left
            case .rightArrow: key = .right
            default: return .ignored
            }
            guard let action = OnboardingKeyboardNavigation.action(
                for: key,
                isEditingText: NSApp.keyWindow?.firstResponder is NSTextView,
                canGoBack: canGoBack,
                canAdvance: canAdvance
            ) else { return .ignored }
            switch action {
            case .back: controller.back()
            case .advance: advance()
            }
            return .handled
        }
    }

    @ViewBuilder private func content(for step: OnboardingStep) -> some View {
        if !runtime.hardware.isSupported {
            StepLayout(symbol: "macbook", title: "This Mac isn’t supported") {
                Text(runtime.hardware.reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            switch step {
            case .welcome:
                StepLayout(symbol: "alternatingcurrent", title: "Speak. Release. Done.") {
                    if !runtime.hardware.supportsContextWorker {
                        Text("This Mac will use dictation-first mode. Local speech recognition and insertion are available; memory-intensive prompt writing and screen context require at least 16 GiB of unified memory.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                }
            case .microphone: permissionStep(.microphone)
            case .accessibility: permissionStep(.accessibility)
            case .screenRecording: permissionStep(.screenRecording)
            case .inputMonitoring: permissionStep(.inputMonitoring)
            case .restart:
                StepLayout(symbol: "arrow.clockwise.circle", title: "One quick restart") {
                    Button("Restart Current") { controller.restart() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            case .model:
                StepLayout(symbol: "cpu", title: "Preparing on-device models") {
                    modelProgress
                }
            case .practice:
                StepLayout(symbol: "text.cursor", title: "Try it here") {
                    TextEditor(text: $controller.practiceText)
                        .font(.title3).scrollContentBackground(.hidden).padding(12)
                        .frame(height: 120)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                }
            case .preferences:
                StepLayout(symbol: "checkmark.circle", title: "Ready when you are") {
                    VStack(spacing: 10) {
                        preferenceCard(
                            title: "Launch Current at login",
                            symbol: "arrow.clockwise.circle",
                            isSelected: $runtime.settings.launchAtLogin
                        )
                        preferenceCard(
                            title: "Play quiet start and stop sounds",
                            symbol: "speaker.wave.2",
                            isSelected: $runtime.settings.soundsEnabled
                        )
                    }
                    .frame(maxWidth: 360)
                }
            case .complete:
                StepLayout(symbol: "checkmark.seal.fill", title: "Current is ready") { EmptyView() }
            }
        }
    }

    private func preferenceCard(
        title: String,
        symbol: String,
        isSelected: Binding<Bool>
    ) -> some View {
        Button {
            isSelected.wrappedValue.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(
                        isSelected.wrappedValue ? Color.accentColor : Color.secondary
                    )
                    .frame(width: 22)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .contentShape(.rect)
            .background(
                isSelected.wrappedValue
                    ? Color.accentColor.opacity(0.07)
                    : Color.white,
                in: .rect(cornerRadius: 11)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(
                        isSelected.wrappedValue
                            ? Color.accentColor
                            : Color(nsColor: .separatorColor).opacity(0.7),
                        lineWidth: isSelected.wrappedValue ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected.wrappedValue ? "On" : "Off")
    }

    private func permissionStep(_ kind: PermissionKind) -> some View {
        let isGranted = controller.permissions[kind].isGranted
        return StepLayout(symbol: permissionSymbol(kind), title: kind.title) {
            VStack(spacing: 0) {
                Group {
                    if isGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(permissionStatusTransition)
                    } else {
                        Button { controller.request(kind) } label: {
                            Label(
                                "Waiting for permission",
                                systemImage: "circle.dotted"
                            )
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .transition(permissionStatusTransition)
                    }
                }
                .id(isGranted)
                if !isGranted {
                    Button(controller.permissions[kind] == .notDetermined ? "Continue" : "Allow \(kind.title)") {
                        controller.request(kind)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 28)
                    .transition(permissionControlTransition)
                }
                if kind == .inputMonitoring, controller.requestedInputMonitoring,
                   !isGranted {
                    Button("I enabled it — Restart Current") { controller.restart() }
                        .buttonStyle(.bordered)
                        .padding(.top, 12)
                        .transition(permissionControlTransition)
                }
                if kind == .screenRecording, controller.requestedScreenRecording,
                   !isGranted {
                    Button("I enabled it — Restart Current") { controller.restart() }
                        .buttonStyle(.bordered)
                        .padding(.top, 12)
                        .transition(permissionControlTransition)
                }
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.16) : .snappy,
                value: isGranted
            )
        }
    }

    private var pageAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .snappy(duration: 0.38)
    }

    private func animatePageChange(to newStep: OnboardingStep) {
        guard newStep != displayedStep else { return }
        let generation = pageTransitionGeneration + 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageTransitionGeneration = generation
            transitionDirection = controller.navigationDirection
            outgoingStep = displayedStep
            displayedStep = newStep
            pageTransitionProgress = 0
        }
        withAnimation(pageAnimation) {
            pageTransitionProgress = 1
        } completion: {
            guard pageTransitionGeneration == generation else { return }
            outgoingStep = nil
        }
    }

    private func pageOffset(width: CGFloat, outgoing: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let direction: CGFloat = transitionDirection == .forward ? 1 : -1
        if outgoing {
            return -direction * width * pageTransitionProgress
        }
        return direction * width * (1 - pageTransitionProgress)
    }

    private var permissionStatusTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
    }

    private var permissionControlTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .bottom))
    }

    @ViewBuilder private var modelProgress: some View {
        VStack(alignment: .leading, spacing: 18) {
            modelRow(
                title: "Speech recognition — Parakeet TDT 0.6B",
                state: runtime.model.state,
                retry: runtime.model.retry
            )
            if runtime.settings.contextWorkerEnabled {
                modelRow(
                    title: "Context structuring — Gemma 4 E2B 4-bit",
                    state: runtime.contextModel.state,
                    retry: runtime.contextModel.retry
                )
            }
        }
        .frame(maxWidth: 440)
    }

    @ViewBuilder private func modelRow(
        title: String,
        state: ModelState,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            switch state {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let error):
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Retry", action: retry)
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading…")
                }
            case .verifying:
                ProgressView("Verifying…")
            case .loading:
                ProgressView("Loading…")
            case .notInstalled:
                ProgressView("Preparing…")
            }
        }
    }

    private var canAdvance: Bool {
        guard runtime.hardware.isSupported else { return false }
        return switch controller.step {
        case .microphone: controller.permissions.microphone.isGranted
        case .accessibility: controller.permissions.accessibility.isGranted
        case .screenRecording: controller.permissions.screenRecording.isGranted
        case .inputMonitoring: controller.permissions.inputMonitoring.isGranted
        case .restart: false
        case .model:
            runtime.model.state.isReady
                && (!runtime.settings.contextWorkerEnabled
                    || runtime.contextModel.state.isReady)
        default: true
        }
    }
    private var canGoBack: Bool {
        OnboardingFlow.adjacentStep(
            from: controller.step,
            direction: -1,
            permissions: controller.permissions,
            contextWorkerEnabled: runtime.settings.contextWorkerEnabled,
            restartRequired: controller.restartRequired
        ) != nil
    }
    private var nextTitle: String { controller.step == .complete ? "Done" : "Continue" }
    private func advance() { controller.step == .complete ? controller.finish() : controller.next() }
    private func permissionSymbol(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "mic"
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .inputMonitoring: "keyboard"
        }
    }
}

private struct CompletionConfetti: View {
    let trigger: Int
    @State private var leftTrigger = 0
    @State private var rightTrigger = 0

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .frame(width: 1, height: 1)
                .confettiCannon(
                    trigger: $leftTrigger,
                    num: 70,
                    colors: confettiColors,
                    confettiSize: 9,
                    rainHeight: geometry.size.height * 1.15,
                    openingAngle: .degrees(18),
                    closingAngle: .degrees(78),
                    radius: geometry.size.width * 0.72,
                    hapticFeedback: false
                )
                .position(x: 0, y: geometry.size.height)

            Color.clear
                .frame(width: 1, height: 1)
                .confettiCannon(
                    trigger: $rightTrigger,
                    num: 70,
                    colors: confettiColors,
                    confettiSize: 9,
                    rainHeight: geometry.size.height * 1.15,
                    openingAngle: .degrees(102),
                    closingAngle: .degrees(162),
                    radius: geometry.size.width * 0.72,
                    hapticFeedback: false
                )
                .position(
                    x: geometry.size.width,
                    y: geometry.size.height
                )
        }
        .task(id: trigger) {
            guard trigger > 0 else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            leftTrigger += 1
            rightTrigger += 1
        }
    }

    private var confettiColors: [Color] {
        [.blue, .cyan, .green, .orange, .pink, .purple, .yellow]
    }
}

private struct StepLayout<Content: View>: View {
    let symbol: String; let title: String; @ViewBuilder let content: Content
    init(symbol: String, title: String, @ViewBuilder content: () -> Content) {
        self.symbol = symbol; self.title = title; self.content = content()
    }
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.gray)
            Text(title).font(.system(size: 30, weight: .semibold, design: .rounded))
            content.padding(.top, 8)
        }
    }
}
