import Foundation

// Pure DNS query → response pipeline. Takes raw DNS query bytes, decides
// whether it's a local container lookup or an upstream forward, and
// returns the response bytes. No socket I/O — transports (DNSUdpTransport,
// DNSStreamTransport) wrap this with the necessary read/write.
//
// The actual external lookup is injected as a closure so tests can stub it.

public enum DNSQueryAnswerKind: Sendable {
    case authoritativeA(name: String, ip: String)
    /// No longer produced. Containers have no IPv6, and the address this
    /// used to carry was invented — see the note in `process`. Kept so a
    /// reintroduction is a compile-time-visible change rather than a silent
    /// one, and so the test asserting it never appears can name it.
    case authoritativeAAAA(name: String, ipv6: String)
    case empty(name: String)
    case upstream(name: String)
    case nxdomain(name: String)
}

public struct DNSQueryResult: Sendable {
    public let response: Data
    public let kind: DNSQueryAnswerKind

    public init(response: Data, kind: DNSQueryAnswerKind) {
        self.response = response
        self.kind = kind
    }
}

public enum DNSQueryProcessor {

    /// Process a DNS query. Returns nil for malformed queries / non-query
    /// opcodes that we shouldn't reply to.
    ///
    /// - Parameters:
    ///   - query: raw DNS wire bytes (header + questions ; the full UDP
    ///            datagram or the unwrapped TCP/vsock payload).
    ///   - containers: the running-container set we resolve against.
    ///   - forwardUpstream: optional closure that performs the external
    ///                     recursive lookup. If nil, non-local queries get
    ///                     NXDOMAIN. The closure receives the original
    ///                     query bytes and returns the upstream's response
    ///                     bytes verbatim (no rebuilding needed).
    public static func process(
        query: Data,
        containers: [Container],
        forwardUpstream: ((Data) -> Data?)? = nil
    ) -> DNSQueryResult? {
        guard query.count > DNSHeader.size else { return nil }

        let header = DNSHeader(data: query)
        guard header.isQuery, header.opcode == 0 else { return nil }

        let (questions, _) = parseDNSQuestions(from: query, count: Int(header.qdCount))
        guard let question = questions.first else { return nil }

        // A / ANY → resolve against the container set.
        if (question.isA || question.isAny),
           let ip = DNSNameResolver.resolveA(name: question.name, in: containers) {
            return DNSQueryResult(
                response: buildAResponse(header: header, question: question, ip: ip),
                kind: .authoritativeA(name: question.name, ip: ip)
            )
        }

        // AAAA → if the name belongs to a container, answer authoritatively
        // (with the v6 record if it has one, empty if it doesn't). For
        // anything else, fall through to upstream forwarding.
        //
        // The previous version returned an authoritative empty for ALL
        // AAAA queries that didn't match a container. uv / pip / npm /
        // curl all default to "happy-eyeballs" — try AAAA first, only
        // fall back to A on NXDOMAIN, NOT on NOERROR + zero answers
        // (RFC 8305 §3). With our authoritative-empty AAAA they treated
        // CDN hostnames like files.pythonhosted.org as "no such host"
        // and refused to retry over IPv4, breaking every PyPI sync.
        // AAAA for one of our own names → authoritative NODATA: the name
        // exists, that record type does not. Containers have no IPv6.
        //
        // This slot has now held all three possible answers, and two of them
        // shipped broken, so the reasoning is worth keeping:
        //
        //  1. **A fabricated address** (`fd00:c0c4::<hash-of-id>`) — what was
        //     here until this change. Configured on no interface in any
        //     guest; every container had one, so every AAAA query for a
        //     container name got a confident answer pointing nowhere.
        //  2. **Falling through to upstream**, giving NXDOMAIN for a name we
        //     own. Looks conservative; breaks Alpine. musl resolves A and
        //     AAAA in parallel and fails the whole lookup when either comes
        //     back NXDOMAIN, even with a perfectly good A answer in hand.
        //     Measured: `wget: bad address 'db:8080'`, e2e 03 and 05 red.
        //  3. **NODATA**, below. musl accepts NOERROR-with-no-answers and
        //     uses the A record.
        //
        // The container check must stay ahead of the upstream path, and must
        // not be widened to non-container names: an authoritative empty for
        // *those* is the 0.5.13.16 regression, where happy-eyeballs clients
        // (RFC 8305 §3) read NOERROR-no-answers as "no such host" for real
        // CDN names and refused to retry over IPv4.
        if question.isAAAA,
           DNSNameResolver.matchesContainer(name: question.name, in: containers) {
            return DNSQueryResult(
                response: buildEmptyResponse(header: header, question: question),
                kind: .empty(name: question.name)
            )
        }
        // AAAA queries for non-container names + non-AAAA queries
        // (anything past the A/AAAA fast paths above) → forward upstream.
        if let forward = forwardUpstream, let upstream = forward(query) {
            return DNSQueryResult(
                response: upstream,
                kind: .upstream(name: question.name)
            )
        }

        return DNSQueryResult(
            response: buildNXDomain(header: header, question: question),
            kind: .nxdomain(name: question.name)
        )
    }

    // MARK: - Response builders

    private static func buildAResponse(header: DNSHeader, question: DNSQuestion, ip: String) -> Data {
        var rh = header
        rh.flags = header.responseFlags(rcode: 0, authoritative: true)
        rh.anCount = 1
        var b = DNSResponseBuilder()
        b.appendHeader(rh)
        b.appendQuestion(question)
        b.appendARecord(ip: ip, ttl: 10)
        return b.build()
    }

    private static func buildAAAAResponse(header: DNSHeader, question: DNSQuestion, ipv6: String) -> Data {
        var rh = header
        rh.flags = header.responseFlags(rcode: 0, authoritative: true)
        rh.anCount = 1
        var b = DNSResponseBuilder()
        b.appendHeader(rh)
        b.appendQuestion(question)
        b.appendAAAARecord(ip: ipv6, ttl: 10)
        return b.build()
    }

    private static func buildEmptyResponse(header: DNSHeader, question: DNSQuestion) -> Data {
        var rh = header
        rh.flags = header.responseFlags(rcode: 0, authoritative: true)
        rh.anCount = 0
        var b = DNSResponseBuilder()
        b.appendHeader(rh)
        b.appendQuestion(question)
        return b.build()
    }

    private static func buildNXDomain(header: DNSHeader, question: DNSQuestion) -> Data {
        var rh = header
        rh.flags = header.responseFlags(rcode: 3, authoritative: true)  // NXDOMAIN
        rh.anCount = 0
        var b = DNSResponseBuilder()
        b.appendHeader(rh)
        b.appendQuestion(question)
        return b.build()
    }
}
