import AppKit
import CurrentCore
import Observation
import SwiftUI

@MainActor
@Observable
final class OverlayModel {
    var phase: DictationPhase = .idle
    var visible = false
}

@MainActor
final class NotchOverlayController {
    private let model = OverlayModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(phase: DictationPhase) {
        guard SettingsStore.shared.overlayEnabled else { hide(); return }
        hideTask?.cancel()
        model.phase = phase
        switch phase {
        case .idle, .paused: hide()
        default:
            ensurePanel()
            positionPanel()
            model.visible = true
            panel?.orderFrontRegardless()
            if [.success, .cancelled, .error].contains(phase) {
                hideTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.2))
                    self?.hide()
                }
            }
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 52),
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
        panel.contentView = NSHostingView(rootView: NotchOverlayView(model: model))
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let width: CGFloat = screen.safeAreaInsets.top > 0 ? 260 : 210
        let height: CGFloat = 52
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
    }

    private func hide() {
        model.visible = false
        panel?.orderOut(nil)
    }
}

private struct NotchOverlayView: View {
    @Bindable var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating, isActive: model.phase == .recording || model.phase == .transcribing)
            Text(label).font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background {
            Capsule().fill(reduceTransparency ? Color.black : Color.black.opacity(0.76))
                .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 1))
        }
        .padding(.top, 6)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: model.phase)
    }

    private var symbol: String {
        switch model.phase { case .recording: "waveform"; case .transcribing, .inserting: "ellipsis"; case .success: "checkmark"; case .cancelled: "xmark"; case .error: "exclamationmark"; default: "alternatingcurrent" }
    }
    private var label: String { model.phase.displayName }
    private var tint: Color { model.phase == .error ? .red : model.phase == .success ? .green : .cyan }
}
