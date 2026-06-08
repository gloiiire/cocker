import Testing
import Foundation
@testable import CockerDaemon

@Suite("DockerAPIServer.rfc3339Nano — Go time.RFC3339Nano compatibility")
struct Rfc3339NanoTests {
    @Test func wholeSecondNoFraction() {
        // A Date that lands on an exact second emits the "Z" suffix
        // without a fractional part — matches Go's RFC3339Nano which
        // trims trailing zeros.
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let s = DockerAPIServer.rfc3339Nano(d)
        #expect(s == "2023-11-14T22:13:20Z")
    }

    @Test func subsecondHasFractionalPart() {
        // A Date with sub-second precision must surface the fractional
        // chunk so Go's `time.Time` round-trip preserves the nano.
        let d = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let s = DockerAPIServer.rfc3339Nano(d)
        #expect(s.hasPrefix("2023-11-14T22:13:20."))
        #expect(s.hasSuffix("Z"))
        // 123456 us = 123456000 ns ; Go trims trailing zeros so we expect
        // "123456" (without the 000 tail).
        #expect(s.contains(".123456"))
    }

    @Test func epochZero() {
        let s = DockerAPIServer.rfc3339Nano(Date(timeIntervalSince1970: 0))
        #expect(s == "1970-01-01T00:00:00Z")
    }
}
