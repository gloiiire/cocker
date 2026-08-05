import Foundation
import Testing
@testable import CockerCore
@testable import CockerDaemon

/// macOS's vmnet lease pool is host-wide, capped at ~256 entries, never
/// reclaimed and `root:wheel` — so a machine that has started 256 containers
/// stops working until somebody with root truncates a file. A container that
/// configures `eth0` itself never asks for a lease and the ceiling stops
/// existing.
///
/// Verified on hardware 2026-08-05 against a pool already saturated at
/// 317/256: the container booted, reached the internet over IPv4 and DNS,
/// answered on a published port, and the lease count did not move.
///
/// See `docs/DESIGN-network-without-vmnet.md`.
@Suite("Static eth0 address")
struct StaticNATAddressTests {

    // MARK: - Deriving the address

    /// The address must survive a daemon restart, which rules out
    /// `hashValue` — Swift seeds it per process, so the same container would
    /// land somewhere else every time cockerd came back. That exact mistake
    /// already shipped here once, in IPv6 allocation.
    ///
    /// Calling the function twice would **not** catch it: `hashValue` is
    /// perfectly stable *within* one process, which is all a single test run
    /// ever sees. So this pins the algorithm to a value computed
    /// independently from the documented FNV-1a definition. Swapping in a
    /// per-process hash fails this immediately.
    @Test func addressIsPinnedToAStableHash() {
        #expect(VMRuntime.staticNATIP(containerID: "abc123def456",
                                      gateway: "192.168.64.1") == "192.168.64.237")
        #expect(VMRuntime.staticNATIP(containerID: "spike",
                                      gateway: "10.0.0.1") == "10.0.0.244")
    }

    @Test func differentContainersGetDifferentAddresses() {
        // Not a guarantee for every pair — the range is 65 wide — but these
        // two must not collide, and a broken derivation (e.g. always the
        // same octet) fails here immediately.
        let ids = (0..<40).map { "container\($0)" }
        let addrs = Set(ids.compactMap {
            VMRuntime.staticNATIP(containerID: $0, gateway: "192.168.64.1")
        })
        #expect(addrs.count > 20, "derivation looks degenerate: \(addrs.count) distinct for 40 ids")
    }

    /// It has to land in the /24 vmnet actually chose on this host, which is
    /// not always 192.168.64.
    @Test func addressSitsInTheGatewaySubnet() {
        let ip = VMRuntime.staticNATIP(containerID: "x", gateway: "192.168.105.1")
        #expect(ip?.hasPrefix("192.168.105.") == true, "got \(ip ?? "nil")")
    }

    /// `.180`–`.244`: bootpd allocates from the low end, so staying high
    /// keeps a self-assigned address clear of leases handed to anything else
    /// on the host, and clear of the gateway itself.
    @Test func addressStaysInTheHighRange() {
        for i in 0..<200 {
            guard let ip = VMRuntime.staticNATIP(containerID: "id-\(i)", gateway: "10.0.0.1"),
                  let last = ip.split(separator: ".").last.flatMap({ Int($0) })
            else {
                Issue.record("no address for id-\(i)")
                return
            }
            #expect(last >= 180 && last <= 244, "\(ip) is outside .180–.244")
        }
    }

    @Test func aMalformedGatewayYieldsNoAddress() {
        #expect(VMRuntime.staticNATIP(containerID: "x", gateway: "not-an-ip") == nil)
        #expect(VMRuntime.staticNATIP(containerID: "x", gateway: "192.168.64") == nil)
        #expect(VMRuntime.staticNATIP(containerID: "x", gateway: "192.168.64.999") == nil)
    }

    // MARK: - Reaching the guest

    private func container() -> Container {
        var c = Container(name: "spike", image: "alpine:latest", command: ["sh"])
        c.cockerIP = "10.42.0.7"
        c.cockerMAC = "02:42:0a:2a:00:07"
        return c
    }

    @Test func cmdlineCarriesTheAddressWhenSet() {
        let line = KernelCommandLine.build(KernelCommandLineParams(
            container: container(),
            dnsIP: "192.168.64.1",
            dnsPort: 5300,
            cockerSwitchGateway: "10.42.0.1",
            staticNATIP: "192.168.64.200"))
        #expect(line.contains("cocker.eth0_ip=192.168.64.200"))
    }

    /// DHCP stays the default. An unconfigured host must behave exactly as
    /// it did before, which means emitting nothing for cocker-init to find —
    /// the guest branches on the parameter's presence.
    @Test func cmdlineOmitsTheAddressByDefault() {
        let line = KernelCommandLine.build(KernelCommandLineParams(
            container: container(),
            dnsIP: "192.168.64.1",
            dnsPort: 5300,
            cockerSwitchGateway: "10.42.0.1"))
        #expect(!line.contains("cocker.eth0_ip"))
    }

    /// The fabric is a separate NIC and must be unaffected either way.
    @Test func theFabricParametersAreUntouched() {
        let line = KernelCommandLine.build(KernelCommandLineParams(
            container: container(),
            dnsIP: "192.168.64.1",
            dnsPort: 5300,
            cockerSwitchGateway: "10.42.0.1",
            staticNATIP: "192.168.64.200"))
        #expect(line.contains("cocker.cnet_ip=10.42.0.7/16"))
        #expect(line.contains("cocker.cnet_mac=02:42:0a:2a:00:07"))
    }
}
