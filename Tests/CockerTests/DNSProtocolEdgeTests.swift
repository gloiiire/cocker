import Testing
import Foundation
@testable import CockerCore

// Edge cases for the RFC 1035 packet parser/builder. Existing tests
// cover the happy path ; this file targets the response-building helpers
// + parsing failures that left lines uncovered.

@Suite("DNSResponseBuilder — A/AAAA record framing")
struct DNSResponseBuilderTests {
    @Test func appendARecordEmitsCorrectFraming() {
        var b = DNSResponseBuilder()
        b.appendARecord(ip: "192.168.1.42", ttl: 30)
        let bytes = b.build()
        // Record layout (NAME[2] TYPE[2] CLASS[2] TTL[4] RDLENGTH[2] RDATA[4])
        // = 16 bytes. Anchor from the tail :
        let len = bytes.count
        // Last 4 bytes = IPv4 octets.
        #expect(bytes[len - 4] == 192)
        #expect(bytes[len - 3] == 168)
        #expect(bytes[len - 2] == 1)
        #expect(bytes[len - 1] == 42)
        // Bytes [len-6 .. len-5] = RDLENGTH (0, 4).
        #expect(bytes[len - 6] == 0)
        #expect(bytes[len - 5] == 4)
        // Bytes [len-10 .. len-7] = TTL big-endian 30.
        #expect(bytes[len - 10] == 0)
        #expect(bytes[len - 9] == 0)
        #expect(bytes[len - 8] == 0)
        #expect(bytes[len - 7] == 30)
    }

    @Test func malformedIPDoesNotCrash() {
        // "10.0.0" has only 3 octets — builder must short-circuit safely.
        var b = DNSResponseBuilder()
        b.appendARecord(ip: "10.0.0", ttl: 10)
        // Header bytes still emitted ; RDATA missing. Length ≤ pre-RDATA.
        #expect(b.build().count >= 10)
    }

    @Test func appendAAAARecordHasCorrectType() {
        var b = DNSResponseBuilder()
        b.appendAAAARecord(ip: "::1", ttl: 60)
        let bytes = b.build()
        // TYPE field sits at offset 2 (after NAME pointer 0xC00C).
        // AAAA == 28 == 0x001C.
        #expect(bytes[2] == 0)
        #expect(bytes[3] == 28)
    }
}

@Suite("DNSHeader — query / response flag accessors")
struct DNSHeaderFlagTests {
    private func headerData(flags: UInt16) -> Data {
        var d = Data(count: 12)
        d.writeUInt16BE(0x1234, at: 0)
        d.writeUInt16BE(flags, at: 2)
        return d
    }

    @Test func queryDetectsZeroQR() {
        let h = DNSHeader(data: headerData(flags: 0x0100))
        #expect(h.isQuery)
        #expect(h.isRecursionDesired)
    }

    @Test func responseDetectsOneQR() {
        let h = DNSHeader(data: headerData(flags: 0x8180))
        #expect(!h.isQuery)
    }

    @Test func responseFlagsRoundtrip() {
        let h = DNSHeader(data: headerData(flags: 0x0100))
        let flags = h.responseFlags()
        // QR bit (bit 15) must be set.
        #expect((flags >> 15) & 1 == 1)
        // AA bit (bit 10) must be set since authoritative=true by default.
        #expect((flags >> 10) & 1 == 1)
        // RA bit (bit 7) must be set.
        #expect((flags >> 7) & 1 == 1)
    }

    @Test func responseFlagsCarryRCode() {
        let h = DNSHeader(data: headerData(flags: 0x0100))
        let f = h.responseFlags(rcode: 3)
        #expect(f & 0xF == 3)
    }

    @Test func serializeRoundtrip() {
        let raw = headerData(flags: 0x0100)
        var hdr = DNSHeader(data: raw)
        hdr.qdCount = 1
        let out = hdr.serialize()
        #expect(out.count == 12)
        #expect(out.readUInt16BE(at: 4) == 1)
    }
}

@Suite("readDNSName — parser failure modes")
struct ReadDNSNameTests {
    @Test func nameWithSingleLabel() {
        // 1 byte length + "a" + null terminator
        let bytes: [UInt8] = [1, 0x61, 0]
        let r = readDNSName(from: Data(bytes), at: 0)
        #expect(r?.name == "a")
        #expect(r?.nextOffset == 3)
    }

    @Test func nameTruncatedReturnsNil() {
        // length byte 5 but only 2 chars follow → out-of-bounds, must nil out.
        let bytes: [UInt8] = [5, 0x61, 0x62]
        let r = readDNSName(from: Data(bytes), at: 0)
        #expect(r == nil)
    }

    @Test func pointerCompressionResolves() {
        // Two labels at offset 0 = "a.b" then offset 5 = pointer to 0.
        // Layout : [1, 'a', 1, 'b', 0, 0xC0, 0]
        let bytes: [UInt8] = [1, 0x61, 1, 0x62, 0, 0xC0, 0]
        let r = readDNSName(from: Data(bytes), at: 5)
        #expect(r?.name == "a.b")
        // Compressed pointer always advances by 2 (the pointer bytes).
        #expect(r?.nextOffset == 7)
    }

    @Test func pointerOutOfBoundsReturnsNil() {
        let bytes: [UInt8] = [0xC0]  // pointer indicator but no follow-up byte
        let r = readDNSName(from: Data(bytes), at: 0)
        #expect(r == nil)
    }
}
