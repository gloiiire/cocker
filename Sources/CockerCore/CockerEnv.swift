import Foundation

/// **I10** : every part of cocker reads `ProcessInfo.processInfo.environment[…]`
/// with string-literal keys, which is exactly how an "AWS_REGEION" typo
/// (mismatched spelling) creeps in and a configured env var silently turns
/// into the default. This enum centralizes the keys cocker honours so the
/// compiler tells us when a name changes.
public enum CockerEnv: String, CaseIterable {
    case cockerHost          = "COCKER_HOST"
    case dockerHost          = "DOCKER_HOST"
    case logLevel            = "COCKER_LOG_LEVEL"
    case logFormat           = "COCKER_LOG_FORMAT"
    case dnsPort             = "COCKER_DNS_PORT"
    case gcDays              = "COCKER_GC_DAYS"
    case tcpTLSPort          = "COCKER_TCP_TLS_PORT"
    case redactInspect       = "COCKER_REDACT_INSPECT"

    /// Look up the variable in the current process environment.
    public var stringValue: String? {
        ProcessInfo.processInfo.environment[rawValue]
    }

    /// Convenience for boolean env vars (`"1"`, `"true"`, `"yes"` → true).
    public var boolValue: Bool {
        switch (stringValue ?? "").lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    /// Convenience for integer env vars. Returns nil on missing / non-numeric.
    public var intValue: Int? {
        stringValue.flatMap(Int.init)
    }
}
