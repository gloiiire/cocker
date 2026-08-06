import Foundation

extension UX {
    /// Says out loud that a flag was accepted and will not be honoured.
    ///
    /// 1.0 commitment #1 is "a flag that can't be honoured says so instead of
    /// being ignored", and fourteen flags were breaking it: declared, listed
    /// in `--help`, accepted on the command line, and read by nobody.
    /// `--read-only` was the sharpest — a hardening flag whose user believes
    /// they have an unwritable root filesystem, measured writable.
    ///
    /// Why a warning and not an error: the README promises for the whole 1.x
    /// line that a flag may be added, or deprecated with a warning for a full
    /// minor cycle, but never silently repurposed. Turning these into hard
    /// failures now would break scripts that pass them today. So they warn,
    /// their `help:` text says the same thing, and the ones worth building
    /// get their own issues.
    ///
    /// Goes to stderr: a warning must not land in output somebody is parsing.
    enum IgnoredFlag {
        /// - Parameters:
        ///   - flag: exactly as the user typed it, e.g. `--read-only`.
        ///   - effect: what actually happens instead. Concrete, not "may not
        ///     work" — the reader needs to know whether to stop.
        static func warn(_ flag: String, _ effect: String) {
            let line = UX.TTY.paint("⚠ \(flag) is accepted but not honoured", .warn)
                + " — " + effect + "\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
