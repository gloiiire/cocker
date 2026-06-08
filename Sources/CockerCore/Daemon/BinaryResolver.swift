import Foundation

// Pure look-up logic for `cocker daemon start` to find a cockerd binary
// without relying on the calling shell's PATH. Extracted so the candidate
// chain (--binary → sibling → /opt/homebrew → /usr/local → $PATH) can be
// tested with a temp filesystem.

public enum BinaryResolver {

    /// Common Homebrew + system install prefixes we check after the sibling
    /// directory. Order matters : we look at Apple Silicon Homebrew before
    /// the Intel one before the more conservative `/usr/local`.
    public static let standardPrefixes: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// Find an executable named `name`. Tries (in order) :
    ///   1. `explicit`, if it's a real executable file
    ///   2. `name` next to `siblingTo` (the binary that invoked us)
    ///   3. each prefix in `prefixes` (defaults to `standardPrefixes`)
    ///   4. each directory in `path` (defaults to $PATH)
    /// Returns the first hit, or nil. The `prefixes` and `path` parameters
    /// are injectable so tests can isolate the lookup from the host
    /// filesystem (otherwise an installed cockerd in /opt/homebrew/bin
    /// short-circuits every test).
    public static func find(name: String,
                            explicit: String? = nil,
                            siblingTo: String? = nil,
                            prefixes: [String]? = nil,
                            path: String? = nil,
                            fs: FileManager = .default) -> String? {

        if let explicit, fs.isExecutableFile(atPath: explicit) {
            return explicit
        }

        if let siblingTo {
            let dir = URL(fileURLWithPath: siblingTo).deletingLastPathComponent().path
            let candidate = "\(dir)/\(name)"
            if fs.isExecutableFile(atPath: candidate) { return candidate }
        }

        for prefix in prefixes ?? standardPrefixes {
            let candidate = "\(prefix)/\(name)"
            if fs.isExecutableFile(atPath: candidate) { return candidate }
        }

        let pathStr = path ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathStr.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fs.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
