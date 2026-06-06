import Foundation

// Pure log-file rotation policy. Doesn't open any file descriptor itself —
// callers ask `shouldRotate(file:)` and, if yes, hand the file off via
// `rotate(file:keep:)`. Lets us unit-test the rotation without touching a
// running daemon's stderr.
//
// The convention mirrors logrotate's classic `keep N copies` behaviour :
//   cockerd.log         (current, can be written to)
//   cockerd.log.1       (most recent rotated)
//   cockerd.log.2       (older)
//   ...
//   cockerd.log.<keep>  (oldest still on disk)
//
// rotate() shifts every `.N` down to `.N+1`, drops anything past `keep`,
// renames the current to `.1`, and truncates the current path.

public enum LogRotator {

    /// Should the file at `url` be rotated given a size threshold ?
    public static func shouldRotate(file url: URL,
                                    maxBytes: UInt64,
                                    fs: FileManager = .default) -> Bool {
        guard let attrs = try? fs.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.uint64Value >= maxBytes
    }

    /// Perform the rotation : shift .N → .N+1 up to `keep`, then mv current
    /// to .1, then truncate current. Errors are swallowed (best-effort —
    /// losing rotation is preferable to crashing the daemon).
    public static func rotate(file url: URL,
                              keep: Int,
                              fs: FileManager = .default) throws {
        guard keep > 0 else { return }

        // Drop anything past keep (e.g. cockerd.log.<keep+1> if it exists).
        for i in stride(from: keep, through: keep, by: 1) {
            let stale = url.appendingPathExtension("\(i)")
            try? fs.removeItem(at: stale)
        }

        // Shift down: .(keep-1) → .keep, .(keep-2) → .(keep-1), …, .1 → .2
        for i in stride(from: keep - 1, through: 1, by: -1) {
            let src = url.appendingPathExtension("\(i)")
            let dst = url.appendingPathExtension("\(i + 1)")
            try? fs.removeItem(at: dst)
            if fs.fileExists(atPath: src.path) {
                try? fs.moveItem(at: src, to: dst)
            }
        }

        // Current → .1
        let dot1 = url.appendingPathExtension("1")
        try? fs.removeItem(at: dot1)
        if fs.fileExists(atPath: url.path) {
            try fs.moveItem(at: url, to: dot1)
        }

        // Recreate the current as empty so the daemon can append on its
        // next write — the existing fd will fail until the daemon reopens
        // it (responsibility of the caller).
        fs.createFile(atPath: url.path, contents: nil, attributes: nil)
    }
}
