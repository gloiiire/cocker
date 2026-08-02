import Foundation
import Testing
@testable import CockerDaemon

/// macOS's vmnet bootpd stops handing out DHCP leases at roughly 256
/// entries, so cocker ships a root LaunchDaemon that truncates the pool
/// when asked. The gate around it decided whether to refuse a `cocker run`
/// by asking *"is the helper installed?"* — meaning *"does a plist file
/// exist?"*
///
/// On a machine where the plist had been installed in June and `launchctl`
/// had never loaded it, that read as "installed" forever. Nothing consumed
/// the trigger file, and `/var/run` is `root:daemon` while `cockerd` runs
/// as the user, so the request could not even be written. Both the nudge
/// and the warning were suppressed by the same `if`, and the pool walked
/// to 317 against a ceiling of 256 while the daemon logged nothing at all.
/// Containers then failed DHCP in silence — the exact outcome the gate
/// exists to prevent, caused by the gate.
///
/// The predicate is now "did the helper accept the request?", which is
/// observable. These tests pin that distinction.
@Suite("Lease pool — helper reachability")
struct LeasePoolMonitorTests {

    /// A lease file with `n` entries, plus an optional helper plist and an
    /// optional read-only directory to hold the trigger.
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeLeases(_ n: Int, in dir: URL) throws -> String {
        let body = (0..<n).map { "{\n\tip_address=192.168.64.\($0 % 250 + 2)\n}" }
            .joined(separator: "\n")
        let path = dir.appendingPathComponent("dhcpd_leases").path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - count

    @Test func countsOneEntryPerLease() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let leases = try writeLeases(7, in: dir)
        #expect(LeasePoolMonitor.count(leasesAt: leases) == 7)
    }

    @Test func missingLeaseFileCountsAsEmpty() {
        #expect(LeasePoolMonitor.count(leasesAt: "/nonexistent/dhcpd_leases") == 0)
    }

    // MARK: - requestClear

    /// No helper at all : nothing to ask, so the request cannot be
    /// delivered. This one was already right.
    @Test func requestIsNotDeliveredWithoutAHelper() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LeasePoolMonitor.requestClear(
            triggerAt: dir.appendingPathComponent("trigger").path,
            plistPath: dir.appendingPathComponent("absent.plist").path) == false)
    }

    @Test func requestIsDeliveredWhenTheTriggerIsWritable() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("helper.plist")
        try Data().write(to: plist)
        let trigger = dir.appendingPathComponent("trigger").path

        #expect(LeasePoolMonitor.requestClear(triggerAt: trigger, plistPath: plist.path))
        #expect(FileManager.default.fileExists(atPath: trigger))
    }

    /// **The regression.** The plist exists, so the old code declared the
    /// helper present and stood down — but the trigger cannot be written,
    /// so nobody was ever asked.
    @Test func installedButUnreachableHelperIsNotDelivered() throws {
        let dir = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let plist = dir.appendingPathComponent("helper.plist")
        try Data().write(to: plist)

        // Stand in for /var/run being root-owned while cockerd is not.
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: locked.path)

        #expect(LeasePoolMonitor.requestClear(
            triggerAt: locked.appendingPathComponent("trigger").path,
            plistPath: plist.path) == false)
    }

    /// A trigger nobody consumes lingers forever. Treating "the file is
    /// already there" as "a clear is pending" is how a dead helper passes
    /// for a live one, so the write is attempted every time.
    @Test func anExistingTriggerDoesNotShortCircuitTheCheck() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("helper.plist")
        try Data().write(to: plist)
        let trigger = dir.appendingPathComponent("trigger")
        try Data().write(to: trigger)

        #expect(LeasePoolMonitor.requestClear(triggerAt: trigger.path, plistPath: plist.path))
    }

    // MARK: - preflightOrThrow

    @Test func plentyOfHeadroomDoesNotBlock() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let leases = try writeLeases(10, in: dir)
        try LeasePoolMonitor.preflightOrThrow(
            leasesAt: leases,
            triggerAt: dir.appendingPathComponent("trigger").path,
            plistPath: dir.appendingPathComponent("absent.plist").path)
    }

    @Test func saturatedPoolWithNoHelperRefusesWithTheFixCommand() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let leases = try writeLeases(LeasePoolMonitor.hardThreshold + 3, in: dir)

        var message = ""
        #expect(throws: (any Error).self) {
            do {
                try LeasePoolMonitor.preflightOrThrow(
                    leasesAt: leases,
                    triggerAt: dir.appendingPathComponent("trigger").path,
                    plistPath: dir.appendingPathComponent("absent.plist").path)
            } catch {
                message = "\(error)"
                throw error
            }
        }
        #expect(message.contains("helper-install"))
    }

    /// The one that used to pass silently: saturated, plist present,
    /// helper unreachable. The run must be refused, and the message must
    /// say the helper is the problem rather than telling the user to
    /// install something they already installed.
    @Test func saturatedPoolWithAnUnreachableHelperStillRefuses() throws {
        let dir = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let leases = try writeLeases(LeasePoolMonitor.hardThreshold + 3, in: dir)
        let plist = dir.appendingPathComponent("helper.plist")
        try Data().write(to: plist)
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: locked.path)

        var message = ""
        #expect(throws: (any Error).self) {
            do {
                try LeasePoolMonitor.preflightOrThrow(
                    leasesAt: leases,
                    triggerAt: locked.appendingPathComponent("trigger").path,
                    plistPath: plist.path)
            } catch {
                message = "\(error)"
                throw error
            }
        }
        #expect(message.contains("did not accept"),
                "the message must name the real problem, got: \(message)")
        #expect(message.contains("clear-leases"))
    }

    /// A reachable helper clears the pool in under two seconds, so a
    /// saturated pool must NOT block when the request lands.
    @Test func saturatedPoolWithAReachableHelperDoesNotBlock() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let leases = try writeLeases(LeasePoolMonitor.hardThreshold + 3, in: dir)
        let plist = dir.appendingPathComponent("helper.plist")
        try Data().write(to: plist)

        try LeasePoolMonitor.preflightOrThrow(
            leasesAt: leases,
            triggerAt: dir.appendingPathComponent("trigger").path,
            plistPath: plist.path)
    }
}
