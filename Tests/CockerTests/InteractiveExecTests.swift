import Foundation
import Testing
import ArgumentParser
import CockerCore
@testable import CockerCLI

/// `cocker exec -it c sh` printed "typed input will not reach the container"
/// and dropped every keystroke. `cocker compose exec -it svc sh` was worse —
/// neither `-i` nor `-t` was declared on that command, so it failed at *parse*
/// time, before the missing plumbing even mattered.
///
/// The guest could always do this: `exec_listener.c` allocates a PTY and runs
/// a bidirectional relay. Everything missing was on the host.
@Suite("Interactive exec")
struct InteractiveExecTests {

    // MARK: - The flags that didn't exist

    /// The regression that matters most: `-it` is the muscle-memory form, and
    /// it has to survive ArgumentParser's short-flag combining.
    @Test func composeExecAcceptsCombinedIT() throws {
        let parsed = try CockerCLI.parseAsRoot(["compose", "exec", "-it", "web", "sh"])
        let command = try #require(parsed as? ComposeExecCommand)
        #expect(command.interactive)
        #expect(command.tty)
        #expect(command.service == "web")
        #expect(command.command == ["sh"])
    }

    @Test func composeExecAcceptsTheLongForms() throws {
        let parsed = try CockerCLI.parseAsRoot(
            ["compose", "exec", "--interactive", "--tty", "api", "bash"])
        let command = try #require(parsed as? ComposeExecCommand)
        #expect(command.interactive)
        #expect(command.tty)
    }

    /// `-T` is Docker's explicit opt-out and must still parse alongside.
    @Test func composeExecStillAcceptsDashT() throws {
        let parsed = try CockerCLI.parseAsRoot(["compose", "exec", "-T", "web", "ls"])
        let command = try #require(parsed as? ComposeExecCommand)
        #expect(command.noTTY)
        #expect(!command.tty)
    }

    @Test func execAcceptsCombinedIT() throws {
        let parsed = try CockerCLI.parseAsRoot(["exec", "-it", "web", "sh"])
        let command = try #require(parsed as? ExecCommand)
        #expect(command.interactive)
        #expect(command.tty)
    }

    /// The command after the container must survive intact, flags and all —
    /// this is why the argument uses `.captureForPassthrough`.
    @Test func theCommandKeepsItsOwnFlags() throws {
        let parsed = try CockerCLI.parseAsRoot(["exec", "-it", "web", "sh", "-c", "echo hi"])
        let command = try #require(parsed as? ExecCommand)
        #expect(command.command == ["sh", "-c", "echo hi"])
    }

    // MARK: - Session identity and wire contract

    @Test func eachSessionGetsItsOwnID() {
        let a = InteractiveSession()
        let b = InteractiveSession()
        #expect(!a.sessionID.isEmpty)
        #expect(a.sessionID != b.sessionID)
    }

    @Test func inputRequestRoundTrips() throws {
        let payload = Data("ls -la\n".utf8)
        let request = try IPCRequest(type: .execInput,
                                     payload: ExecInputRequest(sessionID: "s1", data: payload))
        #expect(request.type == .execInput)
        let decoded = try JSONDecoder().decode(ExecInputRequest.self, from: request.payload)
        #expect(decoded.sessionID == "s1")
        #expect(decoded.data == payload)
        #expect(decoded.eof == false)
    }

    /// EOF is a distinct signal, not an empty chunk: the daemon half-closes
    /// the vsock so a child blocked on read() stops waiting.
    @Test func eofIsDistinctFromAnEmptyChunk() throws {
        let eof = try JSONDecoder().decode(
            ExecInputRequest.self,
            from: try IPCRequest(type: .execInput,
                                 payload: ExecInputRequest(sessionID: "s1", eof: true)).payload)
        #expect(eof.eof)
        #expect(eof.data == nil)
    }

    @Test func execInputIsAKnownRequestType() {
        #expect(IPCRequestType(rawValue: "execInput") == .execInput)
    }

    /// The session id and geometry have to survive the exec request itself,
    /// or the daemon can't match the side channel to the exec.
    @Test func execConfigCarriesSessionAndGeometry() throws {
        var config = ExecConfig(containerID: "abc", command: ["sh"])
        config.sessionID = "session-1"
        config.tty = true
        config.rows = 40
        config.cols = 120

        let encoded = try JSONEncoder().encode(ExecRequest(config: config))
        let decoded = try JSONDecoder().decode(ExecRequest.self, from: encoded).config
        #expect(decoded.sessionID == "session-1")
        #expect(decoded.rows == 40)
        #expect(decoded.cols == 120)
        #expect(decoded.tty)
    }

    /// An older CLI sends none of these; the daemon must fall back rather
    /// than fail to decode.
    @Test func legacyExecConfigStillDecodes() throws {
        let legacy = #"{"containerID":"abc","command":["sh"],"interactive":false,"tty":false,"env":{}}"#
        let decoded = try JSONDecoder().decode(ExecConfig.self, from: Data(legacy.utf8))
        #expect(decoded.sessionID == nil)
        #expect(decoded.rows == nil)
        #expect(decoded.cols == nil)
    }

    // MARK: - Terminal handling

    /// Under `swift test` stdin is not a terminal, so the session must
    /// degrade quietly rather than mangling a pipe. This is what makes
    /// `echo x | cocker exec -i c cat` keep working.
    @Test func degradesWhenStdinIsNotATerminal() throws {
        try #require(!InteractiveSession.stdinIsTerminal,
                     "expected a non-tty stdin under swift test")
        // Raw mode must be a no-op — nothing to enter, nothing to corrupt.
        let session = InteractiveSession()
        session.enterRawMode()
        session.restore()
        // And the callers gate on exactly this flag before minting a session.
        #expect(!InteractiveSession.stdinIsTerminal)
    }

    /// A half-restored terminal is the worst failure mode an interactive
    /// command has, so restore is idempotent and safe to call unpaired.
    @Test func restoreIsIdempotent() {
        let session = InteractiveSession()
        session.restore()
        session.restore()
        session.enterRawMode()
        session.restore()
        session.restore()
    }

    @Test func stopIsIdempotent() {
        let session = InteractiveSession()
        session.stop()
        session.stop()
    }
}
