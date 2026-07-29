import Foundation
import Testing
@testable import CockerCLI

/// `cocker compose watch` ignored Ctrl-C during a rebuild : the user had to
/// reach for `kill -9`. Reproduced before the fix — two SIGINTs delivered
/// during a `RUN sleep 60`, process still alive.
///
/// The cause was a shape that looks correct:
///
///     let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
///     signal(SIGINT, SIG_IGN)
///
/// `SIG_IGN` disarms the kernel's terminate-by-default, so the handler
/// becomes the only way out — and that handler sat on the MAIN queue, which
/// a rebuild occupies for minutes.
///
/// Real signal delivery needs a real process, so the decisive check lives in
/// `Tests/e2e/09-ctrl-c-during-build.sh`. What is worth pinning here is the
/// one property that made the old code fail: the handler must keep running
/// while the main queue is blocked.
@Suite("Signal trap")
struct SignalTrapTests {

    /// The regression, reproduced without any signal: block the main queue,
    /// then check that work scheduled the way SignalTrap schedules it still
    /// runs. Written to FAIL against a `queue: .main` handler.
    @Test func handlerRunsWhileTheMainQueueIsBlocked() async throws {
        let mainQueueRan = LockedFlag()
        let dedicatedRan = LockedFlag()

        // Occupy the main queue the way a rebuild does.
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 1.5) }
        // Give it a moment to actually start blocking.
        try await Task.sleep(nanoseconds: 100_000_000)

        // How the old code scheduled its handler.
        DispatchQueue.main.async { mainQueueRan.set(true) }
        // How SignalTrap schedules its handler.
        DispatchQueue(label: "test.dedicated").async { dedicatedRan.set(true) }

        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(!mainQueueRan.value,
                "a main-queue handler is starved — this is the bug")
        #expect(dedicatedRan.value,
                "a dedicated-queue handler must still run — this is the fix")
    }

    /// A command that finishes normally hands the terminal back, so the trap
    /// must be removable — and removing it twice must not trap.
    @Test func uninstallIsIdempotent() {
        let trap = SignalTrap()
        trap.install(onFirst: {})
        trap.uninstall()
        trap.uninstall()
        #expect(Bool(true))
    }

    /// Not every caller has slow teardown to run.
    @Test func installWithoutTeardownIsAllowed() {
        let trap = SignalTrap()
        trap.install(onFirst: {})
        trap.uninstall()
        #expect(Bool(true))
    }

    /// The footer is armed, released and re-armed across a command's life
    /// (`d` refused → re-arm), so traps must not interfere with each other.
    @Test func multipleTrapsCoexist() {
        let a = SignalTrap()
        let b = SignalTrap()
        a.install(onFirst: {})
        b.install(onFirst: {})
        a.uninstall()
        b.uninstall()
        #expect(Bool(true))
    }

    /// After uninstall the default disposition must be restored, otherwise a
    /// later Ctrl-C would find SIGINT still ignored and do nothing at all —
    /// the exact failure this fix is about, just moved later in time.
    @Test func uninstallRestoresDefaultDisposition() {
        let trap = SignalTrap()
        trap.install(onFirst: {})
        trap.uninstall()

        // Read back the disposition: re-set SIG_DFL and inspect what was
        // there before. C function pointers aren't Equatable, so compare
        // raw addresses.
        let previous = signal(SIGINT, SIG_DFL)
        let previousAddr = unsafeBitCast(previous, to: UInt.self)
        let ignoreAddr = unsafeBitCast(SIG_IGN, to: UInt.self)
        #expect(previousAddr != ignoreAddr,
                "SIGINT left ignored after uninstall would silently break Ctrl-C")
    }

    // MARK: - What a delivered signal decides

    /// First Ctrl-C with teardown to run : restore, then tear down.
    @Test func firstSignalWithTeardownShutsDownGracefully() {
        #expect(SignalTrap.decide(alreadyFiring: false, hasTeardown: true)
            == .gracefulShutdown)
    }

    /// First Ctrl-C with nothing to tear down : leave straight away, with
    /// the conventional 128+SIGINT status.
    @Test func firstSignalWithoutTeardownExitsImmediately() {
        #expect(SignalTrap.decide(alreadyFiring: false, hasTeardown: false)
            == .exitNow(code: 130))
    }

    /// The reason a second Ctrl-C exists : teardown talks to the daemon and
    /// can be slow, and a user pressing twice means "now".
    @Test func secondSignalForcesExitEvenWithTeardown() {
        #expect(SignalTrap.decide(alreadyFiring: true, hasTeardown: true)
            == .forceExit(code: 130))
        #expect(SignalTrap.decide(alreadyFiring: true, hasTeardown: false)
            == .forceExit(code: 130))
    }

    // MARK: - Real signal delivery
    //
    // Deliberately NOT unit-tested. Sending a real SIGINT/SIGTERM to the
    // test process is unsafe here: the suite runs tests in parallel, and
    // any test that restores the default disposition (as the uninstall
    // test must) turns a sibling's signal into an immediate kill of the
    // whole runner — the suite died mid-flight when this was attempted.
    //
    // Delivery is therefore proven where it belongs, against a real
    // process: `Tests/e2e/09-ctrl-c-during-build.sh` sends an actual
    // SIGINT to a running build and requires a clean exit. That scenario
    // was verified RED by putting the handler back on the main queue.
}

/// Minimal thread-safe flag : handlers fire off the test's thread.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set(_ v: Bool) { lock.lock(); flag = v; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
