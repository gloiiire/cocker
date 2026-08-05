import Foundation
import Darwin

// PID-file lifecycle, factored out of the daemon main() and the
// `cocker daemon …` subcommands so the same code path is unit-testable
// against a temp directory. cockerd writes the file at boot, removes it
// in its SIGTERM/SIGINT handlers ; the CLI reads it to know whether the
// daemon is already running and what process to signal.

public enum PIDFile {

    /// Read the contents of a PID file and parse it as a positive integer.
    /// Returns nil if the file is missing, empty, malformed, or non-positive.
    public static func read(_ url: URL) -> pid_t? {
        guard let raw = try? String(contentsOf: url) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(trimmed), pid > 0 else { return nil }
        return pid
    }

    /// Atomically write our own PID into `url`. Used by cockerd at startup.
    public static func writeSelf(to url: URL) throws {
        try "\(getpid())\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write an arbitrary PID — useful for tests.
    public static func write(_ pid: pid_t, to url: URL) throws {
        try "\(pid)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Remove the PID file ; no-op if it's already absent.
    public static func clear(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Is the process represented by `pid` still alive ? Uses kill(pid, 0)
    /// which sends no actual signal but lets the kernel surface ESRCH (no
    /// such process) or EPERM (process exists but we lack permission). Both
    /// the "alive" and "exists but unreachable" cases are treated as alive.
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Convenience : read + check. Returns the live PID, or nil if the file
    /// is missing OR points to a dead process (in which case the caller
    /// usually wants to clear() the stale file).
    ///
    /// - Warning: fine for *reporting* (`daemon status`, "which pid do I
    ///   signal"), useless as an admission gate. It samples a value that is
    ///   briefly wrong during any restart: between one daemon exiting and
    ///   its successor writing the file, this reads a dead pid and says
    ///   "nobody is running". Two daemons started a second apart both passed
    ///   this check and both ran on the same root. Use `acquire` to gate.
    public static func liveFromFile(_ url: URL) -> pid_t? {
        guard let pid = read(url), isAlive(pid) else { return nil }
        return pid
    }

    /// Exclusive run-lock on the pid file. Returns the held descriptor, or
    /// nil when another process already owns it.
    ///
    /// The lock is what makes this safe, not the number in the file. `flock`
    /// is owned by a live file descriptor and released by the kernel when
    /// that process dies — there is no window where a stale value reads as
    /// "free", which is exactly how two daemons ended up sharing one root:
    /// Homebrew's LaunchAgent has `KeepAlive`, so killing the daemon makes
    /// launchd respawn it within a second, and `cocker daemon restart` then
    /// started a second one because the file still named the process it had
    /// just killed.
    ///
    /// **The caller must keep the returned descriptor for the process
    /// lifetime.** Closing it drops the lock. It is deliberately never
    /// closed on the success path — the kernel reclaims it at exit, which
    /// also covers `SIGKILL`, where no cleanup code of ours would run.
    ///
    /// The pid is still written, for humans and for `daemon stop`.
    public static func acquire(_ url: URL) -> Int32? {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        // Truncate + rewrite rather than atomically replacing the file: an
        // atomic write swaps in a new inode, and the lock lives on the inode
        // we are holding. The replacement would be unlocked.
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let line = "\(getpid())\n"
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        return fd
    }
}
