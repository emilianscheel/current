import Foundation

/// Internal launch-time switches used to attribute latency and quality changes
/// independently. A feature is enabled unless its `CURRENT_DISABLE_*` variable
/// is set to `1` or `true`.
public enum ContextEngineeringFeatureFlags {
    public static let conversationLedger = enabled("CURRENT_DISABLE_CONVERSATION_LEDGER")
    public static let localRetrieval = enabled("CURRENT_DISABLE_LOCAL_RETRIEVAL")
    public static let recordingTimeCapture = enabled("CURRENT_DISABLE_RECORDING_CAPTURE")
    public static let providerSessionReuse = enabled("CURRENT_DISABLE_SESSION_REUSE")
    public static let backendCircuitBreaker = enabled("CURRENT_DISABLE_CIRCUIT_BREAKER")

    private static func enabled(_ variable: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[variable]?.lowercased() else {
            return true
        }
        return value != "1" && value != "true" && value != "yes"
    }
}
