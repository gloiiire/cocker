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
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

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
    /// Reading starts immediately, but nothing is *sent* until `markReady()`.
    /// Both halves of that matter, and each was learned the hard way on
    /// hardware:
    ///
    ///  - Sending early breaks the exec outright. A burst of `.execInput`
    ///    frames reaching the daemon before the exec exists made the vsock
    ///    connect fail with ECONNRESET; toggling the pump off made the
    ///    identical command succeed.
    ///  - Reading late loses input. Piped stdin can hit EOF before the
    ///    daemon reports readiness, and anything not already read is gone.
    ///
    /// So the reader runs from the start and the AsyncStream holds the bytes
    /// until the daemon says its side is up.
    ///
    /// The blocking `read(2)` lives on a GCD queue — a keystroke may not come
    /// for hours and must never park a Swift cooperative-executor thread —
    /// while one long-lived Task drains the stream, keeping chunks ordered on
    /// a single connection.
    func startPump(socketPath: String = IPCClient.defaultSocketPath) {
        let session = sessionID
        let (chunks, feed) = AsyncStream.makeStream(of: ExecInputRequest.self)

        sendTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.waitUntilReady()
            if Task.isCancelled { return }
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

    /// The daemon's vsock is up; release the buffered stdin.
    func markReady() {
        lock.lock()
        guard !ready else { lock.unlock(); return }
        ready = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    private func waitUntilReady() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if ready || stopped {
                lock.unlock()
                continuation.resume()
                return
            }
            readyWaiters.append(continuation)
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let task = sendTask
        sendTask = nil
        let waiters = readyWaiters
        readyWaiters.removeAll()
        lock.unlock()
        // Unpark the sender before cancelling, or it stays blocked forever.
        for waiter in waiters { waiter.resume() }
        guard !alreadyStopped else { return }
        task?.cancel()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}
