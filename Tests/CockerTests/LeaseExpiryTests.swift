import Foundation
import Testing
@testable import CockerDaemon

/// macOS never removes entries from `/var/db/dhcpd_leases`. On any machine
/// that has run containers for a while, every address in the subnet appears
/// taken — forever — even though nothing is using them.
///
/// That is not a corner case. Measured on the machine this was written on:
/// **317 entries, all 317 expired**, 127 of them inside the range the
/// allocator draws from. Treating the file as a list of live hosts made the
/// allocator refuse every single request, on exactly the machine the whole
/// feature exists to unblock. An expired lease is a dead reservation.
///
/// Unit tests could not have found this — it took running it. What they can
/// do is keep the parser honest, which is what these are for.
@Suite("Lease expiry")
struct LeaseExpiryTests {

    private func leaseFile(_ body: String) throws -> (URL, String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("leases-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("dhcpd_leases").path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return (dir, path)
    }

    /// `lease=` is a Unix timestamp in hex, exactly as bootpd writes it.
    private func entry(ip: String, expiresAt: UInt64) -> String {
        """
        {
        \tip_address=\(ip)
        \thw_address=1,2:cc:1:2:3:4
        \tlease=0x\(String(expiresAt, radix: 16))
        }
        """
    }

    @Test func anExpiredLeaseIsNotInUse() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (dir, path) = try leaseFile(entry(ip: "192.168.64.50", expiresAt: 1_700_000_000))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LeasePoolMonitor.activeLeasedIPs(leasesAt: path, now: now).isEmpty)
    }

    @Test func anUnexpiredLeaseIsInUse() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (dir, path) = try leaseFile(entry(ip: "192.168.64.50", expiresAt: 1_900_000_000))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LeasePoolMonitor.activeLeasedIPs(leasesAt: path, now: now)
                == ["192.168.64.50"])
    }

    @Test func aFileOfMixedEntriesKeepsOnlyTheLiveOnes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = [
            entry(ip: "192.168.64.10", expiresAt: 1_700_000_000),  // dead
            entry(ip: "192.168.64.11", expiresAt: 1_900_000_000),  // live
            entry(ip: "192.168.64.12", expiresAt: 1_799_999_999),  // dead by 1 s
            entry(ip: "192.168.64.13", expiresAt: 1_800_000_001),  // live by 1 s
        ].joined(separator: "\n")
        let (dir, path) = try leaseFile(body)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LeasePoolMonitor.activeLeasedIPs(leasesAt: path, now: now)
                == ["192.168.64.11", "192.168.64.13"])
    }

    /// An entry with no `lease=` field tells us nothing about whether it is
    /// live, so it counts as live. Skipping an address we could have used
    /// costs one address; handing out one somebody holds costs a debugging
    /// session.
    @Test func anEntryWithoutAnExpiryCountsAsLive() throws {
        let (dir, path) = try leaseFile("""
        {
        \tip_address=192.168.64.77
        \thw_address=1,2:cc:1:2:3:4
        }
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LeasePoolMonitor.activeLeasedIPs(leasesAt: path,
                                                 now: Date(timeIntervalSince1970: 1_800_000_000))
                == ["192.168.64.77"])
    }

    /// A truncated file — bootpd rewrites this thing under us — must still
    /// yield what it can rather than dropping the last entry.
    @Test func afinalEntryWithNoClosingBraceIsStillRead() throws {
        let (dir, path) = try leaseFile("""
        {
        \tip_address=192.168.64.88
        \tlease=0x\(String(UInt64(1_900_000_000), radix: 16))
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LeasePoolMonitor.activeLeasedIPs(leasesAt: path,
                                                 now: Date(timeIntervalSince1970: 1_800_000_000))
                == ["192.168.64.88"])
    }

    @Test func amissingFileYieldsNothing() {
        #expect(LeasePoolMonitor.activeLeasedIPs(leasesAt: "/nonexistent/leases").isEmpty)
    }

    /// The shape that actually shipped: a long file where every entry is
    /// stale. Every address must come back free, or the allocator refuses
    /// on the machines that need it most.
    @Test func afileOfEntirelyStaleEntriesFreesTheWholeRange() throws {
        let body = (128...254)
            .map { entry(ip: "192.168.64.\($0)", expiresAt: 1_700_000_000) }
            .joined(separator: "\n")
        let (dir, path) = try leaseFile(body)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LeasePoolMonitor.activeLeasedIPs(leasesAt: path,
                                                 now: Date(timeIntervalSince1970: 1_800_000_000))
                .isEmpty)
    }
}
