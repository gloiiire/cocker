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
    case staticETH0          = "COCKER_STATIC_ETH0"

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

    /// Boolean lookup for opt-*out* switches, where "unset" must mean `true`.
    ///
    /// `boolValue` can't serve these: it maps everything it doesn't recognise
    /// to `false`, so a feature that ships on by default would silently turn
    /// itself off the moment nobody set the variable. An unrecognised value
    /// also falls back to `defaultValue` rather than to `false` — a typo like
    /// `COCKER_STATIC_ETH0=fasle` leaves the documented default in place
    /// instead of quietly flipping behaviour.
    public func boolValue(default defaultValue: Bool) -> Bool {
        switch stringValue?.lowercased() {
        case "1", "true", "yes", "on":   return true
        case "0", "false", "no", "off":  return false
        default:                         return defaultValue
        }
    }

    /// True when containers configure `eth0` themselves instead of asking
    /// vmnet's bootpd for a lease. **On by default since 1.1.0.0.**
    ///
    /// This lives here rather than next to the engine because both the daemon
    /// (which must not monitor a pool nothing draws from) and the CLI (which
    /// must not report that pool as a capacity gauge) need the same answer.
    /// It previously existed only as a string literal inside the daemon, so
    /// `cocker daemon status` had no way to ask — and went on advertising a
    /// lease counter and a helper that had stopped meaning anything.
    ///
    /// Set `COCKER_STATIC_ETH0=0` to go back to DHCP; that path is intact.
    public static var staticETH0Enabled: Bool {
        staticETH0.boolValue(default: true)
    }
}
