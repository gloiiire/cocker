import Testing
import Foundation
@testable import CockerCore

@Suite("DNS name resolver — A records")
struct DNSNameResolverATests {
    private func makeContainer(
        id: String = "abc123def456",
        name: String,
        hostname: String? = nil,
        labels: [String: String] = [:],
        ip: String? = nil,
        cockerIP: String? = nil,
        ipv6: String? = nil
    ) -> Container {
        var c = Container(
            id: id, name: name,
            image: "alpine", command: ["sh"],
            labels: labels,
            hostname: hostname ?? name
        )
        c.ip = ip
        c.cockerIP = cockerIP
        c.ipv6 = ipv6
        return c
    }

    @Test func resolvesExactContainerName() {
        let c = makeContainer(name: "srv-a", cockerIP: "10.42.0.2")
        #expect(DNSNameResolver.resolveA(name: "srv-a", in: [c]) == "10.42.0.2")
    }

    @Test func prefersCockerIPOverVmnetIP() {
        let c = makeContainer(name: "srv-a", ip: "192.168.64.5", cockerIP: "10.42.0.2")
        #expect(DNSNameResolver.resolveA(name: "srv-a", in: [c]) == "10.42.0.2")
    }

    @Test func fallsBackToVmnetIPWhenCockerIPMissing() {
        let c = makeContainer(name: "srv-a", ip: "192.168.64.5")
        #expect(DNSNameResolver.resolveA(name: "srv-a", in: [c]) == "192.168.64.5")
    }

    @Test func skipsContainersWithoutAnyIP() {
        let c = makeContainer(name: "srv-a")
        #expect(DNSNameResolver.resolveA(name: "srv-a", in: [c]) == nil)
    }

    @Test func resolvesFQDNWithCockerDomain() {
        let c = makeContainer(name: "srv-a", cockerIP: "10.42.0.2")
        #expect(DNSNameResolver.resolveA(name: "srv-a.cocker", in: [c]) == "10.42.0.2")
    }

    @Test func resolvesFQDNWithTrailingDot() {
        let c = makeContainer(name: "srv-a", cockerIP: "10.42.0.2")
        #expect(DNSNameResolver.resolveA(name: "srv-a.", in: [c]) == "10.42.0.2")
        #expect(DNSNameResolver.resolveA(name: "srv-a.cocker.", in: [c]) == "10.42.0.2")
    }

    @Test func resolvesByShortID() {
        let c = makeContainer(id: "abc123def456", name: "verbose-name", cockerIP: "10.42.0.5")
        #expect(DNSNameResolver.resolveA(name: "abc123def456", in: [c]) == "10.42.0.5")
    }

    @Test func resolvesByHostname() {
        let c = makeContainer(name: "srv-a", hostname: "my-host", cockerIP: "10.42.0.3")
        #expect(DNSNameResolver.resolveA(name: "my-host", in: [c]) == "10.42.0.3")
    }

    @Test func resolvesByComposeServiceLabel() {
        let c = makeContainer(
            name: "compose_web_1",
            labels: ["com.cocker.service": "web"],
            cockerIP: "10.42.0.4"
        )
        #expect(DNSNameResolver.resolveA(name: "web", in: [c]) == "10.42.0.4")
        #expect(DNSNameResolver.resolveA(name: "web.cocker", in: [c]) == "10.42.0.4")
    }

    @Test func resolvesByNetworkAlias() {
        let c = makeContainer(
            name: "real-name",
            labels: ["com.cocker.aliases": "alias1, alias2 ,  alias3"],
            cockerIP: "10.42.0.7"
        )
        #expect(DNSNameResolver.resolveA(name: "alias1", in: [c]) == "10.42.0.7")
        #expect(DNSNameResolver.resolveA(name: "alias2", in: [c]) == "10.42.0.7")
        #expect(DNSNameResolver.resolveA(name: "alias3", in: [c]) == "10.42.0.7")
    }

    @Test func returnsNilForUnknownName() {
        let c = makeContainer(name: "srv-a", cockerIP: "10.42.0.2")
        #expect(DNSNameResolver.resolveA(name: "nope", in: [c]) == nil)
    }

    @Test func resolvesAcrossMultipleContainers() {
        let cs = [
            makeContainer(name: "web", cockerIP: "10.42.0.2"),
            makeContainer(name: "db",  cockerIP: "10.42.0.3"),
            makeContainer(name: "cache", cockerIP: "10.42.0.4"),
        ]
        #expect(DNSNameResolver.resolveA(name: "web", in: cs) == "10.42.0.2")
        #expect(DNSNameResolver.resolveA(name: "db",  in: cs) == "10.42.0.3")
        #expect(DNSNameResolver.resolveA(name: "cache", in: cs) == "10.42.0.4")
    }

    @Test func returnsNilOnEmptyContainerList() {
        #expect(DNSNameResolver.resolveA(name: "anything", in: []) == nil)
    }
}

@Suite("DNS name resolver — AAAA records")
struct DNSNameResolverAAAATests {
    @Test func resolvesExactNameToIPv6() {
        var c = Container(id: "x", name: "srv", image: "a", command: ["sh"])
        c.ipv6 = "fd00::1"
        #expect(DNSNameResolver.resolveAAAA(name: "srv", in: [c]) == "fd00::1")
    }

    @Test func skipsContainerWithoutIPv6() {
        let c = Container(id: "x", name: "srv", image: "a", command: ["sh"])
        #expect(DNSNameResolver.resolveAAAA(name: "srv", in: [c]) == nil)
    }

    @Test func resolvesByServiceLabel() {
        var c = Container(
            id: "x", name: "compose_db_1",
            image: "a", command: ["sh"],
            labels: ["com.cocker.service": "db"]
        )
        c.ipv6 = "fd00::2"
        #expect(DNSNameResolver.resolveAAAA(name: "db", in: [c]) == "fd00::2")
    }

    @Test func resolvesByShortID() {
        var c = Container(id: "abc123def456", name: "verbose", image: "a", command: ["sh"])
        c.ipv6 = "fd00::3"
        #expect(DNSNameResolver.resolveAAAA(name: "abc123def456", in: [c]) == "fd00::3")
    }
}

@Suite("DNS name resolver — name normalization")
struct DNSNameNormalizationTests {
    @Test func plainNameStaysItself() {
        let s = DNSNameResolver.normalizedNames(from: "srv-a")
        #expect(s.contains("srv-a"))
    }

    @Test func stripsCockerDomain() {
        let s = DNSNameResolver.normalizedNames(from: "srv-a.cocker")
        #expect(s.contains("srv-a"))
    }

    @Test func stripsTrailingDot() {
        let s = DNSNameResolver.normalizedNames(from: "srv-a.")
        #expect(s.contains("srv-a"))
    }

    @Test func extractsFirstLabel() {
        let s = DNSNameResolver.normalizedNames(from: "srv-a.myproject_default.cocker")
        // After stripping .cocker we get "srv-a.myproject_default", first label "srv-a"
        #expect(s.contains("srv-a"))
        #expect(s.contains("srv-a.myproject_default"))
    }

    @Test func leavesNonCockerDomainAlone() {
        let s = DNSNameResolver.normalizedNames(from: "example.com")
        #expect(s.contains("example.com"))
        // "example" is the first label, still gets emitted
        #expect(s.contains("example"))
    }
}
