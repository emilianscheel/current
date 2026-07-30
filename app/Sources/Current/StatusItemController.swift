import AppKit
import CurrentCore

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
        let permissions = runtime.effectivePermissionSnapshot()
        let onboardingTitle = MenuBarPresentation.onboardingActionTitle(
            completed: runtime.settings.onboardingComplete,
            permissions: permissions,
            contextWorkerEnabled: runtime.settings.contextWorkerEnabled
        )
        add(
            runtime.coordinator.phase.displayName,
            to: menu,
            symbol: MenuBarPresentation.symbol(for: runtime.coordinator.phase),
            enabled: false
        )
        if onboardingTitle != nil {
            add(
                permissionStatusTitle(permissions),
                to: menu,
                symbol: permissions.allGranted(
                    contextWorkerEnabled: runtime.settings.contextWorkerEnabled
                ) ? "checkmark.shield" : "exclamationmark.triangle",
                enabled: false
            )
        }
        menu.addItem(.separator())
        add(
            captureTitle,
            to: menu,
            action: #selector(toggleCapture),
            symbol: runtime.coordinator.phase == .recording ? "stop" : "waveform",
            enabled: !runtime.inputMonitoringRestartRequired
        )
        add(
            "Paste Last Transcription",
            to: menu,
            action: #selector(pasteLast),
            symbol: "doc.on.clipboard",
            enabled: !runtime.coordinator.lastTranscription.isEmpty
        )
        add(
            "Copy Last Transcription",
            to: menu,
            action: #selector(copyLast),
            symbol: "doc.on.doc",
            enabled: !runtime.coordinator.lastTranscription.isEmpty
        )
        add(
            "Undo Last Insertion",
            to: menu,
            action: #selector(undoLast),
            symbol: "arrow.uturn.backward",
            enabled: runtime.coordinator.insertion.canUndoLastInsertion
        )
        add(
            "Context…", to: menu, action: #selector(openContext), symbol: "doc.text.magnifyingglass"
        )
        add(
            "Usage Statistics…", to: menu, action: #selector(openUsageStatistics),
            symbol: "chart.bar")
        if let onboardingTitle {
            add(
                onboardingTitle,
                to: menu,
                action: #selector(openOnboarding),
                symbol: permissions.allGranted(
                    contextWorkerEnabled: runtime.settings.contextWorkerEnabled
                ) ? "checklist" : "hand.raised"
            )
        }
        menu.addItem(.separator())
        add(
            runtime.settings.isEnabled ? "Pause Current" : "Resume Current",
            to: menu,
            action: #selector(toggleEnabled),
            symbol: runtime.settings.isEnabled ? "pause" : "play"
        )
        add(
            runtime.settings.contextWorkerEnabled
                ? "Pause Context Worker"
                : "Resume Context Worker",
            to: menu,
            action: #selector(toggleContextWorker),
            symbol: runtime.settings.contextWorkerEnabled
                ? "pause"
                : "play"
        )
        addModel(
            "Parakeet TDT v3 Multilingual",
            category: "Speech model",
            state: runtime.model.state,
            to: menu
        )
        addModel(
            "Gemma 4 E2B 4-bit",
            category: "Context model",
            state: runtime.contextModel.state,
            statusOverride: runtime.settings.contextWorkerEnabled
                ? nil : "Disabled",
            to: menu
        )
        add("About Current", to: menu, action: #selector(openAbout), symbol: "info.circle")
        menu.addItem(.separator())
        add("Quit Current", to: menu, action: #selector(quit), key: "q", symbol: "power")
    }

    private var captureTitle: String {
        if runtime.coordinator.phase == .recording {
            return "Stop and Transcribe"
        }
        if !runtime.settings.isEnabled
            || runtime.coordinator.phase == .paused
        {
            return "Resume and Start Dictation"
        }
        return "Start Dictation"
    }

    private func permissionStatusTitle(
        _ permissions: PermissionSnapshot
    ) -> String {
        if runtime.inputMonitoringRestartRequired {
            return "Permissions: Restart required"
        }
        return permissions.allGranted(
            contextWorkerEnabled: runtime.settings.contextWorkerEnabled
        ) ? "Permissions: Ready" : "Permissions: Action needed"
    }

    private func add(
        _ title: String,
        to menu: NSMenu,
        action: Selector? = nil,
        key: String = "",
        symbol: String? = nil,
        enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        if let symbol {
            item.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: title
            )
            item.image?.isTemplate = true
        }
        menu.addItem(item)
    }

    private func addModel(
        _ title: String,
        category: String,
        state: ModelState,
        statusOverride: String? = nil,
        to menu: NSMenu
    ) {
        let status =
            statusOverride
            ?? MenuBarPresentation.modelStatusTitle(for: state)
        let subtitle = "\(category) · \(status)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = ModelMenuItemView(title: title, subtitle: subtitle)
        menu.addItem(item)
    }

    @objc private func toggleCapture() { runtime.coordinator.beginFromMenu() }
    @objc private func pasteLast() { runtime.coordinator.pasteLastTranscription() }
    @objc private func copyLast() { runtime.coordinator.copyLastTranscription() }
    @objc private func undoLast() { runtime.coordinator.undoLastInsertion() }
    @objc private func openContext() { runtime.context.show() }
    @objc private func openUsageStatistics() { runtime.usage.show() }
    @objc private func toggleEnabled() { runtime.coordinator.toggleEnabled() }
    @objc private func toggleContextWorker() {
        runtime.setContextWorkerEnabled(!runtime.settings.contextWorkerEnabled)
    }
    @objc private func openOnboarding() { runtime.onboarding.show() }
    @objc private func openAbout() { runtime.about.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

@MainActor
private final class ModelMenuItemView: NSView {
    private static let horizontalPadding: CGFloat = 20
    private static let verticalPadding: CGFloat = 5
    private static let lineSpacing: CGFloat = 1

    init(title: String, subtitle: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .disabledControlTextColor

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.textColor = .disabledControlTextColor

        let contentWidth = max(
            titleLabel.intrinsicContentSize.width,
            subtitleLabel.intrinsicContentSize.width
        )
        let contentHeight =
            titleLabel.intrinsicContentSize.height
            + Self.lineSpacing
            + subtitleLabel.intrinsicContentSize.height

        super.init(
            frame: NSRect(
                x: 0,
                y: 0,
                width: contentWidth + (Self.horizontalPadding * 2),
                height: contentHeight + (Self.verticalPadding * 2)
            )
        )

        for label in [titleLabel, subtitleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.horizontalPadding),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalPadding),
            subtitleLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor, constant: Self.lineSpacing),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalPadding),
            subtitleLabel.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
