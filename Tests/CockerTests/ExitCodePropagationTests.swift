import Foundation
import Testing
import CockerCore
@testable import CockerCLI
@testable import CockerDaemon

/// Cocker used to report success no matter what actually happened :
///
///  1. `cocker run img false` exited 0 — the foreground path streamed logs
///     and returned without ever reading the container's code.
///  2. `GET /containers/{id}/wait` returned a hardcoded `StatusCode: 0`
///     immediately, so `docker run`, `compose up --abort-on-container-exit`
///     and every CI runner saw unconditional success.
///  3. `cocker exec c false` exited 0 — the daemon reports completion as a
///     `.status` event carrying `exit:<n>`, and every call site dropped it.
///
/// These cover the parsing and plumbing that carry the real code out. The
/// end-to-end behaviour needs a booted VM and lives in `Tests/e2e`.
@Suite("Exit-code propagation")
struct ExitCodePropagationTests {

    // MARK: - The `exit:<n>` status marker

    @Test func parsesAPlainExitMarker() {
        #expect(ExitMarker.parse("exit:0") == 0)
        #expect(ExitMarker.parse("exit:1") == 1)
        #expect(ExitMarker.parse("exit:127") == 127)
    }

    /// The guest may leave the marker's trailing newline attached.
    @Test func tolerateTrailingWhitespace() {
        #expect(ExitMarker.parse("exit:3\n") == 3)
        #expect(ExitMarker.parse("exit:42  ") == 42)
        #expect(ExitMarker.parse("exit:7\r\n") == 7)
    }

    /// Other status payloads (pull progress and the like) must pass through
    /// untouched rather than being mistaken for a completion.
    @Test func ignoresNonExitStatusPayloads() {
        #expect(ExitMarker.parse("Pulling from library/alpine") == nil)
        #expect(ExitMarker.parse("") == nil)
        #expect(ExitMarker.parse("exit:") == nil)
        #expect(ExitMarker.parse("exit:notanumber") == nil)
        #expect(ExitMarker.parse("exited:1") == nil)
    }

    /// The CLI and the Docker-API server both read this marker back. They
    /// share one parser precisely so they can't disagree — this pins the box
    /// to it so a future local copy shows up as a failure.
    @Test func theBoxUsesTheSharedParser() {
        for raw in ["exit:0", "exit:1\n", "exit:255", "not-an-exit", "exit:x"] {
            let box = ExitStatusBox()
            let consumed = box.consume(statusPayload: raw)
            #expect(consumed == (ExitMarker.parse(raw) != nil), "disagreement on \(raw)")
            if let expected = ExitMarker.parse(raw) { #expect(box.code == expected) }
        }
    }

    // MARK: - The box

    @Test func defaultsToSuccessUntilToldOtherwise() {
        #expect(ExitStatusBox().code == 0)
    }

    @Test func consumeReportsWhetherItSwallowedTheEvent() {
        let box = ExitStatusBox()
        #expect(box.consume(statusPayload: "exit:5") == true)
        #expect(box.code == 5)
        // A non-exit status is left for the caller to handle.
        #expect(box.consume(statusPayload: "downloading") == false)
        #expect(box.code == 5)
    }

    @Test func lastExitMarkerWins() {
        let box = ExitStatusBox()
        box.consume(statusPayload: "exit:1")
        box.consume(statusPayload: "exit:0")
        #expect(box.code == 0)
    }

    // MARK: - IPC contract

    @Test func waitIsAKnownRequestType() {
        #expect(IPCRequestType(rawValue: "wait") == .wait)
    }

    @Test func waitResponseRoundTrips() throws {
        for code: Int32 in [0, 1, 126, 127, 137, 255] {
            let encoded = try JSONEncoder().encode(WaitResponse(exitCode: code))
            let decoded = try JSONDecoder().decode(WaitResponse.self, from: encoded)
            #expect(decoded.exitCode == code)
        }
    }

    /// `.wait` reuses `ContainerIDRequest`, so a request built by the CLI has
    /// to survive the daemon's decode.
    @Test func waitRequestCarriesTheContainerID() throws {
        let request = try IPCRequest(type: .wait, payload: ContainerIDRequest(id: "abc123"))
        #expect(request.type == .wait)
        let decoded = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
        #expect(decoded.id == "abc123")
    }
}
