import Foundation
import CockerCore

/// **A1 — extracted from ContainerEngine** (was ~100 lines of lease-pool
/// helpers entangled with the container lifecycle).
///
/// macOS's vmnet bootpd refuses to hand out new DHCP leases once
/// `/var/db/dhcpd_leases` reaches ~256 entries. Under churn (CI runs, dev
/// test suites spawning hundreds of containers) we saturate that pool in
/// minutes and every subsequent `cocker run` either gets stuck on DHCP
/// or comes up with port-forwarding pointing at the fallback `127.0.0.1`.
///
/// This module owns the four observability + admission-control checks
/// cockerd performs around the lease pool :
///
///   * `count()` — quick parse of how many leases are currently in the
///     file.
///   * `helperInstalled()` — does the LaunchDaemon trigger plist exist ?
///     If yes, the daemon can touch a file to ask root to truncate the
///     pool.
///   * `maybeTriggerClear()` — proactive nudge of the helper when the
///     pool is approaching saturation. Cheap to call from the run path.
///   * `preflightOrThrow()` — hard gate at the edge of saturation. Refuses
///     `cocker run` with an actionable error message when the user has no
///     helper installed AND the pool is full.
///
/// Pure, stateless, deliberately easy to unit-test : no actor isolation,
/// no I/O beyond the lease file + the trigger file.
public enum LeasePoolMonitor {
    /// Path of the bootp lease file vmnet uses for the shared NAT network.
    public static let leasesPath = "/var/db/dhcpd_leases"
    /// LaunchDaemon plist that the install-helper drops. Its presence
    /// means "the daemon can ask for an asynchronous truncation".
    public static let helperPlistPath =
        "/Library/LaunchDaemons/com.cocker.leases-helper.plist"
    /// Touching this file is the IPC contract with the helper.
    public static let triggerPath = "/var/run/cocker-clear-leases"
    /// Approximate vmnet ceiling. Apple doesn't expose it directly ; this
    /// is the value at which our own tests reliably start losing leases.
    public static let approximateCeiling = 256
    /// Soft threshold — we start nudging the helper at this point.
    public static let softWatermark = 200
    /// Hard threshold — past here, `preflightOrThrow` refuses new runs
    /// when no helper is installed. Leaves a 4-lease cushion for whatever
    /// else macOS hands out while we're checking.
    public static let hardThreshold = 252

    public static func count() -> Int {
        guard let s = try? String(contentsOfFile: leasesPath, encoding: .utf8)
        else { return 0 }
        return s.components(separatedBy: "ip_address=").count - 1
    }

    public static func helperInstalled() -> Bool {
        FileManager.default.fileExists(atPath: helperPlistPath)
    }

    /// Proactive nudge — touch the trigger file when the pool is past
    /// `softWatermark`. Only meaningful if the helper is installed ;
    /// otherwise we no-op (the watchdog in main.swift surfaces the
    /// situation to the user with a high-priority log line).
    public static func maybeTriggerClear() {
        let c = count()
        guard c > softWatermark else { return }
        guard helperInstalled() else { return }
        let trigger = URL(fileURLWithPath: triggerPath)
        guard !FileManager.default.fileExists(atPath: trigger.path) else { return }
        _ = try? Data().write(to: trigger)
        fputs("[lease-gc] pool at \(c) — touched helper trigger\n", stderr); fflush(stderr)
    }

    /// Hard pre-flight gate. Called from `ContainerEngine.run()` before any
    /// VM resource is allocated. Refusing early with the exact fix command
    /// in the message turns a 30-min debugging session into a 10 s helper
    /// install.
    public static func preflightOrThrow() throws {
        let c = count()
        guard c >= hardThreshold else { return }
        // Helper present : the watchdog / runPreflight path will touch the
        // trigger and clear it in <2 s. Don't block.
        if helperInstalled() { return }
        throw CockerError.internalError(
            "macOS DHCP pool saturated (\(c)/\(approximateCeiling)). " +
            "New containers can't get an IP. " +
            "Fix once and forever : `cocker daemon helper-install` " +
            "(one sudo prompt, then forget). " +
            "Or one-shot : `cocker daemon clear-leases`."
        )
    }

    /// Look up `mac` in macOS's vmnet bootp lease file. Returns the most
    /// recent IPv4 address handed out to that MAC, or nil if no entry
    /// matches. Used as a fallback when `/cocker-ip` polling times out
    /// because udhcpc inside the container raced and lost.
    public static func lookupLeasedIP(forMAC mac: String) -> String? {
        guard let text = try? String(contentsOfFile: leasesPath, encoding: .utf8)
        else { return nil }
        // Normalize MACs : drop leading zeros per octet so "02:cc:01:02:03:04"
        // matches "2:cc:1:2:3:4" (vmnet writes the short form).
        func normalize(_ s: String) -> String {
            s.split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }
             .joined(separator: ":")
        }
        let target = normalize(mac).lowercased()
        var currentIP: String? = nil
        var matchedIP: String? = nil
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ip_address=") {
                currentIP = String(trimmed.dropFirst("ip_address=".count))
            } else if trimmed.hasPrefix("hw_address=") {
                let val = trimmed.dropFirst("hw_address=".count)
                let macPart = val.split(separator: ",").last.map(String.init) ?? String(val)
                if normalize(macPart).lowercased() == target {
                    matchedIP = currentIP
                    // Don't break — last entry wins (newest lease).
                }
            }
        }
        return matchedIP
    }

    /// Derive a stable, locally-administered MAC from a container ID.
    /// The `02:cc:` prefix marks the address as locally-administered so
    /// vmnet treats it as unicast and the host stack doesn't dedupe it
    /// against any global allocation.
    public static func deriveNATMAC(from containerID: String) -> String {
        var hex = containerID.filter { $0.isHexDigit }
        while hex.count < 8 { hex += "0" }
        let bytes = Array(hex.prefix(8))
        return "02:cc:" + stride(from: 0, to: 8, by: 2).map { i in
            String(bytes[i...i+1])
        }.joined(separator: ":")
    }
}
