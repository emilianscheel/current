import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private unowned let runtime: AppRuntime
    private let auxiliaryWindowID = UUID()
    private var window: NSWindow?

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: AboutView())
            let window = NSWindow(contentViewController: controller)
            window.title = "About Current"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 420, height: 440))
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }

        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        runtime.setAuxiliaryWindow(auxiliaryWindowID, visible: false)
    }
}

private struct AboutView: View {
    private let projectURL = URL(string: "https://github.com/emilianscheel/current")!
    private let licensesURL = URL(string: "https://github.com/emilianscheel/current/blob/main/app/Licenses/NOTICE.md")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0"
    }

    private var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private var versionLine: String {
        guard let build, !build.isEmpty else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)

            Text("Current")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 10)

            Text(versionLine)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 5) {
                informationRow("Privacy", "Private and on-device")
                informationRow("Engine", "FluidAudio / MLX Swift · Apache 2.0")
                informationRow("Speech", "Parakeet TDT 0.6B v3 · CC BY 4.0")
                informationRow("Context", "Gemma 4 E2B 4-bit · Terms of Use")
            }
            .font(.system(size: 13))
            .padding(.top, 24)

            Button {
                NSWorkspace.shared.open(projectURL)
            } label: {
                Text("More Info…")
                    .frame(width: 116)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, 26)

            Spacer(minLength: 16)

            Button {
                NSWorkspace.shared.open(licensesURL)
            } label: {
                Text("Open-source licenses")
                    .underline()
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))

            Text("Copyright © 2026 Current contributors.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 27)
        .padding(.bottom, 16)
        .padding(.horizontal, 24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func informationRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            Text(value)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
        }
    }
}
