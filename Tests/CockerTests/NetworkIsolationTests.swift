import Foundation
import Testing
@testable import CockerCore
@testable import CockerDaemon

/// `cocker network create` accepted a name, a driver, a subnet and a
/// gateway, stored all of it, and enforced none of it. Every container sat
/// on one flat L2 segment and DNS resolved globally, so two "separate"
/// networks could reach each other and resolve each other by name. A user
/// who split two stacks apart for isolation got none, and was told nothing.
///
/// Isolation is enforced in two places, and it takes both. The switch drops
/// frames that would cross networks — that is the part that actually
/// contains traffic. DNS scoping is what stops a container resolving a name
/// it provably cannot reach, which would otherwise turn a clean failure
/// into a hang.
@Suite("Network isolation")
struct NetworkIsolationTests {

    private func container(_ name: String, network: String?) -> Container {
        Container(name: name, image: "alpine", command: ["sh"], networkName: network)
    }

    // MARK: - DNS scoping

    @Test func aContainerSeesPeersOnItsOwnNetwork() {
        let a = container("a", network: "frontend")
        let b = container("b", network: "frontend")
        let visible = DNSServer.visibleContainers(to: a.id, from: [a, b])
        #expect(visible.map(\.name).sorted() == ["a", "b"])
    }

    /// The point of the whole change.
    @Test func aContainerCannotResolveAcrossNetworks() {
        let a = container("a", network: "frontend")
        let c = container("c", network: "backend")
        let visible = DNSServer.visibleContainers(to: a.id, from: [a, c])
        #expect(visible.map(\.name) == ["a"], "backend leaked into frontend's view")
    }

    /// Containers with no explicit network share the default one, which is
    /// what almost every `cocker run` does — this must keep working.
    @Test func containersWithNoNetworkShareTheDefault() {
        let a = container("a", network: nil)
        let b = container("b", network: nil)
        #expect(DNSServer.visibleContainers(to: a.id, from: [a, b]).count == 2)
    }

    /// `nil` and `"bridge"` are the same network, not two.
    @Test func theDefaultNetworkIsNamedBridge() {
        let a = container("a", network: nil)
        let b = container("b", network: "bridge")
        #expect(DNSServer.visibleContainers(to: a.id, from: [a, b]).count == 2)
    }

    /// A query we cannot attribute must keep the old global view rather than
    /// resolve nothing. Host-side queries have no asker, and a wiring mistake
    /// that lost the asker should degrade to "too permissive", not to "DNS is
    /// broken for everyone".
    @Test func anUnidentifiedAskerFallsBackToTheGlobalView() {
        let a = container("a", network: "frontend")
        let c = container("c", network: "backend")
        #expect(DNSServer.visibleContainers(to: nil, from: [a, c]).count == 2)
        #expect(DNSServer.visibleContainers(to: "not-a-container", from: [a, c]).count == 2)
    }

    /// Scoping happens before name resolution, so a name that exists on
    /// another network resolves to nothing rather than to an unreachable
    /// address.
    @Test func aNameOnAnotherNetworkDoesNotResolve() {
        let a = container("a", network: "frontend")
        var db = container("db", network: "backend")
        db.cockerIP = "10.42.0.9"

        let visibleToA = DNSServer.visibleContainers(to: a.id, from: [a, db])
        #expect(DNSNameResolver.resolveA(name: "db", in: visibleToA) == nil)

        // …and still resolves for a peer that shares its network.
        var peer = container("peer", network: "backend")
        peer.cockerIP = "10.42.0.10"
        let visibleToPeer = DNSServer.visibleContainers(to: peer.id, from: [peer, db])
        #expect(DNSNameResolver.resolveA(name: "db", in: visibleToPeer) == "10.42.0.9")
    }
}
