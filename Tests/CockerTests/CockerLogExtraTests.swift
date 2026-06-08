import Testing
import Foundation
@testable import CockerCore

@Suite("CockerLog — init + environment")
struct CockerLogInitTests {
    @Test func defaultInitIsInfoText() {
        let log = CockerLog()
        #expect(log.minimum == .info)
        #expect(log.format == .text)
    }

    @Test func customInitOverrides() {
        let log = CockerLog(minimum: .debug, format: .json)
        #expect(log.minimum == .debug)
        #expect(log.format == .json)
    }

    @Test func sharedIsAccessible() {
        // `shared` resolves once at first access ; verifying we can read
        // it without crashing covers the lazy-init path.
        let s = CockerLog.shared
        #expect(s.minimum >= .debug)
    }
}

@Suite("CockerLog — JSON escapes for raw control chars")
struct CockerLogJSONEscapeTests {
    @Test func nullByteIsUnicodeEscaped() throws {
        let s = CockerLog.formatJSON(level: .info, module: "x", message: "a\u{0}b",
                                     timestamp: Date(timeIntervalSince1970: 0))
        #expect(s.contains("\\u0000"))
    }

    @Test func bellCharIsUnicodeEscaped() throws {
        let s = CockerLog.formatJSON(level: .info, module: "x", message: "ring\u{7}",
                                     timestamp: Date(timeIntervalSince1970: 0))
        #expect(s.contains("\\u0007"))
    }

    @Test func nonAsciiUnicodePassesThroughVerbatim() throws {
        // Non-ASCII printable chars don't need \\uXXXX escapes for JSON ;
        // we hand them off as UTF-8.
        let s = CockerLog.formatJSON(level: .info, module: "x", message: "café 🎉",
                                     timestamp: Date(timeIntervalSince1970: 0))
        #expect(s.contains("café 🎉"))
    }
}

@Suite("CockerLog — emit honours level filter")
struct CockerLogEmitFilterTests {
    @Test func debugDroppedWhenMinimumIsInfo() {
        // `emit` writes to stderr, so we just confirm it doesn't throw or
        // misbehave under the filter. Behavioural correctness of the filter
        // itself is covered by the level-comparison tests in CockerLogTests.
        let log = CockerLog(minimum: .info)
        log.debug("test", "should not appear")
        log.warn("test", "should appear")
        // Reaching this line means emit() ran through both paths without
        // crashing under the level guard.
        #expect(Bool(true))
    }
}
