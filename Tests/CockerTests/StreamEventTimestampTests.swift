import Testing
import Foundation
@testable import CockerCore

@Suite("StreamEvent — timestamp overload")
struct StreamEventTimestampTests {
    @Test func defaultInitUsesNow() {
        let before = Date()
        let e = StreamEvent(stream: .stdout, data: "x")
        let after = Date()
        // Now-ish — within the bracketing window.
        #expect(e.timestamp >= before && e.timestamp <= after)
        #expect(e.data == "x")
        #expect(e.stream == .stdout)
    }

    @Test func explicitTimestampPreserved() {
        // Used by VMRuntime.readJSONLog when replaying persisted events
        // for short-lived containers whose in-memory buffer is already
        // gone. The replay must keep the original timestamp so `docker
        // logs --timestamps` shows the right values.
        let frozen = Date(timeIntervalSince1970: 1_700_000_000.5)
        let e = StreamEvent(stream: .stderr, data: "replay", timestamp: frozen)
        #expect(e.timestamp == frozen)
        #expect(e.data == "replay")
        #expect(e.stream == .stderr)
    }

    @Test func codableRoundtripPreservesTimestamp() throws {
        let frozen = Date(timeIntervalSince1970: 1_700_000_000.5)
        let e = StreamEvent(stream: .stdout, data: "hi", timestamp: frozen)
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(StreamEvent.self, from: data)
        #expect(back.timestamp.timeIntervalSince1970 == frozen.timeIntervalSince1970)
    }
}
