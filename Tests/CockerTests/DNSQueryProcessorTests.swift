import Testing
import Foundation
@testable import CockerCore

@Suite("DNS query processor")
struct DNSQueryProcessorTests {

    // MARK: - Helpers

    /// Build a DNS query packet (header + one question). Returns the raw bytes.
    private func buildQuery(name: String, qtype: UInt16, id: UInt16 = 0x1234) -> Data {
        // Header
        var d = Data()
        d.append(UInt8(id >> 8)); d.append(UInt8(id & 0xFF))         // ID
        d.append(0x01); d.append(0x00)                                 // flags : standard query, RD=1
        d.append(0x00); d.append(0x01)                                 // QDCOUNT = 1
        d.append(0x00); d.append(0x00)                                 // ANCOUNT
        d.append(0x00); d.append(0x00)                                 // NSCOUNT
        d.append(0x00); d.append(0x00)                                 // ARCOUNT

        // QNAME : sequence of (length-prefixed labels) ending with 0
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            d.append(UInt8(bytes.count))
            d.append(contentsOf: bytes)
        }
        d.append(0)  // root label

        // QTYPE + QCLASS
        d.append(UInt8(qtype >> 8)); d.append(UInt8(qtype & 0xFF))
        d.append(0x00); d.append(0x01)  // class IN

        return d
    }

    private func container(name: String, cockerIP: String? = nil, ipv6: String? = nil) -> Container {
        var c = Container(
            id: "abc123def456",
            name: name,
            image: "alpine",
            command: ["sh"],
            hostname: name
        )
        c.cockerIP = cockerIP
        c.ipv6 = ipv6
        return c
    }

    // MARK: - A records

    @Test func resolvesANameToCockerIP() throws {
        let q = buildQuery(name: "srv-a", qtype: 1)  // A
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [container(name: "srv-a", cockerIP: "10.42.0.2")]
        )
        let result = try #require(r)
        if case .authoritativeA(_, let ip) = result.kind {
            #expect(ip == "10.42.0.2")
        } else {
            Issue.record("expected authoritativeA, got \(result.kind)")
        }
    }

    @Test func aResponseStartsWithQueryIDAndHasResponseBit() throws {
        let q = buildQuery(name: "srv-a", qtype: 1, id: 0xCAFE)
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [container(name: "srv-a", cockerIP: "10.42.0.2")]
        )
        let response = try #require(r?.response)
        // ID preserved
        #expect(response[0] == 0xCA)
        #expect(response[1] == 0xFE)
        // QR (high bit of byte 2) = 1
        #expect((response[2] & 0x80) != 0)
        // ANCOUNT = 1
        #expect(response[6] == 0 && response[7] == 1)
    }

    @Test func aRecordEncodesIPv4Correctly() throws {
        let q = buildQuery(name: "x", qtype: 1)
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [container(name: "x", cockerIP: "10.42.0.42")]
        )
        let response = try #require(r?.response)
        // last 4 bytes = the IPv4 octets
        let last4 = Array(response.suffix(4))
        #expect(last4 == [10, 42, 0, 42])
    }

    // MARK: - AAAA records

    @Test func resolvesAAAAToContainerIPv6() throws {
        let q = buildQuery(name: "srv-a", qtype: 28)  // AAAA
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [container(name: "srv-a", ipv6: "fd00:c0c4::5")]
        )
        let result = try #require(r)
        if case .authoritativeAAAA(_, let ipv6) = result.kind {
            #expect(ipv6 == "fd00:c0c4::5")
        } else {
            Issue.record("expected authoritativeAAAA, got \(result.kind)")
        }
    }

    /// Before 0.5.13.16 we answered AAAA for a name-matching-container
    /// with no IPv6 as "authoritative empty", which breaks happy-eyeballs
    /// (RFC 8305) for tools like uv / pip / curl when the container's
    /// hostname collides with a real public CDN (files.pythonhosted.org
    /// hit this). The new contract : without an IPv6 we DO NOT short-
    /// circuit ; the query falls through to upstream forwarding. When no
    /// upstream forwarder is wired up (this test's case), `process`
    /// returns `nil` so the caller can decide what to do.
    @Test func aaaaWithoutIPv6FallsThroughToUpstream() throws {
        let q = buildQuery(name: "srv-a", qtype: 28)
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [container(name: "srv-a", cockerIP: "10.42.0.2")]  // no ipv6
        )
        let result = try #require(r)
        if case .nxdomain = result.kind { /* ok — no upstream + no v6 = NXDOMAIN */ }
        else { Issue.record("expected nxdomain, got \(result.kind)") }
    }

    // MARK: - Upstream forwarding

    @Test func unknownNameForwardsToUpstreamWhenAvailable() throws {
        let q = buildQuery(name: "google.com", qtype: 1)
        var forwardedQuery: Data?
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [],
            forwardUpstream: { incoming in
                forwardedQuery = incoming
                // Synthesize a tiny "response" — content doesn't matter, just identity.
                return Data([0xDE, 0xAD, 0xBE, 0xEF])
            }
        )
        let result = try #require(r)
        if case .upstream(let name) = result.kind {
            #expect(name == "google.com")
        } else {
            Issue.record("expected upstream, got \(result.kind)")
        }
        #expect(result.response == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(forwardedQuery == q)
    }

    @Test func unknownNameWithoutUpstreamReturnsNXDOMAIN() throws {
        let q = buildQuery(name: "nope.invalid", qtype: 1)
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [],
            forwardUpstream: nil
        )
        let result = try #require(r)
        if case .nxdomain = result.kind { /* ok */ }
        else { Issue.record("expected nxdomain, got \(result.kind)") }
        // RCODE = 3 in flags byte 3, low nibble
        #expect((result.response[3] & 0x0F) == 3)
    }

    @Test func upstreamFailureFallsBackToNXDOMAIN() throws {
        let q = buildQuery(name: "nope.invalid", qtype: 1)
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [],
            forwardUpstream: { _ in nil }
        )
        let result = try #require(r)
        if case .nxdomain = result.kind { /* ok */ }
        else { Issue.record("expected nxdomain, got \(result.kind)") }
    }

    // MARK: - Malformed input

    @Test func tooShortQueryReturnsNil() {
        let r = DNSQueryProcessor.process(query: Data([0x00, 0x01]), containers: [])
        #expect(r == nil)
    }

    @Test func responseOpcodeIsIgnored() {
        // Build a "response" packet (QR=1) and confirm we don't reply.
        var q = buildQuery(name: "anything", qtype: 1)
        q[2] = 0x81  // set QR bit
        let r = DNSQueryProcessor.process(query: q, containers: [])
        #expect(r == nil)
    }

    // MARK: - ANY queries treat like A

    @Test func anyQueryResolvesLikeA() throws {
        let q = buildQuery(name: "srv-a", qtype: 255)  // ANY
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [container(name: "srv-a", cockerIP: "10.42.0.2")]
        )
        let result = try #require(r)
        if case .authoritativeA = result.kind { /* ok */ }
        else { Issue.record("expected authoritativeA for ANY, got \(result.kind)") }
    }
}
