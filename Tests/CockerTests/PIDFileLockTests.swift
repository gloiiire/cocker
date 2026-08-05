import Foundation
import Darwin
import Testing
@testable import CockerCore

/// Two cockerd processes ran on one root, both printing "Ready", both
/// writing the same `state.json`.
///
/// The admission check read the pid out of the file and asked whether that
/// process was alive — a value that is briefly wrong during any restart.
/// Homebrew's LaunchAgent has `KeepAlive`, so killing the daemon makes
/// launchd respawn it within a second; `cocker daemon restart` then started
/// a second one because the file still named the process it had just
/// killed, so the check passed.
///
/// `flock` has no such window: the lock belongs to a live descriptor and the
/// kernel releases it on exit, `SIGKILL` included.
@Suite("PID file run lock")
struct PIDFileLockTests {

    private func scratchFile() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pidlock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cockerd.pid")
    }

    @Test func theFirstAcquirerGetsTheLock() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fd = try #require(PIDFile.acquire(url))
        defer { close(fd) }
        #expect(fd >= 0)
    }

    /// The regression, directly.
    @Test func aSecondAcquirerIsRefusedWhileTheFirstHolds() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try #require(PIDFile.acquire(url))
        defer { close(first) }
        #expect(PIDFile.acquire(url) == nil, "two holders — this is the bug")
    }

    /// Releasing must actually release, or a clean restart would be refused
    /// forever and the cure would be worse than the disease.
    @Test func theLockIsAvailableAgainOnceReleased() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try #require(PIDFile.acquire(url))
        close(first)
        let second = try #require(PIDFile.acquire(url))
        close(second)
    }

    @Test func theHoldersPidIsReadableFromTheFile() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fd = try #require(PIDFile.acquire(url))
        defer { close(fd) }
        #expect(PIDFile.read(url) == getpid())
    }

    /// A leftover pid from a dead process must not block a fresh start —
    /// that is the failure mode of a lock done wrong, and it would leave a
    /// machine unable to start cockerd after a crash.
    @Test func aStalePidInTheFileDoesNotBlockAcquisition() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A pid that is almost certainly not running, written by no one.
        try PIDFile.write(999_999, to: url)
        let fd = try #require(PIDFile.acquire(url),
                              "a stale pid must not look like a live holder")
        defer { close(fd) }
        #expect(PIDFile.read(url) == getpid(), "the file should now name us")
    }

    /// Rewriting in place rather than atomically replacing matters: an
    /// atomic write swaps in a new inode and `flock` lives on the inode, so
    /// the replacement would be unlocked and a second daemon could take it.
    @Test func theLockSurvivesTheHoldersOwnPidWrite() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fd = try #require(PIDFile.acquire(url))
        defer { close(fd) }
        // Same inode, still locked.
        #expect(PIDFile.acquire(url) == nil)
    }

    /// `liveFromFile` stays fine for reporting — `daemon status` and
    /// `daemon stop` need a pid to show and to signal. It just must not be
    /// what decides whether a daemon may start.
    @Test func liveFromFileStillReportsTheHolder() throws {
        let url = try scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fd = try #require(PIDFile.acquire(url))
        defer { close(fd) }
        #expect(PIDFile.liveFromFile(url) == getpid())
    }
}
