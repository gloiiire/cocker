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

    private func container(name: String, cockerIP: String? = nil) -> Container {
        var c = Container(
            id: "abc123def456",
            name: name,
            image: "alpine",
            command: ["sh"],
            hostname: name
        )
        c.cockerIP = cockerIP
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

    /// The fabricated answer, gone. cocker used to reply to any AAAA query
    /// for a container name with `fd00:c0c4::<hash-of-id>` — an address it
    /// invented, stored, and served, configured on no interface in any
    /// guest. Containers have no IPv6, so these fall through like any other
    /// name we cannot answer.
    /// The fabricated answer, gone — and replaced by NODATA rather than by
    /// silence. cocker used to reply to any AAAA query for a container name
    /// with `fd00:c0c4::<hash-of-id>`, an address configured on no interface
    /// in any guest.
    ///
    /// Answering nothing at all (falling through to upstream, hence NXDOMAIN
    /// for a name we own) was tried and is worse: musl resolves A and AAAA in
    /// parallel and fails the whole lookup when either returns NXDOMAIN, so
    /// every Alpine container lost DNS by name. Measured as `wget: bad
    /// address 'db:8080'`, e2e 03 and 05 red.
    @Test func aaaaForAContainerIsAuthoritativeNodata() throws {
        let q = buildQuery(name: "srv-a", qtype: 28)  // AAAA
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [container(name: "srv-a", cockerIP: "10.42.0.2")]
        )
        let result = try #require(r)
        if case .authoritativeAAAA = result.kind {
            Issue.record("the fabricated IPv6 answer is back")
        }
        guard case .empty = result.kind else {
            Issue.record("expected authoritative NODATA, got \(result.kind); NXDOMAIN here breaks musl's parallel A/AAAA lookup")
            return
        }
    }

    /// The same name must still resolve over IPv4 — that is the answer musl
    /// ends up using.
    @Test func theSameNameStillResolvesOverIPv4() throws {
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

    /// The other half of the rule: a name we do NOT own must keep going
    /// upstream. Answering NODATA for those is the 0.5.13.16 regression that
    /// broke PyPI installs.
    @Test func aaaaForAForeignNameIsNotAnsweredAuthoritatively() throws {
        let q = buildQuery(name: "files.pythonhosted.org", qtype: 28)
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [container(name: "srv-a", cockerIP: "10.42.0.2")]
        )
        let result = try #require(r)
        if case .empty = result.kind {
            Issue.record("authoritative NODATA leaked to a foreign name")
        }
    }

    /// The 0.5.13.16 rule, narrowed rather than reverted.
    ///
    /// That fix stopped answering authoritative-empty for AAAA because
    /// happy-eyeballs clients (RFC 8305 §3) read NOERROR-with-no-answers as
    /// "no such host" and would not retry over IPv4 — which broke PyPI when a
    /// container's name collided with the first label of a real CDN host.
    /// It applied that to every AAAA query, container or not.
    ///
    /// Blanket fall-through turned out to be wrong for names we DO own: musl
    /// resolves A and AAAA in parallel and fails the whole lookup when either
    /// comes back NXDOMAIN, so Alpine containers lost DNS by name entirely
    /// (`wget: bad address 'db:8080'`, e2e 03 and 05 red).
    ///
    /// So the rule is now split by ownership, and both halves are pinned:
    /// ours → NODATA (above), foreign → upstream (here).
    @Test func aaaaForAForeignNameFallsThroughToUpstream() throws {
        let q = buildQuery(name: "cdn.example.org", qtype: 28)
        let r = DNSQueryProcessor.process(
            query: q,
            containers: [container(name: "srv-a", cockerIP: "10.42.0.2")]
        )
        let result = try #require(r)
        // No upstream forwarder wired up here, so falling through lands on
        // NXDOMAIN — the point is that it is not answered authoritatively.
        if case .nxdomain = result.kind { /* expected */ }
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
