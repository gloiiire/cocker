import Foundation
import Testing
@testable import CockerCore
@testable import CockerDaemon

/// `compose logs` stamps each line with the service name so interleaved
/// output stays readable. The prefix used to be applied per *stream event*,
/// but console output arrives in arbitrary chunks: one line often spans
/// several events, and one event often carries several lines. That produced
/// output like
///
///     [api] API-LOG-7[api]
///
/// — the name stamped mid-line, and the remainder of the line left bare.
@Suite("compose logs service prefix")
struct ComposeLogPrefixTests {

    @Test func singleLineGetsOnePrefix() {
        #expect(DaemonServer.prefixEachLine("hello\n", with: "api") == "[api] hello\n")
    }

    /// A chunk carrying several lines must stamp every one of them, not
    /// just the first.
    @Test func everyLineInAChunkIsPrefixed() {
        #expect(DaemonServer.prefixEachLine("one\ntwo\nthree\n", with: "api")
                == "[api] one\n[api] two\n[api] three\n")
    }

    /// Container consoles emit CRLF. The CR belongs to the line it ends and
    /// must not start a new prefixed line.
    @Test func crlfLineEndingsArePreservedVerbatim() {
        #expect(DaemonServer.prefixEachLine("API-LOG-7\r\n", with: "api") == "[api] API-LOG-7\r\n")
        #expect(DaemonServer.prefixEachLine("a\r\nb\r\n", with: "api") == "[api] a\r\n[api] b\r\n")
    }

    /// No trailing newline means no trailing empty prefix.
    @Test func noPrefixIsAddedAfterTheFinalNewline() {
        #expect(DaemonServer.prefixEachLine("done\n", with: "web") == "[web] done\n")
        #expect(!DaemonServer.prefixEachLine("done\n", with: "web").hasSuffix("[web] "))
    }

    @Test func unterminatedLineIsStillPrefixed() {
        #expect(DaemonServer.prefixEachLine("no newline", with: "api") == "[api] no newline")
    }

    /// Blank lines are real output and keep their prefix.
    @Test func blankLinesArePrefixed() {
        #expect(DaemonServer.prefixEachLine("\n", with: "api") == "[api] \n")
    }

    @Test func emptyInputStaysEmpty() {
        #expect(DaemonServer.prefixEachLine("", with: "api") == "")
    }

    /// Feeding a split line through LineBuffer then prefixing yields one
    /// clean line — the end-to-end shape of the bug.
    @Test func splitLineReassemblesToASinglePrefixedLine() {
        let buf = LineBuffer()
        var out = ""
        for chunk in ["API-LOG-", "7\r", "\n"] {
            for line in buf.feed(chunk) { out += DaemonServer.prefixEachLine(line, with: "api") }
        }
        #expect(out == "[api] API-LOG-7\r\n")
    }
}
