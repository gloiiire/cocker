import Foundation
import Testing
@testable import CockerCore
@testable import CockerDaemon

/// Allocation used to be a cursor held in memory: hand out the next id,
/// remember where you stopped. That is only correct while the process
/// owning the cursor stays alive. Restart `cockerd` and it resets to the
/// start of the range while containers that survived the restart still hold
/// their addresses — so it hands out duplicates, silently, on a switch that
/// forwards by learned MAC.
///
/// The replacement keeps no state to lose: it takes the addresses actually
/// in use and returns the lowest free one. Which means the interesting
/// tests are about what "in use" is allowed to miss.
@Suite("Address allocation")
struct AddressAllocatorTests {

    // MARK: - The pool itself

    @Test func handsOutTheLowestFreeID() {
        #expect(AddressPool.lowestFree(first: 2, last: 10, inUse: []) == 2)
        #expect(AddressPool.lowestFree(first: 2, last: 10, inUse: [2, 3, 4]) == 5)
    }

    /// Holes get refilled — that is the whole point of not using a cursor.
    /// A container removed from the middle of the range returns its address.
    @Test func reusesAFreedAddressInsteadOfMarchingOnwards() {
        #expect(AddressPool.lowestFree(first: 2, last: 10, inUse: [2, 4, 5]) == 3)
    }

    /// Refuses rather than wraps. Wrapping means returning an address
    /// somebody already holds, which fails later and somewhere else, as
    /// traffic arriving at the wrong container.
    @Test func afullPoolYieldsNothing() {
        #expect(AddressPool.lowestFree(first: 2, last: 4, inUse: [2, 3, 4]) == nil)
    }

    @Test func anInvertedRangeYieldsNothing() {
        #expect(AddressPool.lowestFree(first: 10, last: 2, inUse: []) == nil)
    }

    /// `last` sitting at the top of the type must terminate, not overflow.
    @Test func aRangeEndingAtTheMaximumTerminates() {
        #expect(AddressPool.lowestFree(first: .max, last: .max, inUse: []) == .max)
        #expect(AddressPool.lowestFree(first: .max, last: .max, inUse: [.max]) == nil)
    }

    // MARK: - Reading "what is taken" out of mixed data

    @Test func onlyAddressesInOurSubnetCount() {
        #expect(AddressPool.hostInSubnet("192.168.64.42", prefix: "192.168.64") == 42)
        #expect(AddressPool.hostInSubnet("10.0.0.42", prefix: "192.168.64") == nil)
        #expect(AddressPool.hostInSubnet("not-an-ip", prefix: "192.168.64") == nil)
        #expect(AddressPool.hostInSubnet("192.168.640.1", prefix: "192.168.64") == nil)
    }

    // MARK: - eth0, the vmnet side

    /// The reason this allocator exists: vmnet shares the subnet with
    /// whatever else runs on the host, and nothing announces itself. An
    /// address already leased to another VM must not be handed out.
    @Test func skipsAddressesVmnetLeasedToSomebodyElse() {
        let ip = NATAddressAllocator.allocate(
            prefix: "192.168.64",
            leased: ["192.168.64.128", "192.168.64.129"],
            assigned: [])
        #expect(ip == "192.168.64.130")
    }

    @Test func skipsAddressesOurOwnContainersHold() {
        let ip = NATAddressAllocator.allocate(
            prefix: "192.168.64",
            leased: [],
            assigned: ["192.168.64.128"])
        #expect(ip == "192.168.64.129")
    }

    /// Leases for other subnets are noise in the same file and must not
    /// consume ids in ours.
    @Test func leasesFromOtherSubnetsAreIgnored() {
        let ip = NATAddressAllocator.allocate(
            prefix: "192.168.64",
            leased: ["10.0.0.128", "172.16.0.128"],
            assigned: [])
        #expect(ip == "192.168.64.128")
    }

    /// It has to work in whichever /24 vmnet actually chose, which is not
    /// always 192.168.64.
    @Test func followsTheSubnetVmnetChose() {
        #expect(NATAddressAllocator.subnetPrefix(ofGateway: "192.168.105.1") == "192.168.105")
        let ip = NATAddressAllocator.allocate(prefix: "192.168.105", leased: [], assigned: [])
        #expect(ip == "192.168.105.128")
    }

    @Test func aMalformedGatewayHasNoSubnet() {
        #expect(NATAddressAllocator.subnetPrefix(ofGateway: "nope") == nil)
        #expect(NATAddressAllocator.subnetPrefix(ofGateway: "192.168.64") == nil)
    }

    /// Full means full. Refusing lets the caller say so; wrapping would put
    /// two containers on one address and say nothing.
    @Test func afullSubnetYieldsNothing() {
        let everything = Set((NATAddressAllocator.firstHost...NATAddressAllocator.lastHost)
            .map { "192.168.64.\($0)" })
        #expect(NATAddressAllocator.allocate(prefix: "192.168.64",
                                             leased: everything,
                                             assigned: []) == nil)
    }

    /// bootpd allocates from the low end of the subnet, so staying high
    /// keeps a self-assigned address clear of leases it issues *later* —
    /// which the lease file cannot tell us about.
    @Test func allocatesFromTheHighEndOfTheSubnet() {
        #expect(NATAddressAllocator.firstHost >= 128)
        #expect(NATAddressAllocator.lastHost <= 254)   // .255 is broadcast
        let ip = NATAddressAllocator.allocate(prefix: "192.168.64", leased: [], assigned: [])
        #expect(ip == "192.168.64.128")
    }

    /// The gateway is never allocatable, even if somebody narrows the range
    /// down to include it.
    @Test func theGatewayIsNeverHandedOut() {
        let ips = (0..<NATAddressAllocator.capacity).reduce(into: Set<String>()) { acc, _ in
            if let ip = NATAddressAllocator.allocate(prefix: "192.168.64",
                                                     leased: [], assigned: acc) {
                acc.insert(ip)
            }
        }
        #expect(!ips.contains("192.168.64.1"))
        #expect(ips.count == NATAddressAllocator.capacity)
    }

    // MARK: - eth1, the fabric side

    @Test func fabricAddressesRoundTripThroughTheirHostID() {
        for host: UInt16 in [2, 255, 256, 4242, 65534] {
            let ip = CockerSwitchAllocator.ip(forHost: host)
            #expect(CockerSwitchAllocator.host(forIP: ip) == host,
                    "\(ip) did not round-trip from host \(host)")
        }
    }

    @Test func addressesOutsideTheFabricHaveNoHostID() {
        #expect(CockerSwitchAllocator.host(forIP: "192.168.64.2") == nil)
        #expect(CockerSwitchAllocator.host(forIP: "10.43.0.2") == nil)
        #expect(CockerSwitchAllocator.host(forIP: "garbage") == nil)
    }

    /// The restart bug, as a unit test. A daemon that has forgotten its
    /// in-memory cursor still sees these addresses on persisted containers,
    /// so the next allocation must step over them rather than restart at
    /// `firstHost`.
    @Test func allocationAfterARestartSkipsSurvivingContainers() {
        let survivors: Set<UInt32> = ["10.42.0.2", "10.42.0.3", "10.42.0.4"]
            .compactMap { CockerSwitchAllocator.host(forIP: $0) }
            .reduce(into: Set<UInt32>()) { $0.insert(UInt32($1)) }

        let next = AddressPool.lowestFree(first: UInt32(CockerSwitchAllocator.firstHost),
                                          last: UInt32(CockerSwitchAllocator.lastHost),
                                          inUse: survivors)
        #expect(next == 5, "a cursor reset would have returned 2 and duplicated an address")
        #expect(CockerSwitchAllocator.ip(forHost: UInt16(next!)) == "10.42.0.5")
    }
}
