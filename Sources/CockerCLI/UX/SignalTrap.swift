import Foundation

// Reliable Ctrl-C for the interactive commands.
//
// The previous shape looked right and was subtly broken:
//
//     let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
//     signal(SIGINT, SIG_IGN)
//
// `SIG_IGN` disarms the kernel's default "terminate the process" action, so
// from that moment the ONLY thing that can stop the command is the handler.
// But the handler was posted on the MAIN queue, and `compose watch` spends
// its rebuilds inside `await composeUp(...)` on that same queue. During a
// rebuild the queue never drains, the handler never runs, and Ctrl-C does
// strictly nothing — the user hammers it and has to reach for `kill -9`.
//
// Two changes make it dependable:
//
//   1. The signal source runs on its own serial queue, so it fires no
//      matter what the main queue is doing.
//   2. A second Ctrl-C exits immediately. Graceful teardown can itself be
//      slow (it asks the daemon to stop containers), and a user pressing
//      Ctrl-C twice means "stop now" — honouring that is the difference
//      between a responsive tool and one that feels hung.
//
// `SIGTERM` and `SIGHUP` get the same treatment: a closing terminal window
// or a `kill` should tear down as cleanly as Ctrl-C does.
final class SignalTrap: @unchecked Sendable {
    /// Dedicated queue : never blocked by application work.
    private static let queue = DispatchQueue(label: "cocker.signal-trap")

    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var firing = false
    /// Process exit, injectable so tests can drive the handler without
    /// killing the test runner. Defaults to the real thing.
    private let exitProcess: @Sendable (Int32) -> Void

    /// Signals that should trigger a graceful shutdown.
    private static let trapped: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    init(exitProcess: @escaping @Sendable (Int32) -> Void = { Darwin.exit($0) }) {
        self.exitProcess = exitProcess
    }

    /// What a delivered signal should do, given whether one is already
    /// being handled. Pure decision logic, split out so the behaviour can
    /// be tested without a real signal and a real process exit.
    enum Action: Equatable {
        /// First signal, no teardown to run : leave with 128+SIGINT.
        case exitNow(code: Int32)
        /// First signal : restore the terminal, then run teardown.
        case gracefulShutdown
        /// Another signal arrived while shutting down : leave immediately.
        case forceExit(code: Int32)
    }

    static func decide(alreadyFiring: Bool, hasTeardown: Bool) -> Action {
        if alreadyFiring { return .forceExit(code: 130) }
        return hasTeardown ? .gracefulShutdown : .exitNow(code: 130)
    }

    /// Install the handlers.
    ///
    /// - Parameters:
    ///   - onFirst: synchronous, must be fast. Restores the terminal so the
    ///     shell is usable even if teardown then hangs.
    ///   - onTeardown: the slow part (asking the daemon to stop things).
    ///     Skipped entirely on a second signal.
    func install(onFirst: @escaping @Sendable () -> Void,
                 onTeardown: (@Sendable () async -> Void)? = nil) {
        for signum in Self.trapped {
            let source = DispatchSource.makeSignalSource(signal: signum, queue: Self.queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }

                self.lock.lock()
                let alreadyFiring = self.firing
                self.firing = true
                self.lock.unlock()

                switch Self.decide(alreadyFiring: alreadyFiring,
                                   hasTeardown: onTeardown != nil) {
                case .forceExit(let code):
                    // Second Ctrl-C : the user is telling us the graceful
                    // path is taking too long.
                    self.exitProcess(code)
                case .exitNow(let code):
                    // Terminal first : whatever happens next, the shell is sane.
                    onFirst()
                    self.exitProcess(code)
                case .gracefulShutdown:
                    onFirst()
                    let done = self.exitProcess
                    Task.detached(priority: .userInitiated) {
                        await onTeardown?()
                        done(0)
                    }
                }
            }
            source.resume()

            // Only disarm the default action AFTER the source is live, so a
            // signal arriving in between still terminates the process rather
            // than vanishing into a gap where nothing handles it.
            signal(signum, SIG_IGN)

            lock.lock(); sources.append(source); lock.unlock()
        }
    }

    /// Remove the handlers and restore default behaviour. Used when a
    /// command finishes normally and hands the terminal back.
    func uninstall() {
        lock.lock()
        let current = sources
        sources.removeAll()
        firing = false
        lock.unlock()

        for source in current { source.cancel() }
        for signum in Self.trapped { signal(signum, SIG_DFL) }
    }

    deinit { uninstall() }
}
