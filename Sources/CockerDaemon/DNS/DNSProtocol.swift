import Foundation

// DNS packet parser/builder — RFC 1035
// Handles A/AAAA queries, name compression, upstream forwarding

struct DNSHeader {
    var id: UInt16
    var flags: UInt16
    var qdCount: UInt16
    var anCount: UInt16
    var nsCount: UInt16
    var arCount: UInt16

    // Flags helpers
    var isQuery: Bool { (flags >> 15) & 1 == 0 }
    var opcode: UInt8 { UInt8((flags >> 11) & 0xF) }
    var isRecursionDesired: Bool { (flags >> 8) & 1 == 1 }

    static let size = 12

    init(data: Data) {
        id      = data.readUInt16BE(at: 0)
        flags   = data.readUInt16BE(at: 2)
        qdCount = data.readUInt16BE(at: 4)
        anCount = data.readUInt16BE(at: 6)
        nsCount = data.readUInt16BE(at: 8)
        arCount = data.readUInt16BE(at: 10)
    }

    func responseFlags(rcode: UInt8 = 0, authoritative: Bool = true) -> UInt16 {
        var f: UInt16 = 0
        f |= (1 << 15)          // QR = response
        f |= UInt16(opcode) << 11
        if authoritative { f |= (1 << 10) }  // AA
        if isRecursionDesired { f |= (1 << 8) }  // RD copy
        f |= (1 << 7)           // RA = recursion available
        f |= UInt16(rcode)
        return f
    }

    func serialize() -> Data {
        var d = Data(count: 12)
        d.writeUInt16BE(id, at: 0)
        d.writeUInt16BE(flags, at: 2)
        d.writeUInt16BE(qdCount, at: 4)
        d.writeUInt16BE(anCount, at: 6)
        d.writeUInt16BE(nsCount, at: 8)
        d.writeUInt16BE(arCount, at: 10)
        return d
    }
}

struct DNSQuestion {
    let name: String
    let qtype: UInt16
    let qclass: UInt16
    let rawBytes: Data  // original bytes for copying into response

    var isA:    Bool { qtype == 1  }
    var isAAAA: Bool { qtype == 28 }
    var isAny:  Bool { qtype == 255 }
}

enum DNSType: UInt16 {
    case A    = 1
    case AAAA = 28
    case PTR  = 12
    case ANY  = 255
}

// MARK: - Packet parsing

func parseDNSQuestions(from data: Data, count: Int) -> (questions: [DNSQuestion], bytesRead: Int) {
    var offset = DNSHeader.size
    var questions: [DNSQuestion] = []

    for _ in 0..<count {
        let start = offset
        guard let (name, newOffset) = readDNSName(from: data, at: offset) else { break }
        offset = newOffset

        guard offset + 4 <= data.count else { break }
        let qtype  = data.readUInt16BE(at: offset)
        let qclass = data.readUInt16BE(at: offset + 2)
        offset += 4

        let rawBytes = Data(data[start..<offset])
        questions.append(DNSQuestion(name: name, qtype: qtype, qclass: qclass, rawBytes: rawBytes))
    }

    return (questions, offset)
}

func readDNSName(from data: Data, at startOffset: Int) -> (name: String, nextOffset: Int)? {
    var labels: [String] = []
    var offset = startOffset
    var jumped = false
    var jumpReturn = 0

    while offset < data.count {
        let len = Int(data[offset])

        if len == 0 {
            offset += 1
            break
        }

        // Pointer compression: top 2 bits = 11
        if (len & 0xC0) == 0xC0 {
            guard offset + 1 < data.count else { return nil }
            let ptr = Int(data.readUInt16BE(at: offset) & 0x3FFF)
            if !jumped { jumpReturn = offset + 2 }
            jumped = true
            offset = ptr
            continue
        }

        // Normal label
        offset += 1
        guard offset + len <= data.count else { return nil }
        let label = String(data: data[offset..<(offset + len)], encoding: .utf8) ?? ""
        labels.append(label)
        offset += len
    }

    let name = labels.joined(separator: ".")
    return (name, jumped ? jumpReturn : offset)
}

// MARK: - Response building

struct DNSResponseBuilder {
    private var data = Data()

    mutating func appendHeader(_ header: DNSHeader) {
        data.append(header.serialize())
    }

    // Copy raw question bytes
    mutating func appendQuestion(_ question: DNSQuestion) {
        data.append(question.rawBytes)
    }

    // A record answer: name pointer + type/class/ttl + IPv4
    mutating func appendARecord(name pointer: UInt16 = 0xC00C, ip: String, ttl: UInt32 = 10) {
        // NAME: pointer to question name
        data.writeUInt16BE(0xC000 | pointer, appendingAt: data.count)
        // TYPE: A (1)
        data.writeUInt16BE(1, appendingAt: data.count)
        // CLASS: IN (1)
        data.writeUInt16BE(1, appendingAt: data.count)
        // TTL (short for containers — IPs change)
        data.writeUInt32BE(ttl, appendingAt: data.count)
        // RDLENGTH: 4
        data.writeUInt16BE(4, appendingAt: data.count)
        // RDATA: IPv4 address
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return }
        data.append(contentsOf: parts)
    }

    // AAAA record answer: name pointer + type 28 + IPv6 (16 bytes)
    mutating func appendAAAARecord(ip: String, ttl: UInt32 = 10) {
        // NAME: pointer to question name (0xC00C)
        data.writeUInt16BE(0xC00C, appendingAt: data.count)
        // TYPE: AAAA (28)
        data.writeUInt16BE(28, appendingAt: data.count)
        // CLASS: IN (1)
        data.writeUInt16BE(1, appendingAt: data.count)
        // TTL
        data.writeUInt32BE(ttl, appendingAt: data.count)
        // RDLENGTH: 16 bytes for IPv6
        data.writeUInt16BE(16, appendingAt: data.count)
        // RDATA: IPv6 address as 16 bytes
        let groups = expandIPv6(ip)
        for group in groups {
            data.writeUInt16BE(group, appendingAt: data.count)
        }
    }

    private func expandIPv6(_ ip: String) -> [UInt16] {
        // Parse compressed IPv6 like fd00:c0c4::1 → 8 groups of UInt16
        var result = [UInt16](repeating: 0, count: 8)
        let parts = ip.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        // Find the :: (empty part) position
        var left: [String] = []
        var right: [String] = []
        var foundEmpty = false

        for part in parts {
            if part.isEmpty {
                foundEmpty = true
            } else if foundEmpty {
                right.append(part)
            } else {
                left.append(part)
            }
        }

        // Fill left side
        for (i, part) in left.enumerated() {
            result[i] = UInt16(part, radix: 16) ?? 0
        }
        // Fill right side from the end
        for (i, part) in right.reversed().enumerated() {
            result[7 - i] = UInt16(part, radix: 16) ?? 0
        }

        return result
    }

    mutating func build() -> Data { data }
}

// MARK: - Upstream DNS forwarding

func forwardToUpstream(_ query: Data, upstream: String = "1.1.1.1", port: UInt16 = 53, timeout: TimeInterval = 2) -> Data? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    // Set timeout
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    inet_pton(AF_INET, upstream, &addr.sin_addr)

    let sent = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            query.withUnsafeBytes { buf in
                sendto(fd, buf.baseAddress!, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard sent > 0 else { return nil }

    var response = [UInt8](repeating: 0, count: 4096)
    let received = recv(fd, &response, response.count, 0)
    guard received > 0 else { return nil }

    return Data(response.prefix(received))
}

// MARK: - Data helpers

extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    mutating func writeUInt16BE(_ value: UInt16, at offset: Int) {
        self[offset]     = UInt8(value >> 8)
        self[offset + 1] = UInt8(value & 0xFF)
    }

    mutating func writeUInt16BE(_ value: UInt16, appendingAt _: Int) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func writeUInt32BE(_ value: UInt32, appendingAt _: Int) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8)  & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
