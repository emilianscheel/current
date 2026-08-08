import Foundation
import Testing
@testable import CurrentCore

@MainActor
private final class MemoryLicenseStorage: LicenseSecureStoring {
    var strings: [String: String] = [:]
    func string(for key: String) -> String? { strings[key] }
    func date(for key: String) -> Date? {
        strings[key].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }
    func set(_ value: String, for key: String) { strings[key] = value }
    func set(_ value: Date, for key: String) { strings[key] = String(value.timeIntervalSince1970) }
    func remove(_ key: String) { strings[key] = nil }
}

private struct StubLicenseAPI: LicenseAPIProviding {
    let response: LicenseServerResponse?
    func request(action: String, key: String, installationHash: String) async throws
        -> LicenseServerResponse {
        guard let response else { throw URLError(.notConnectedToInternet) }
        return response
    }
}

@Test func licenseKeyFormattingIsStrictAndFriendly() {
    #expect(LicenseKeyFormat.normalize("abc123xyz") == "ABC-123-XYZ")
    #expect(LicenseKeyFormat.normalize("ABC-123-XYZ") == "ABC-123-XYZ")
    #expect(LicenseKeyFormat.normalize("ABC-12-XYZ") == nil)
    #expect(LicenseKeyFormat.normalize("ABC-123-XY!") == nil)
}

@Test func trialPolicyUsesLastSeenTimeToResistClockRollback() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let sixDaysLater = start.addingTimeInterval(6 * 86_400)
    #expect(TrialPolicy.state(
        trialStart: start,
        licenseKey: nil,
        now: start.addingTimeInterval(60),
        lastSeen: sixDaysLater
    ) == .trial(daysRemaining: 1))
    #expect(TrialPolicy.state(
        trialStart: start,
        licenseKey: nil,
        now: start,
        lastSeen: start.addingTimeInterval(8 * 86_400)
    ) == .trialExpired)
}

@MainActor
@Test func licenseManagerStartsTrialAndKeepsPaidLicenseOffline() async {
    let storage = MemoryLicenseStorage()
    let instant = Date(timeIntervalSince1970: 2_000_000)
    let manager = LicenseManager(
        storage: storage,
        api: StubLicenseAPI(response: .init(ok: true, licenseKey: "ABC-123-XYZ")),
        now: { instant }
    )
    #expect(manager.state == .needsTrialConsent)
    manager.startTrial()
    #expect(manager.state == .trial(daysRemaining: 7))
    await manager.redeem("abc123xyz")
    #expect(manager.state == .licensed(key: "ABC-123-XYZ"))

    let offline = LicenseManager(
        storage: storage,
        api: StubLicenseAPI(response: nil),
        now: { instant.addingTimeInterval(9 * 86_400) }
    )
    await offline.validateIfPossible()
    #expect(offline.state == .licensed(key: "ABC-123-XYZ"))
}

@MainActor
@Test func confirmedRevocationCannotFallBackToTrial() async {
    let storage = MemoryLicenseStorage()
    let instant = Date(timeIntervalSince1970: 3_000_000)
    storage.set(instant, for: "trial-start")
    storage.set("ABC-123-XYZ", for: "license-key")
    let manager = LicenseManager(
        storage: storage,
        api: StubLicenseAPI(response: .init(ok: false, code: "invalid")),
        now: { instant }
    )
    await manager.validateIfPossible()
    #expect(manager.state == .revoked)
    manager.refreshLocalState()
    #expect(manager.state == .revoked)
}

@MainActor
@Test func dictationEntryIsBlockedWhenAuthorizationExpires() {
    let suiteName = "CurrentCoreTests.Licensing.DictationGate.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let coordinator = DictationCoordinator(settings: SettingsStore(defaults: defaults))
    var presentedLicensing = false
    coordinator.isAuthorized = { false }
    coordinator.onAuthorizationRequired = { presentedLicensing = true }

    coordinator.beginFromMenu()

    #expect(presentedLicensing)
    #expect(coordinator.currentSession == nil)
}
