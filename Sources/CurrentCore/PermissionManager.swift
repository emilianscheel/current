import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

@MainActor
public protocol PermissionManaging: AnyObject {
    func snapshot() -> PermissionSnapshot
    func request(_ kind: PermissionKind) async -> PermissionState
    func openSettings(for kind: PermissionKind)
}

@MainActor
public final class PermissionManager: PermissionManaging {
    public init() {}

    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneState,
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            inputMonitoring: CGPreflightListenEventAccess() ? .granted : .denied
        )
    }

    public func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        try? await Task.sleep(for: .milliseconds(250))
        return snapshot()[kind]
    }

    public func openSettings(for kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        let direct = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        if !NSWorkspace.shared.open(direct),
           let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(fallback)
        }
    }

    private var microphoneState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }
}
