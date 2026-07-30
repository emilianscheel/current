import AppKit
import CurrentCore
import Observation
import SwiftUI

@MainActor
@Observable
final class OnboardingController: NSObject, NSWindowDelegate {
    private unowned let runtime: AppRuntime
    private let auxiliaryWindowID = UUID()
    private var window: NSWindow?
    private var pollTask: Task<Void, Never>?
    var step: OnboardingStep
    var permissions = PermissionSnapshot()
    var practiceText = ""
    var requestedInputMonitoring = false
    var requestedScreenRecording = false

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
                && runtime.contextModel.hasInstalledSnapshot
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
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    func showUnsupported() {
        step = .welcome
        show()
    }

    func close() {
        window?.orderOut(nil)
        onboardingDidHide()
    }

    func windowWillClose(_ notification: Notification) {
        onboardingDidHide()
    }

    func refreshPermissions() {
        permissions = runtime.permissions.snapshot()
    }

    func request(_ kind: PermissionKind) {
        if kind == .inputMonitoring { requestedInputMonitoring = true }
        if kind == .screenRecording { requestedScreenRecording = true }
        Task {
            _ = await runtime.permissions.request(kind)
            refreshPermissions()
            if !permissions[kind].isGranted { runtime.permissions.openSettings(for: kind) }
        }
    }

    func openSettings(_ kind: PermissionKind) { runtime.permissions.openSettings(for: kind) }

    func next() {
        guard let index = OnboardingStep.allCases.firstIndex(of: step), index + 1 < OnboardingStep.allCases.count else { return }
        setStep(OnboardingStep.allCases[index + 1])
    }

    func back() {
        guard let index = OnboardingStep.allCases.firstIndex(of: step), index > 0 else { return }
        setStep(OnboardingStep.allCases[index - 1])
    }

    func restart() { runtime.relaunch() }

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
        pollTask?.cancel()
        pollTask = nil
        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: false)
    }

    private func setStep(_ step: OnboardingStep) {
        withAnimation(.snappy) { self.step = step }
        runtime.settings.onboardingStep = step
    }

}

struct OnboardingView: View {
    @Bindable var controller: OnboardingController
    @Bindable var runtime: AppRuntime

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Group { content }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                Divider().opacity(0.5)
                HStack {
                    if controller.step != .welcome { Button("Back") { controller.back() }.buttonStyle(.plain) }
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
    }

    @ViewBuilder private var content: some View {
        if !runtime.hardware.isSupported {
            StepLayout(symbol: "macbook", title: "This Mac isn’t supported") { EmptyView() }
        } else {
            switch controller.step {
            case .welcome:
                StepLayout(symbol: "alternatingcurrent", title: "Speak. Release. Done.") { EmptyView() }
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
                    VStack(alignment: .leading) {
                        Toggle("Launch Current at login", isOn: $runtime.settings.launchAtLogin)
                        Toggle("Play quiet start and stop sounds", isOn: $runtime.settings.soundsEnabled)
                    }.toggleStyle(.switch).frame(maxWidth: 360)
                }
            case .complete:
                StepLayout(symbol: "checkmark.seal.fill", title: "Current is ready") { EmptyView() }
            }
        }
    }

    private func permissionStep(_ kind: PermissionKind) -> some View {
        StepLayout(symbol: permissionSymbol(kind), title: kind.title) {
            VStack(spacing: 0) {
                Label(controller.permissions[kind].isGranted ? "Granted" : "Waiting for permission", systemImage: controller.permissions[kind].isGranted ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(controller.permissions[kind].isGranted ? .green : .secondary)
                if !controller.permissions[kind].isGranted {
                    Button(controller.permissions[kind] == .notDetermined ? "Continue" : "Allow \(kind.title)") {
                        controller.request(kind)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 28)
                }
                if kind == .inputMonitoring, controller.requestedInputMonitoring,
                   !controller.permissions[kind].isGranted {
                    Button("I enabled it — Restart Current") { controller.restart() }
                        .buttonStyle(.bordered)
                        .padding(.top, 12)
                }
                if kind == .screenRecording, controller.requestedScreenRecording,
                   !controller.permissions[kind].isGranted {
                    Button("I enabled it — Restart Current") { controller.restart() }
                        .buttonStyle(.bordered)
                        .padding(.top, 12)
                }
            }
        }
    }

    @ViewBuilder private var modelProgress: some View {
        VStack(alignment: .leading, spacing: 18) {
            modelRow(
                title: "Speech recognition — Parakeet TDT 0.6B",
                state: runtime.model.state,
                retry: runtime.model.retry
            )
            modelRow(
                title: "Context structuring — Gemma 4 E2B 4-bit",
                state: runtime.contextModel.state,
                retry: runtime.contextModel.retry
            )
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
                && runtime.contextModel.state.isReady
        default: true
        }
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
