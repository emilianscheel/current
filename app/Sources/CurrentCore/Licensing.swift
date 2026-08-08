import CryptoKit
import Foundation
import Observation
import Security

public enum LicenseKeyFormat {
    public static func normalize(_ value: String) -> String? {
        let compact = value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard compact.count == 9 else { return nil }
        let groups = stride(from: 0, to: 9, by: 3).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 3)
            return String(compact[start..<end])
        }
        return groups.joined(separator: "-")
    }
}

public enum LicenseEntitlementState: Equatable, Sendable {
    case needsTrialConsent
    case trial(daysRemaining: Int)
    case trialExpired
    case licensed(key: String)
    case revoked

    public var isAuthorized: Bool {
        switch self {
        case .trial, .licensed: true
        default: false
        }
    }
}

public enum TrialPolicy {
    public static let duration: TimeInterval = 7 * 24 * 60 * 60

    public static func state(
        trialStart: Date?,
        licenseKey: String?,
        now: Date,
        lastSeen: Date?
    ) -> LicenseEntitlementState {
        if let licenseKey, let normalized = LicenseKeyFormat.normalize(licenseKey) {
            return .licensed(key: normalized)
        }
        guard let trialStart else { return .needsTrialConsent }
        let effectiveNow = max(now, lastSeen ?? now)
        let remaining = duration - effectiveNow.timeIntervalSince(trialStart)
        guard remaining > 0 else { return .trialExpired }
        return .trial(daysRemaining: max(1, Int(ceil(remaining / 86_400))))
    }
}

@MainActor
public protocol LicenseSecureStoring: AnyObject {
    func string(for key: String) -> String?
    func date(for key: String) -> Date?
    func set(_ value: String, for key: String)
    func set(_ value: Date, for key: String)
    func remove(_ key: String)
}

@MainActor
public final class KeychainLicenseStorage: LicenseSecureStoring {
    private let service: String

    public init(service: String = "com.emilianscheel.current.licensing") {
        self.service = service
    }

    public func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func date(for key: String) -> Date? {
        guard let raw = string(for: key), let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func set(_ value: String, for key: String) {
        setData(Data(value.utf8), for: key)
    }

    public func set(_ value: Date, for key: String) {
        set(String(value.timeIntervalSince1970), for: key)
    }

    public func remove(_ key: String) {
        SecItemDelete(query(for: key) as CFDictionary)
    }

    private func data(for key: String) -> Data? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func setData(_ data: Data, for key: String) {
        let query = query(for: key)
        let changed = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if changed == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }
}

public struct LicenseServerResponse: Codable, Sendable {
    public let ok: Bool
    public let code: String?
    public let licenseKey: String?

    public init(ok: Bool, code: String? = nil, licenseKey: String? = nil) {
        self.ok = ok
        self.code = code
        self.licenseKey = licenseKey
    }
}

public protocol LicenseAPIProviding: Sendable {
    func request(action: String, key: String, installationHash: String) async throws
        -> LicenseServerResponse
}

public struct URLLicenseAPIClient: LicenseAPIProviding {
    public let baseURL: URL

    public init(baseURL: URL = URL(string: "https://current-mac.vercel.app")!) {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["CURRENT_LICENSE_API_BASE_URL"],
           let url = URL(string: override) {
            self.baseURL = url
            return
        }
        #endif
        self.baseURL = baseURL
    }

    public func request(action: String, key: String, installationHash: String) async throws
        -> LicenseServerResponse {
        let url = baseURL.appending(path: "api/licenses/\(action)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "licenseKey": key,
            "installationId": installationHash,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(LicenseServerResponse.self, from: data)
    }
}

@MainActor
@Observable
public final class LicenseManager {
    public private(set) var state: LicenseEntitlementState = .needsTrialConsent
    public private(set) var isWorking = false
    public private(set) var message: String?

    private let storage: any LicenseSecureStoring
    private let api: any LicenseAPIProviding
    private let now: @MainActor () -> Date
    private let trialStartKey = "trial-start"
    private let lastSeenKey = "last-seen"
    private let licenseKey = "license-key"
    private let installationKey = "installation-id"
    private let revokedKey = "license-revoked"

    public init(
        storage: any LicenseSecureStoring = KeychainLicenseStorage(),
        api: any LicenseAPIProviding = URLLicenseAPIClient(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.storage = storage
        self.api = api
        self.now = now
        refreshLocalState()
    }

    public var isAuthorized: Bool { state.isAuthorized }
    public var requiresTrialConsent: Bool { state == .needsTrialConsent }
    public var currentLicenseKey: String? {
        if case .licensed(let key) = state { return key }
        return nil
    }
    public var statusTitle: String {
        switch state {
        case .needsTrialConsent: "Trial not started"
        case .trial(let days): "Trial · \(days) day\(days == 1 ? "" : "s") left"
        case .trialExpired: "Trial expired"
        case .licensed: "Lifetime license active"
        case .revoked: "License revoked"
        }
    }

    public func startTrial() {
        guard storage.string(for: revokedKey) != "true" else {
            state = .revoked
            return
        }
        guard storage.date(for: trialStartKey) == nil else { refreshLocalState(); return }
        let date = now()
        storage.set(date, for: trialStartKey)
        storage.set(date, for: lastSeenKey)
        refreshLocalState()
    }

    public func refreshLocalState() {
        if storage.string(for: revokedKey) == "true" {
            state = .revoked
            return
        }
        let date = now()
        let lastSeen = storage.date(for: lastSeenKey)
        if lastSeen == nil || date > lastSeen! { storage.set(date, for: lastSeenKey) }
        state = TrialPolicy.state(
            trialStart: storage.date(for: trialStartKey),
            licenseKey: storage.string(for: licenseKey),
            now: date,
            lastSeen: lastSeen
        )
    }

    public func redeem(_ rawKey: String) async {
        guard let key = LicenseKeyFormat.normalize(rawKey) else {
            message = "Enter a key like ABC-123-XYZ."
            return
        }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let response = try await api.request(
                action: "activate",
                key: key,
                installationHash: installationHash()
            )
            guard response.ok else {
                message = response.code == "limit_reached"
                    ? "This key is already active on three Macs."
                    : "That license key is not active."
                return
            }
            storage.set(key, for: licenseKey)
            storage.remove(revokedKey)
            state = .licensed(key: key)
            message = "License redeemed. Current is unlocked."
        } catch {
            message = "Current could not reach the license server. Try again when online."
        }
    }

    public func validateIfPossible() async {
        guard let key = storage.string(for: licenseKey).flatMap(LicenseKeyFormat.normalize) else {
            refreshLocalState()
            return
        }
        do {
            let response = try await api.request(
                action: "validate",
                key: key,
                installationHash: installationHash()
            )
            if response.ok {
                state = .licensed(key: key)
            } else {
                storage.remove(licenseKey)
                storage.set("true", for: revokedKey)
                state = .revoked
            }
        } catch {
            state = .licensed(key: key)
        }
    }

    public func deactivate() async {
        guard let key = currentLicenseKey else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let response = try await api.request(
                action: "deactivate",
                key: key,
                installationHash: installationHash()
            )
            guard response.ok else { message = "This Mac could not be deactivated."; return }
            storage.remove(licenseKey)
            refreshLocalState()
            message = "This Mac has been deactivated."
        } catch {
            message = "Current could not reach the license server."
        }
    }

    private func installationHash() -> String {
        let identifier: String
        if let saved = storage.string(for: installationKey) {
            identifier = saved
        } else {
            identifier = UUID().uuidString
            storage.set(identifier, for: installationKey)
        }
        return SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
