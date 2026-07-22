import AppKit
import CurrentCore
import Observation
import SwiftUI

@MainActor
@Observable
final class OnboardingController {
    private unowned let runtime: AppRuntime
    private var window: NSWindow?
    private var pollTask: Task<Void, Never>?
    var step: OnboardingStep
    var permissions = PermissionSnapshot()
    var practiceText = ""
    var requestedInputMonitoring = false

    init(runtime: AppRuntime) {
        self.runtime = runtime
        self.step = runtime.settings.onboardingStep
        refreshPermissions()
    }

    func show() {
        step = OnboardingFlow.initialStep(
            saved: step,
            completed: runtime.settings.onboardingComplete,
            permissions: permissions,
            modelInstalled: runtime.model.hasInstalledSnapshot
        )
        runtime.settings.onboardingStep = step
        if window == nil {
            let view = OnboardingView(controller: self, runtime: runtime)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "Welcome to Current"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 720, height: 560))
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        runtime.applyDockPolicy()
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
        pollTask?.cancel()
    }

    func refreshPermissions() {
        let previous = permissions
        permissions = runtime.permissions.snapshot()
        guard window?.isVisible == true else { return }
        if previous != permissions { autoAdvanceIfPossible() }
    }

    func request(_ kind: PermissionKind) {
        if kind == .inputMonitoring { requestedInputMonitoring = true }
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

    private func autoAdvanceIfPossible() {
        if let destination = OnboardingFlow.automaticDestination(from: step, permissions: permissions) { setStep(destination) }
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
            LinearGradient(colors: [Color.indigo.opacity(0.28), Color.cyan.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Label("Current", systemImage: "alternatingcurrent")
                        .font(.headline)
                    Spacer()
                    Text(progressLabel).font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
                Divider().opacity(0.5)
                Group { content }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                Divider().opacity(0.5)
                HStack {
                    if controller.step != .welcome { Button("Back") { controller.back() }.buttonStyle(.plain) }
                    Spacer()
                    if showNext { Button(nextTitle) { advance() }.buttonStyle(.borderedProminent).controlSize(.large) }
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        if !runtime.hardware.isSupported {
            StepLayout(symbol: "macbook", title: "This Mac isn’t supported", text: runtime.hardware.reason) {
                Text("Current is optimized for M3-or-newer MacBooks with at least 16 GB of unified memory.")
                    .foregroundStyle(.secondary)
            }
        } else {
            switch controller.step {
            case .welcome:
                StepLayout(symbol: "alternatingcurrent", title: "Speak. Release. Done.", text: "Hold fn, speak naturally, then release to type into the app you were using.") {
                    VStack(alignment: .leading, spacing: 12) {
                        FeatureRow(symbol: "lock.shield", text: "Audio and transcription stay on this Mac")
                        FeatureRow(symbol: "waveform", text: "Parakeet Unified runs on the Neural Engine")
                        FeatureRow(symbol: "arrow.down.circle", text: modelSummary)
                    }
                }
            case .microphone: permissionStep(.microphone)
            case .accessibility: permissionStep(.accessibility)
            case .inputMonitoring: permissionStep(.inputMonitoring)
            case .restart:
                StepLayout(symbol: "arrow.clockwise.circle", title: "One quick restart", text: "macOS activates Input Monitoring after Current restarts. Your model download and onboarding place are preserved.") {
                    Button("Restart Current") { controller.restart() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            case .model:
                StepLayout(symbol: "cpu", title: "Preparing on-device speech", text: "Current is downloading and compiling the English Parakeet model for this Mac.") {
                    modelProgress
                }
            case .practice:
                StepLayout(symbol: "text.cursor", title: "Try it here", text: "Click the field, hold fn, say a short sentence, and release.") {
                    TextEditor(text: $controller.practiceText)
                        .font(.title3).scrollContentBackground(.hidden).padding(12)
                        .frame(height: 120).background(.black.opacity(0.25), in: .rect(cornerRadius: 14))
                }
            case .preferences:
                StepLayout(symbol: "checkmark.circle", title: "Ready when you are", text: "Choose two useful defaults. You can change these later in Settings.") {
                    VStack(alignment: .leading) {
                        Toggle("Launch Current at login", isOn: $runtime.settings.launchAtLogin)
                        Toggle("Play quiet start and stop sounds", isOn: $runtime.settings.soundsEnabled)
                    }.toggleStyle(.switch).frame(maxWidth: 360)
                }
            case .complete:
                StepLayout(symbol: "checkmark.seal.fill", title: "Current is ready", text: "Current now lives in the menu bar. Hold fn in any editable field to dictate.") { EmptyView() }
            }
        }
    }

    private func permissionStep(_ kind: PermissionKind) -> some View {
        StepLayout(symbol: permissionSymbol(kind), title: "Allow \(kind.title)", text: kind.explanation) {
            VStack(spacing: 12) {
                Label(controller.permissions[kind].isGranted ? "Granted" : "Waiting for permission", systemImage: controller.permissions[kind].isGranted ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(controller.permissions[kind].isGranted ? .green : .secondary)
                Button(controller.permissions[kind] == .notDetermined ? "Continue" : "Allow \(kind.title)") {
                    controller.request(kind)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                if kind == .inputMonitoring, controller.requestedInputMonitoring {
                    Button("I enabled it — Restart Current") { controller.restart() }.buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var modelProgress: some View {
        switch runtime.model.state {
        case .ready: Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let error):
            VStack { Text(error).foregroundStyle(.red); Button("Retry") { runtime.model.retry() } }
        case .downloading(let progress):
            ProgressView(value: progress) { Text("Downloading…") }.frame(maxWidth: 340)
        default: ProgressView("Preparing…")
        }
    }

    private var progressLabel: String {
        let index = OnboardingStep.allCases.firstIndex(of: controller.step) ?? 0
        return "Step \(min(index + 1, 8)) of 8"
    }
    private var modelSummary: String { runtime.model.state.isReady ? "Local model ready" : "Model download started automatically" }
    private var showNext: Bool {
        switch controller.step {
        case .microphone, .accessibility, .inputMonitoring, .restart: false
        case .model: runtime.model.state.isReady
        default: true
        }
    }
    private var nextTitle: String { controller.step == .complete ? "Done" : "Continue" }
    private func advance() { controller.step == .complete ? controller.finish() : controller.next() }
    private func permissionSymbol(_ kind: PermissionKind) -> String {
        switch kind { case .microphone: "mic"; case .accessibility: "accessibility"; case .inputMonitoring: "keyboard" }
    }
}

private struct StepLayout<Content: View>: View {
    let symbol: String; let title: String; let text: String; @ViewBuilder let content: Content
    init(symbol: String, title: String, text: String, @ViewBuilder content: () -> Content) {
        self.symbol = symbol; self.title = title; self.text = text; self.content = content()
    }
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol).font(.system(size: 52, weight: .medium)).symbolRenderingMode(.hierarchical).foregroundStyle(.cyan)
            Text(title).font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(text).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            content.padding(.top, 8)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String; let text: String
    var body: some View { Label(text, systemImage: symbol).foregroundStyle(.secondary) }
}
