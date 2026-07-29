import Foundation
import Testing
@testable import CockerCore
@testable import CockerDaemon

/// `VMRuntime.logs` feeds three separate consumers: `cocker logs`,
/// `cocker attach`, and `compose logs`. Its two sources disagree by nature —
/// the in-memory ring holds raw console chunks (CRLF-terminated), the JSON
/// log stores one record per line with the terminator stripped — and for a
/// while that difference was left to each caller to handle.
///
/// Predictably, callers got it wrong. `compose logs` ran consecutive backlog
/// lines together:
///
///     [proj_api_1] INFO: startup complete[proj_api_1]
///
/// and `attach`, which forwards the same backlog untouched, had the same
/// latent bug. The producer now guarantees the invariant instead, so no
/// consumer has to remember.
@Suite("VMRuntime backlog line termination")
struct VMRuntimeLogTerminationTests {

    private func event(_ s: String, stream: StreamEvent.Stream = .stdout) -> StreamEvent {
        StreamEvent(stream: stream, data: s)
    }

    @Test func unterminatedLineGetsANewline() {
        #expect(VMRuntime.terminated(event("INFO: startup complete")).data
                == "INFO: startup complete\n")
    }

    @Test func alreadyTerminatedLineIsUntouched() {
        #expect(VMRuntime.terminated(event("already\n")).data == "already\n")
    }

    /// The case a Character-level check gets wrong: "\r\n" is a single
    /// grapheme cluster, so `hasSuffix("\n")` is false and a naive
    /// implementation appends a second newline, double-spacing the output.
    @Test func crlfIsRecognisedAsTerminated() {
        #expect(VMRuntime.terminated(event("console line\r\n")).data == "console line\r\n",
                "CRLF already ends the line — must not gain a second newline")
    }

    /// A lone CR does not end a line, so it must still be terminated.
    @Test func bareCarriageReturnIsStillTerminated() {
        #expect(VMRuntime.terminated(event("progress\r")).data == "progress\r\n")
    }

    @Test func emptyEventIsLeftAlone() {
        #expect(VMRuntime.terminated(event("")).data == "")
    }

    /// A multi-line chunk that already ends cleanly keeps its shape.
    @Test func multiLineChunkKeepsItsShape() {
        #expect(VMRuntime.terminated(event("a\nb\n")).data == "a\nb\n")
        #expect(VMRuntime.terminated(event("a\nb")).data == "a\nb\n")
    }

    @Test func streamAndTimestampSurvive() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let out = VMRuntime.terminated(StreamEvent(stream: .stderr, data: "boom", timestamp: ts))
        #expect(out.stream == .stderr)
        #expect(out.timestamp == ts)
        #expect(out.data == "boom\n")
    }

    /// The end-to-end shape of the bug: consecutive backlog entries must not
    /// run into each other once concatenated, which is exactly what a
    /// consumer does when it writes them out in order.
    @Test func consecutiveBacklogEntriesDoNotRunTogether() {
        let backlog = ["INFO: started", "INFO: ready", "INFO: serving"]
            .map { VMRuntime.terminated(event($0)).data }
            .joined()
        #expect(backlog == "INFO: started\nINFO: ready\nINFO: serving\n")
        #expect(backlog.split(separator: "\n").count == 3)
    }
}
