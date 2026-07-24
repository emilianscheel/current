import AppKit
import CurrentCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let runtime: AppRuntime
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
        item.button?.image = NSImage(
            systemSymbolName: MenuBarPresentation.symbol(for: runtime.coordinator.phase),
            accessibilityDescription: "Current"
        )
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(runtime.coordinator.phase.displayName, to: menu, enabled: false)
        if !runtime.settings.onboardingComplete {
            add(runtime.permissions.snapshot().allGranted ? "Permissions: Ready" : "Permissions: Action needed", to: menu, enabled: false)
        }
        menu.addItem(.separator())
        add(runtime.coordinator.phase == .recording ? "Stop and Transcribe" : "Start Dictation", to: menu, action: #selector(toggleCapture))
        add("Paste Last Transcription", to: menu, action: #selector(pasteLast), enabled: !runtime.coordinator.lastTranscription.isEmpty)
        add("Copy Last Transcription", to: menu, action: #selector(copyLast), enabled: !runtime.coordinator.lastTranscription.isEmpty)
        menu.addItem(.separator())
        add(runtime.settings.isEnabled ? "Pause Current" : "Resume Current", to: menu, action: #selector(toggleEnabled))
        add(modelTitle, to: menu, enabled: false)
        if !runtime.settings.onboardingComplete {
            add("Permissions & Onboarding…", to: menu, action: #selector(openOnboarding))
        }
        add("About Current", to: menu, action: #selector(openAbout))
        menu.addItem(.separator())
        add("Quit Current", to: menu, action: #selector(quit), key: "q")
    }

    private var modelTitle: String {
        switch runtime.model.state {
        case .ready: "Model: Parakeet TDT v3 Multilingual"
        case .downloading: "Model: Downloading…"
        case .failed: "Model: Action needed"
        default: "Model: Preparing…"
        }
    }

    private func add(_ title: String, to menu: NSMenu, action: Selector? = nil, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func toggleCapture() { runtime.coordinator.beginFromMenu() }
    @objc private func pasteLast() { runtime.coordinator.pasteLastTranscription() }
    @objc private func copyLast() { runtime.coordinator.copyLastTranscription() }
    @objc private func toggleEnabled() { runtime.coordinator.toggleEnabled() }
    @objc private func openOnboarding() { runtime.onboarding.show() }
    @objc private func openAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Current",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            .credits: NSAttributedString(string: "Private, on-device multilingual dictation.\nFluidAudio — Apache 2.0\nParakeet TDT 0.6B v3 — CC BY 4.0")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
