import Foundation
import Testing
@testable import CockerCore
@testable import CockerDaemon

/// macOS's vmnet lease pool is host-wide, capped at ~256 entries, never
/// reclaimed and `root:wheel` — so a machine that had started 256 containers
/// stopped working until somebody with root truncated a file. A container
/// that configures `eth0` itself never asks for a lease and the ceiling
/// stops existing.
///
/// Verified on hardware against a pool already saturated at 317/256: the
/// container booted, reached the internet over IPv4 and DNS, answered on a
/// published port, and the full e2e suite passed without the lease count
/// moving. See `docs/DESIGN-network-without-vmnet.md`.
///
/// Allocation itself lives in `AddressAllocatorTests`. This is about the
/// address reaching the guest, and surviving on the way there.
@Suite("Static eth0 address")
struct StaticNATAddressTests {

    private func container(natIP: String? = nil) -> Container {
        var c = Container(name: "spike", image: "alpine:latest", command: ["sh"])
        c.cockerIP = "10.42.0.7"
        c.cockerMAC = "02:42:0a:2a:00:07"
        c.natIP = natIP
        return c
    }

    // MARK: - Surviving persistence

    /// `Container` has a hand-written `init(from:)`, so a stored property
    /// missing from it encodes fine and reads back nil — that has already
    /// swallowed `tty` and `shmSizeMB` here.
    ///
    /// For `natIP` the consequence is worse than a lost flag. The allocator
    /// reads persisted addresses to know what is taken, so dropping them on
    /// read means a restarted daemon believes the pool is empty and hands
    /// out addresses that surviving containers still hold.
    @Test func theAddressSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = container(natIP: "192.168.64.137")
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Container.self, from: data)
        #expect(restored.natIP == "192.168.64.137")
    }

    /// State written before this field existed must still load.
    @Test func stateWithoutTheFieldStillDecodes() throws {
        var data = try JSONEncoder().encode(container(natIP: "192.168.64.137"))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "natIP")
        data = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder().decode(Container.self, from: data)
        #expect(restored.natIP == nil)
    }

    // MARK: - Reaching the guest

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
    /// before, which means emitting nothing — the guest branches on the
    /// parameter's presence.
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

    /// The runtime hands over what was allocated and persisted — it does not
    /// recompute anything. Deriving it locally is what the spike did, and a
    /// derivation consults nothing: it cannot see other VMs' leases, and two
    /// containers whose ids collide share an address.
    @Test func theRuntimeUsesThePersistedAddress() {
        #expect(VMRuntime.staticNATIP(for: container(natIP: "192.168.64.190"))
                == "192.168.64.190")
        #expect(VMRuntime.staticNATIP(for: container()) == nil)
    }
}

/// Self-assigned `eth0` addresses are the default as of this change.
///
/// The DHCP path shipped a ceiling: macOS's lease pool is host-wide, capped
/// at ~256, never reclaimed and `root:wheel`, so a machine that had started
/// 256 containers stopped working until somebody with root truncated a file.
/// Keeping that as the default meant shipping a daemon that needs root to
/// recover from its own normal use.
@Suite("Static eth0 is the default")
struct StaticNATDefaultTests {

    /// `unsetenv` then read, so this describes what a normal daemon does
    /// rather than what this test process happens to inherit.
    @MainActor
    private func enabled(with value: String?) -> Bool {
        let key = "COCKER_STATIC_ETH0"
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        return ContainerEngine.staticNATEnabled
    }

    @MainActor
    @Test func onWhenUnset() {
        #expect(enabled(with: nil))
    }

    /// The escape hatch has to work, and has to be obvious — a host where
    /// something else owns the subnet needs a way back to DHCP.
    @MainActor
    @Test func offOnlyWhenExplicitlyDisabled() {
        for off in ["0", "false", "no", "off", "OFF", "False"] {
            #expect(enabled(with: off) == false, "'\(off)' should disable it")
        }
    }

    /// Anything else means on. A typo must not silently reinstate the
    /// ~256-container ceiling.
    @MainActor
    @Test func anUnrecognisedValueDoesNotSilentlyDisableIt() {
        for on in ["1", "true", "yes", "", "wat"] {
            #expect(enabled(with: on), "'\(on)' should leave it enabled")
        }
    }
}
