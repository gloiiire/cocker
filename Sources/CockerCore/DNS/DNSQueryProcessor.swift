import Foundation

// Pure DNS query → response pipeline. Takes raw DNS query bytes, decides
// whether it's a local container lookup or an upstream forward, and
// returns the response bytes. No socket I/O — transports (DNSUdpTransport,
// DNSStreamTransport) wrap this with the necessary read/write.
//
// The actual external lookup is injected as a closure so tests can stub it.

public enum DNSQueryAnswerKind: Sendable {
    case authoritativeA(name: String, ip: String)
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
        if question.isAAAA,
           let ipv6 = DNSNameResolver.resolveAAAA(name: question.name, in: containers) {
            return DNSQueryResult(
                response: buildAAAAResponse(header: header, question: question, ipv6: ipv6),
                kind: .authoritativeAAAA(name: question.name, ipv6: ipv6)
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
