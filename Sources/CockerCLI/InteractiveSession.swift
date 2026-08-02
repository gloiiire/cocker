import Foundation
import CockerCore

/// Host side of an interactive exec: full raw mode on the local terminal, and
/// a pump that streams stdin to the daemon while the response stream carries
/// output back.
///
/// Until now `-i` only drained stdin into a one-shot blob before the command
/// started, and `-t` set a flag the host never acted on. `cocker exec -it c
/// sh` printed a warning saying typed input would not reach the container.
/// The guest has always been able to do this — `exec_listener.c` allocates a
/// PTY and runs a bidirectional relay — so everything missing was here.
///
/// Stdin travels on its own IPC connection. The daemon's per-connection loop
/// can't read a second frame while it is streaming the exec's output, so
/// sharing one connection would deadlock.
final class InteractiveSession: @unchecked Sendable {

    /// Identifies this exec to the daemon across both connections.
    let sessionID = UUID().uuidString

    private let lock = NSLock()
    private var original = termios()
    private var rawActive = false
    private var stopped = false
    private var sendTask: Task<Void, Never>?

    // MARK: - Terminal

    /// Whether an interactive session is possible at all: we need a real
    /// terminal on stdin to put into raw mode.
    static var stdinIsTerminal: Bool { isatty(fileno(stdin)) == 1 }

    /// Current terminal geometry, so the guest's PTY starts at the right size
    /// instead of openpty's 80x24 default.
    static func windowSize() -> (rows: Int, cols: Int)? {
        var ws = winsize()
        guard ioctl(fileno(stdout), UInt(TIOCGWINSZ), &ws) == 0,
              ws.ws_row > 0, ws.ws_col > 0 else { return nil }
        return (Int(ws.ws_row), Int(ws.ws_col))
    }

    /// Full raw mode, not just ICANON/ECHO off.
    ///
    /// `ISIG` matters: with it left on, Ctrl-C would raise SIGINT in the
    /// *CLI* and kill the client while the container kept running. Docker
    /// forwards the keystroke instead and lets the container's own terminal
    /// discipline turn it into a signal, which is what a user pressing Ctrl-C
    /// inside `sh` expects.
    func enterRawMode() {
        lock.lock(); defer { lock.unlock() }
        guard !rawActive, isatty(fileno(stdin)) == 1 else { return }
        guard tcgetattr(fileno(stdin), &original) == 0 else { return }
        var raw = original
        raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~UInt(OPOST)
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
        // Block until at least one byte, no inter-byte timer: a keystroke is
        // forwarded the moment it happens.
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        if tcsetattr(fileno(stdin), TCSAFLUSH, &raw) == 0 { rawActive = true }
    }

    /// Idempotent, and safe to call from a signal handler path.
    func restore() {
        lock.lock(); defer { lock.unlock() }
        guard rawActive else { return }
        _ = tcsetattr(fileno(stdin), TCSAFLUSH, &original)
        rawActive = false
    }

    // MARK: - Stdin pump

    /// Stream stdin to the daemon until EOF or `stop()`.
    ///
    /// Two halves on purpose. A GCD queue owns the blocking `read(2)` — a
    /// keystroke may not come for hours and that must never park a Swift
    /// cooperative-executor thread. A single long-lived Task owns the
    /// sending, draining an AsyncStream so chunks reach the daemon strictly
    /// in order on one connection.
    ///
    /// An earlier version blocked the reader on a semaphore waiting for a
    /// per-chunk Task. Under load that Task wasn't always scheduled before
    /// the timeout, so input was silently dropped — caught on hardware, not
    /// by any unit test.
    func startPump(socketPath: String = IPCClient.defaultSocketPath) {
        let session = sessionID
        let (chunks, feed) = AsyncStream.makeStream(of: ExecInputRequest.self)

        sendTask = Task.detached(priority: .userInitiated) {
            let client = IPCClient(socketPath: socketPath)
            for await request in chunks {
                guard let frame = try? IPCRequest(type: .execInput, payload: request) else { continue }
                // A dropped chunk isn't worth tearing the session down over;
                // the output stream is the authority on whether it's alive.
                _ = try? await client.send(frame)
            }
            await client.disconnect()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                if self?.isStopped ?? true { break }
                let n = read(fileno(stdin), &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }  // EOF or error
                feed.yield(ExecInputRequest(sessionID: session, data: Data(buffer.prefix(n))))
            }
            // Local stdin closed. Tell the daemon to half-close the vsock so
            // a child blocked in read() sees EOF instead of hanging.
            feed.yield(ExecInputRequest(sessionID: session, eof: true))
            feed.finish()
        }
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let task = sendTask
        sendTask = nil
        lock.unlock()
        guard !alreadyStopped else { return }
        task?.cancel()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}
