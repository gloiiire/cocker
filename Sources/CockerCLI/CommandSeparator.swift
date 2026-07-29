import Foundation

// Docker-compatible handling of the POSIX `--` separator.
//
// `docker run alpine -- sh -c 'echo hi'` runs `sh -c 'echo hi'` : cobra
// strips the terminator before handing the rest to the container. Swift
// ArgumentParser's `.captureForPassthrough` keeps it instead, so the
// separator reached the guest as argv[0] and cocker-init died with
// `execvp --: No such file or directory` (exit 127).
//
// The rule is narrow on purpose : only a `--` in *leading* position is a
// separator. Anything later belongs to the user's command
// (`sh -c 'git log --'`, `find . -- -name x`) and must be preserved
// byte for byte.
public enum CommandSeparator {

    /// Drop a single leading `--`.
    ///
    /// - A separator only ever appears first ; the image/container name is
    ///   parsed as its own argument before this runs.
    /// - Only ONE is dropped : `-- --` means "the command is literally
    ///   `--`", which is the caller's business, not ours.
    /// - Everything else, including later `--`, is returned untouched.
    public static func strippingLeadingSeparator(_ command: [String]) -> [String] {
        guard command.first == "--" else { return command }
        return Array(command.dropFirst())
    }
}
