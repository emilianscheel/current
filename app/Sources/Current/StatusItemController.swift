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
        add(captureTitle, to: menu, action: #selector(toggleCapture))
        add("Paste Last Transcription", to: menu, action: #selector(pasteLast), enabled: !runtime.coordinator.lastTranscription.isEmpty)
        add("Copy Last Transcription", to: menu, action: #selector(copyLast), enabled: !runtime.coordinator.lastTranscription.isEmpty)
        add("Undo Last Insertion", to: menu, action: #selector(undoLast), enabled: runtime.coordinator.insertion.canUndoLastInsertion)
        add("Context…", to: menu, action: #selector(openContext))
        add("Usage Statistics…", to: menu, action: #selector(openUsageStatistics))
        menu.addItem(.separator())
        add(runtime.settings.isEnabled ? "Pause Current" : "Resume Current", to: menu, action: #selector(toggleEnabled))
        add(speechModelTitle, to: menu, enabled: false)
        add(contextModelTitle, to: menu, enabled: false)
        if !runtime.settings.onboardingComplete {
            add("Permissions & Onboarding…", to: menu, action: #selector(openOnboarding))
        }
        add("About Current", to: menu, action: #selector(openAbout))
        menu.addItem(.separator())
        add("Quit Current", to: menu, action: #selector(quit), key: "q")
    }

    private var speechModelTitle: String {
        switch runtime.model.state {
        case .ready: "Speech model: Parakeet TDT v3 Multilingual"
        case .downloading: "Speech model: Downloading…"
        case .failed: "Speech model: Action needed"
        default: "Speech model: Preparing…"
        }
    }

    private var captureTitle: String {
        if runtime.coordinator.phase == .recording {
            return "Stop and Transcribe"
        }
        if !runtime.settings.isEnabled
            || runtime.coordinator.phase == .paused {
            return "Resume and Start Dictation"
        }
        return "Start Dictation"
    }

    private var contextModelTitle: String {
        switch runtime.contextModel.state {
        case .ready: "Context model: Gemma 4 E2B 4-bit"
        case .downloading: "Context model: Downloading…"
        case .failed: "Context model: Action needed"
        default: "Context model: Preparing…"
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
    @objc private func undoLast() { runtime.coordinator.undoLastInsertion() }
    @objc private func openContext() { runtime.context.show() }
    @objc private func openUsageStatistics() { runtime.usage.show() }
    @objc private func toggleEnabled() { runtime.coordinator.toggleEnabled() }
    @objc private func openOnboarding() { runtime.onboarding.show() }
    @objc private func openAbout() { runtime.about.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
