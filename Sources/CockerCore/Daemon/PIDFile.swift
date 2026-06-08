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
    public static func liveFromFile(_ url: URL) -> pid_t? {
        guard let pid = read(url), isAlive(pid) else { return nil }
        return pid
    }
}
