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
    ///   2. `$COCKER_DAEMON_BIN` env var (set by SUFFIX=-dev wrappers so
    ///      `cocker-dev daemon start` doesn't accidentally spawn a
    ///      prod-rooted `/opt/homebrew/bin/cockerd` — the wrapper points
    ///      it explicitly at the dev daemon binary)
    ///   3. `name` next to `siblingTo` (the binary that invoked us)
    ///   4. each prefix in `prefixes` (defaults to `standardPrefixes`)
    ///   5. each directory in `path` (defaults to $PATH)
    /// Returns the first hit, or nil. The `prefixes` and `path` parameters
    /// are injectable so tests can isolate the lookup from the host
    /// filesystem (otherwise an installed cockerd in /opt/homebrew/bin
    /// short-circuits every test).
    public static func find(name: String,
                            explicit: String? = nil,
                            siblingTo: String? = nil,
                            prefixes: [String]? = nil,
                            path: String? = nil,
                            fs: FileManager = .default,
                            env: [String: String]? = nil) -> String? {

        if let explicit, fs.isExecutableFile(atPath: explicit) {
            return explicit
        }

        // Env-var override — only honored for "cockerd". Side-by-side dev
        // installs (./install.sh with SUFFIX=-dev) ship a wrapper that
        // exports COCKER_DAEMON_BIN so the CLI's daemon subcommands target
        // the matching dev daemon binary instead of falling through to
        // whichever cockerd happens to sit in /opt/homebrew/bin.
        let environ = env ?? ProcessInfo.processInfo.environment
        if name == "cockerd",
           let envBin = environ["COCKER_DAEMON_BIN"],
           !envBin.isEmpty,
           fs.isExecutableFile(atPath: envBin) {
            return envBin
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
