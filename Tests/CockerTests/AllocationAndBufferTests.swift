import Foundation
import Testing
import CockerCore
@testable import CockerDaemon

/// A build VM's console feeds straight into `OutputBuffer` for the whole
/// build, and `append` had no cap: one chatty `RUN` — npm, pip or apt with
/// progress bars, or an accidental `yes` — grew cockerd's resident memory
/// without limit.
@Suite("Build output buffer")
struct OutputBufferTests {

    @Test func keepsSmallOutputVerbatim() {
        let buffer = OutputBuffer()
        buffer.append(Data("hello world\n".utf8))
        #expect(buffer.text() == "hello world\n")
    }

    @Test func accumulatesAcrossAppends() {
        let buffer = OutputBuffer()
        buffer.append(Data("one\n".utf8))
        buffer.append(Data("two\n".utf8))
        #expect(buffer.text() == "one\ntwo\n")
    }

    /// What matters on a failure is the tail — the command that broke and its
    /// error — so that is what survives.
    @Test func boundsItselfAndKeepsTheTail() {
        let buffer = OutputBuffer()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 1 << 20)  // 1 MiB
        for _ in 0..<8 { buffer.append(chunk) }                        // 8 MiB in
        buffer.append(Data("THE-END\n".utf8))

        let text = buffer.text()
        #expect(text.hasSuffix("THE-END\n"), "the tail must survive")
        // Comfortably bounded, with room for the dropped-bytes notice.
        #expect(text.utf8.count < OutputBuffer.capacity + 4096)
    }

    /// Truncating silently would present a partial log as if it were whole.
    @Test func saysWhenItDropped() {
        let buffer = OutputBuffer()
        buffer.append(Data(repeating: UInt8(ascii: "y"), count: OutputBuffer.capacity + 4096))
        #expect(buffer.text().contains("dropped"))
    }

    @Test func staysSilentWhenNothingWasDropped() {
        let buffer = OutputBuffer()
        buffer.append(Data("short\n".utf8))
        #expect(!buffer.text().contains("dropped"))
    }
}

/// Both allocators handed out addresses that were wrong in ways nothing
/// downstream corrected.
@Suite("IP allocation")
struct IPAllocationTests {

    private func manager() async throws -> NetworkManager {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-ipalloc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try await NetworkManager(store: try StateStore(rootDir: root))
    }

    @Test func ipv4IsStablePerContainer() async throws {
        let net = try await manager()
        let first = await net.allocateIP(for: "abc")
        let again = await net.allocateIP(for: "abc")
        #expect(first == again)
    }

    /// `2 + allocatedIPs.count` handed out duplicates the moment anything was
    /// released: three containers take .2 .3 .4, stop the middle one, and the
    /// next newcomer is handed .4 — already in use.
    @Test func ipv4IsNotReusedAfterARelease() async throws {
        let net = try await manager()
        let a = await net.allocateIP(for: "a")
        let b = await net.allocateIP(for: "b")
        let c = await net.allocateIP(for: "c")
        #expect(Set([a, b, c]).count == 3)

        await net.releaseIP(for: "b")
        let d = await net.allocateIP(for: "d")
        #expect(d != a && d != c, "reused a live address: \(d)")
        // `b`'s address is free again, so the lowest gap is the right answer.
        #expect(d == b)
    }

    @Test func ipv4AddressesAreDistinctAcrossManyContainers() async throws {
        let net = try await manager()
        var seen: Set<String> = []
        for i in 0..<50 { seen.insert(await net.allocateIP(for: "c\(i)")) }
        #expect(seen.count == 50)
    }

    /// `hashValue` is seeded per process, so a container's IPv6 changed on
    /// every daemon restart while `container.ipv6` in state.json kept the old
    /// value — and unlike `ip`, nothing later corrects it.
    /// Pinned to an exact address, computed independently from the FNV-1a
    /// definition. Two managers in one process would agree even with the old
    /// `hashValue` (same seed), so only a fixed expected value actually
    /// catches a regression to a per-process hash.
    @Test func ipv6IsDerivedFromAStableHash() async throws {
        let net = try await manager()
        #expect(await net.allocateIPv6(for: "container-xyz") == "fd00:c0c4::2fda")
    }

    @Test func ipv6AgreesAcrossManagers() async throws {
        let first = try await manager()
        let second = try await manager()
        let a = await first.allocateIPv6(for: "container-xyz")
        let b = await second.allocateIPv6(for: "container-xyz")
        #expect(a == b)
    }

    @Test func ipv6IsDistinctPerContainer() async throws {
        let net = try await manager()
        var seen: Set<String> = []
        for i in 0..<50 { seen.insert(await net.allocateIPv6(for: "c\(i)")) }
        #expect(seen.count == 50, "collided: \(seen.count)/50 unique")
    }

    @Test func ipv6IsStablePerContainer() async throws {
        let net = try await manager()
        #expect(await net.allocateIPv6(for: "abc") == (await net.allocateIPv6(for: "abc")))
    }
}
