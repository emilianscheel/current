import Foundation
import Observation

@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore()
    private let defaults: UserDefaults

    public var isEnabled: Bool { didSet { save(isEnabled, "isEnabled") } }
    public var holdThresholdMilliseconds: Double { didSet { save(holdThresholdMilliseconds, "holdThresholdMilliseconds") } }
    public var trailingSpace: Bool { didSet { save(trailingSpace, "trailingSpace") } }
    public var restoreClipboard: Bool { didSet { save(restoreClipboard, "restoreClipboard") } }
    public var fallbackShortcut: String { didSet { save(fallbackShortcut, "fallbackShortcut") } }
    public var inputDeviceID: UInt32 { didSet { save(Int(inputDeviceID), "inputDeviceID") } }
    public var showDockIcon: Bool { didSet { save(showDockIcon, "showDockIcon") } }
    public var launchAtLogin: Bool { didSet { save(launchAtLogin, "launchAtLogin") } }
    public var soundsEnabled: Bool { didSet { save(soundsEnabled, "soundsEnabled") } }
    public var overlayEnabled: Bool { didSet { save(overlayEnabled, "overlayEnabled") } }
    public var animationIntensity: Double { didSet { save(animationIntensity, "animationIntensity") } }
    public var minimumRecordingDuration: Double { didSet { save(minimumRecordingDuration, "minimumRecordingDuration") } }
    public var maximumRecordingDuration: Double { didSet { save(maximumRecordingDuration, "maximumRecordingDuration") } }
    public var onboardingComplete: Bool { didSet { save(onboardingComplete, "onboardingComplete") } }
    public var onboardingStep: OnboardingStep {
        didSet { save(onboardingStep.rawValue, "onboardingStep") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "isEnabled": true,
            "holdThresholdMilliseconds": 180.0,
            "trailingSpace": true,
            "restoreClipboard": true,
            "fallbackShortcut": "control-option-space",
            "inputDeviceID": 0,
            "showDockIcon": false,
            "launchAtLogin": false,
            "soundsEnabled": false,
            "overlayEnabled": true,
            "animationIntensity": 0.6,
            "minimumRecordingDuration": 0.25,
            "maximumRecordingDuration": 120.0,
            "onboardingComplete": false,
            "onboardingStep": OnboardingStep.welcome.rawValue,
        ])
        isEnabled = defaults.bool(forKey: "isEnabled")
        holdThresholdMilliseconds = defaults.double(forKey: "holdThresholdMilliseconds")
        trailingSpace = defaults.bool(forKey: "trailingSpace")
        restoreClipboard = defaults.bool(forKey: "restoreClipboard")
        fallbackShortcut = defaults.string(forKey: "fallbackShortcut") ?? "control-option-space"
        inputDeviceID = UInt32(max(0, defaults.integer(forKey: "inputDeviceID")))
        showDockIcon = defaults.bool(forKey: "showDockIcon")
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")
        overlayEnabled = defaults.bool(forKey: "overlayEnabled")
        animationIntensity = defaults.double(forKey: "animationIntensity")
        minimumRecordingDuration = defaults.double(forKey: "minimumRecordingDuration")
        maximumRecordingDuration = defaults.double(forKey: "maximumRecordingDuration")
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        onboardingStep = OnboardingStep(rawValue: defaults.string(forKey: "onboardingStep") ?? "") ?? .welcome
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
