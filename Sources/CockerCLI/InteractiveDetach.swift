import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Interactive-mode keystroke listener for `cocker compose up` (and
/// later `cocker run` without `-d`). Matches Docker Compose v2's UX :
/// while logs stream to the terminal, a footer hint lets the user
/// press `d` to detach (containers keep running) or Ctrl-C to tear
/// the project down.
///
/// We deliberately don't draw a sticky footer at the bottom of the
/// screen — that requires constant ANSI redraw, mangles `tee` /
/// pipe redirection, and breaks under multiplexers (`tmux`, `screen`,
/// VS Code's terminal). A one-line hint at startup is enough.
///
/// Mechanics :
///   1. Put stdin in cbreak/no-echo via `termios` so a single key
///      press is delivered without the user hitting Enter.
///   2. Spawn a background Task that reads stdin byte-by-byte.
///   3. On `d` → call the detach handler, which cancels the streaming
///      task and lets the CLI exit cleanly.
///   4. On Ctrl-C (`0x03`) → fall through to the normal SIGINT handler
///      so the existing project teardown logic runs.
///   5. Always restore the previous `termios` state in `defer`, even
///      on crash — otherwise the user's shell stays in raw mode after
///      cocker exits and they're stuck typing blind.
struct InteractiveDetach {
    /// Wraps a streaming task with detach-on-`d`. Returns true if the
    /// user detached, false if the stream finished on its own. Throws
    /// any error the streaming task throws.
    ///
    /// `stream` runs the actual subscription. The closure is called
    /// once with a `DetachToken` it can check ; canceling the token
    /// short-circuits the loop. The simpler pattern (cancel the Task)
    /// also works ; the token exists so callers that swallow
    /// `CancellationError` can still tell "did I get canceled because
    /// the user pressed `d`, or because of an error?".
    static func run(
        prompt: String = "Attached. Press \u{1B}[1md\u{1B}[0m to detach (containers keep running), Ctrl-C to stop.",
        stream: @escaping (DetachToken) async throws -> Void
    ) async throws -> Bool {
        // Only install raw-mode TTY handling when stdin is actually a
        // terminal. Piped or redirected stdin (`cocker compose up |
        // tee log`) skips this entirely so we don't choke on EOF.
        guard isatty(fileno(stdin)) != 0 else {
            try await stream(DetachToken())
            return false
        }

        var original = termios()
        guard tcgetattr(fileno(stdin), &original) == 0 else {
            try await stream(DetachToken())
            return false
        }
        var raw = original
        // cbreak mode : disable canonical line-buffering and echo, but
        // KEEP ISIG so Ctrl-C still raises SIGINT. We don't want raw
        // raw (`cfmakeraw`) — that disables signal handling and we'd
        // have to re-implement Ctrl-C ourselves.
        raw.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
        _ = tcsetattr(fileno(stdin), TCSANOW, &raw)
        defer {
            _ = tcsetattr(fileno(stdin), TCSANOW, &original)
        }

        print("\n" + prompt)

        let token = DetachToken()

        let keyTask = Task.detached(priority: .userInitiated) {
            let stdinFd = fileno(stdin)
            var buf = [UInt8](repeating: 0, count: 1)
            while !Task.isCancelled && !token.isCanceled {
                let n = read(stdinFd, &buf, 1)
                if n <= 0 { break }
                let c = buf[0]
                if c == UInt8(ascii: "d") || c == UInt8(ascii: "D") {
                    token.cancel(reason: .userDetached)
                    print("\nDetached. Containers continue in the background.")
                    print("→ Tail logs:   cocker logs -f <name>")
                    print("→ Stop all:    cocker compose down")
                    return
                }
                // Pass-through Ctrl-C (0x03) is handled by the kernel
                // via ISIG → existing SIGINT handler. We just consume
                // and ignore any other byte.
            }
        }

        do {
            try await stream(token)
            keyTask.cancel()
            return token.reason == .userDetached
        } catch {
            keyTask.cancel()
            // If the stream got CancellationError because the user
            // pressed `d`, swallow it and report clean detach.
            if token.reason == .userDetached, error is CancellationError {
                return true
            }
            throw error
        }
    }
}

/// Cooperative cancellation token for the detach flow. Wraps a single
/// `Bool` + reason behind a lock so concurrent reads from the streaming
/// task and writes from the key-press task are race-free.
final class DetachToken: @unchecked Sendable {
    enum Reason { case none, userDetached, streamEnded }

    private let lock = NSLock()
    private var _canceled = false
    private var _reason: Reason = .none

    var isCanceled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _canceled
    }

    var reason: Reason {
        lock.lock(); defer { lock.unlock() }
        return _reason
    }

    func cancel(reason: Reason = .userDetached) {
        lock.lock(); defer { lock.unlock() }
        _canceled = true
        if _reason == .none { _reason = reason }
    }
}
