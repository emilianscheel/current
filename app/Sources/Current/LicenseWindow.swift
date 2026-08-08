import AppKit
import CurrentCore
import Observation
import SwiftUI

@MainActor
final class LicenseWindowController: NSObject, NSWindowDelegate {
    private unowned let runtime: AppRuntime
    private var window: NSWindow?

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
    }

    func show(prefilledKey: String? = nil) {
        let view = LicenseView(manager: runtime.license, prefilledKey: prefilledKey)
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Current License"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 480, height: 390))
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        if let prefilledKey {
            Task { await runtime.license.redeem(prefilledKey) }
        }
    }
}

private struct LicenseView: View {
    @Bindable var manager: LicenseManager
    @State private var key: String

    init(manager: LicenseManager, prefilledKey: String?) {
        self.manager = manager
        _key = State(initialValue: prefilledKey ?? manager.currentLicenseKey ?? "")
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: manager.isAuthorized ? "checkmark.seal.fill" : "key.fill")
                .font(.system(size: 48, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(manager.isAuthorized ? .green : .secondary)
            Text(manager.statusTitle)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            if let active = manager.currentLicenseKey {
                Text(active).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                Button("Deactivate This Mac", role: .destructive) {
                    Task { await manager.deactivate() }
                }
                .disabled(manager.isWorking)
            } else {
                TextField("ABC-123-XYZ", text: $key)
                    .font(.system(.title3, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 290)
                    .onChange(of: key) { _, value in key = displayFormat(value) }
                HStack(spacing: 10) {
                    Button("Buy License") {
                        NSWorkspace.shared.open(URL(string: "https://current-mac.vercel.app/checkout")!)
                    }
                    Button("Redeem License") { Task { await manager.redeem(key) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.isWorking || LicenseKeyFormat.normalize(key) == nil)
                }
            }
            if manager.isWorking { ProgressView().controlSize(.small) }
            if let message = manager.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(message.contains("unlocked") ? .green : .secondary)
                    .multilineTextAlignment(.center)
            }
            Text("Payment details stay with Apple Pay and Stripe. Current stores only your license key and an anonymous installation identifier.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayFormat(_ value: String) -> String {
        let compact = value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let limited = String(compact.prefix(9))
        return stride(from: 0, to: limited.count, by: 3).map { offset in
            let start = limited.index(limited.startIndex, offsetBy: offset)
            let end = limited.index(start, offsetBy: min(3, limited.count - offset))
            return String(limited[start..<end])
        }.joined(separator: "-")
    }
}
