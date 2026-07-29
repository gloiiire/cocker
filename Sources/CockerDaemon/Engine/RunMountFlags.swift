import Foundation

// BuildKit `RUN` flags : `--mount=...`, `--network=...`, `--security=...`.
//
// `RUN --mount=type=cache,target=/root/.cache uv sync` is the standard
// way to keep a package cache between builds, and every modern Python /
// Rust / Node Dockerfile uses it. Cocker used to forward the whole line
// to `/bin/sh`, which then tried to execute `--mount=type=cache,...` as
// a program. The step failed, the diagnostic scrolled past, and the
// build looked like it had silently done nothing.
//
// Cocker has no BuildKit mount backend. Rather than pretend, we strip
// the flags, run the actual command, and report what was ignored:
//
//   - `type=cache`  : purely an optimisation. Dropping it makes the
//     build slower, never wrong — the command still runs and still
//     downloads what it needs.
//   - `type=tmpfs`  : the target simply stays a normal directory.
//     Behaviour is equivalent for anything that just writes scratch
//     files there.
//   - `type=bind` / `type=secret` / `type=ssh` : these CHANGE what the
//     command can see. Silently dropping them would produce a wrong
//     image, so those fail the build with an explicit message instead.
//
// `--network` and `--security` get the same treatment : they are far
// rarer, but leaking either to the shell reproduces the exact bug this
// file exists to fix.
public enum RunMountFlags {

    public struct Parsed: Equatable {
        /// The command with every leading `--mount=...` flag removed.
        public let command: String
        /// Mount types that were dropped (in order, duplicates kept).
        public let ignoredTypes: [String]
        /// Mount types that cannot be dropped without changing the result.
        public let unsupportedTypes: [String]
    }

    /// Leading BuildKit RUN flags other than `--mount`, and whether
    /// dropping one can change the result.
    ///
    /// `--network=none` DOES change what the command can do (it must not
    /// reach the network), so silently running with networking would be
    /// wrong. `--network=default` and `--security=insecure` match what
    /// cocker already does, so they are simply noted.
    private static let otherFlags = ["--network", "--security"]

    /// Same list without the leading dashes : that is the form stored in
    /// `ignoredTypes`, so messages can tell a flag from a mount type.
    /// Derived rather than duplicated, so adding a flag cannot desync it.
    private static var otherFlagNames: [String] {
        otherFlags.map { String($0.dropFirst(2)) }
    }

    /// Split leading `--mount=...` flags off a RUN instruction.
    ///
    /// Only *leading* flags are considered : BuildKit requires them
    /// before the command, and anything later belongs to the user's
    /// command line (`docker run --mount=...` inside a RUN, for example).
    public static func parse(_ raw: String) -> Parsed {
        var rest = Substring(raw).drop { $0.isWhitespace }
        var ignored: [String] = []
        var unsupported: [String] = []

        while true {
            // `--mount` guards against `--mountains` ; the same guard is
            // needed here, otherwise a command starting with a merely
            // similar flag (`--security-opt`, `--network-manager-cli`) got
            // swallowed and the build failed on a line it should not touch.
            if let other = otherFlags.first(where: { isFlag($0, at: rest) }) {
                let (value, remainder) = takeFlagValue(rest, flag: other)
                // Anything that is not the default behaviour changes what
                // the command observes, so refuse rather than mislead.
                let normalised = value.lowercased()
                let name = String(other.dropFirst(2))
                if normalised.isEmpty || normalised == "default" || normalised == "sandbox" {
                    ignored.append(name)
                } else {
                    unsupported.append("\(name)=\(normalised)")
                }
                rest = remainder
                continue
            }
            guard rest.hasPrefix("--mount") else { break }
            // Accept both `--mount=type=cache,...` and `--mount type=cache,...`.
            var spec = rest.dropFirst("--mount".count)
            if spec.first == "=" || spec.first == " " {
                spec = spec.dropFirst()
            } else if !spec.isEmpty && !spec.first!.isWhitespace {
                // `--mountains ...` is not a mount flag.
                break
            }
            spec = spec.drop { $0.isWhitespace }

            // The spec runs to the next unquoted whitespace.
            var value = ""
            var quote: Character?
            var idx = spec.startIndex
            while idx < spec.endIndex {
                let ch = spec[idx]
                if let q = quote {
                    if ch == q { quote = nil } else { value.append(ch) }
                } else if ch == "\"" || ch == "'" {
                    quote = ch
                } else if ch.isWhitespace {
                    break
                } else {
                    value.append(ch)
                }
                idx = spec.index(after: idx)
            }

            let type = mountType(of: value)
            if requiresRealMount(type) {
                unsupported.append(type)
            } else {
                ignored.append(type)
            }

            rest = spec[idx...].drop { $0.isWhitespace }
        }

        return Parsed(
            command: String(rest),
            ignoredTypes: ignored,
            unsupportedTypes: unsupported
        )
    }

    /// True when `input` starts with exactly `flag`, followed by `=`,
    /// whitespace, or nothing. Prevents `--security-opt` from matching
    /// `--security`, which would consume a flag meant for the command.
    private static func isFlag(_ flag: String, at input: Substring) -> Bool {
        guard input.hasPrefix(flag) else { return false }
        guard let next = input.dropFirst(flag.count).first else { return true }
        return next == "=" || next.isWhitespace
    }

    /// Consume `--flag=value` (or `--flag value`) and return the value
    /// plus what remains after it.
    private static func takeFlagValue(
        _ input: Substring, flag: String
    ) -> (value: String, rest: Substring) {
        var s = input.dropFirst(flag.count)
        if s.first == "=" || s.first == " " { s = s.dropFirst() }
        s = s.drop { $0.isWhitespace }
        let value = s.prefix { !$0.isWhitespace }
        let rest = s.dropFirst(value.count).drop { $0.isWhitespace }
        return (String(value), rest)
    }

    /// `type=` value of a mount spec. BuildKit defaults to `bind`.
    private static func mountType(of spec: String) -> String {
        for field in spec.split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1)
            // Generated Dockerfiles sometimes upper-case the key. BuildKit
            // accepts it, so matching case-sensitively silently treated
            // `TYPE=CACHE` as the default (bind) and failed the build.
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "type" {
                return parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            }
        }
        return "bind"
    }

    /// Types whose absence changes what the command can see, so dropping
    /// them would silently build a wrong image.
    private static func requiresRealMount(_ type: String) -> Bool {
        ["bind", "secret", "ssh"].contains(type)
    }

    /// One-line explanation shown in the build log when flags are dropped.
    ///
    /// `failure` already separates mounts from other flags ; the warning
    /// has to do the same. Saying "mount(s)" and "cache/tmpfs" for an
    /// ignored `--network=default` named something absent from the line,
    /// sending the reader looking for a mount that was never there.
    public static func warning(for types: [String]) -> String {
        let unique = Array(NSOrderedSet(array: types)) as? [String] ?? types
        let flags = unique.filter { otherFlagNames.contains($0) }
        let mounts = unique.filter { !otherFlagNames.contains($0) }
        var parts: [String] = []
        if !mounts.isEmpty {
            parts.append(
                "ignoring unsupported BuildKit mount(s): "
                + "\(mounts.joined(separator: ", ")) — the command still runs, "
                + "only the cache/tmpfs optimisation is lost")
        }
        if !flags.isEmpty {
            parts.append(
                "ignoring BuildKit flag(s): "
                + "\(flags.map { "--\($0)" }.joined(separator: ", ")) — the "
                + "requested value already matches cocker's behaviour")
        }
        return parts.joined(separator: " ; ")
    }

    /// Error message for mounts that cannot be dropped safely.
    public static func failure(for types: [String]) -> String {
        let unique = Array(NSOrderedSet(array: types)) as? [String] ?? types
        // `--network=none` and `--mount=type=bind` are both refused, but
        // for different reasons and with different fixes — a single
        // message mentioning "mount type" and suggesting COPY was actively
        // misleading for the network case.
        let mounts = unique.filter { !$0.contains("=") }
        let others = unique.filter { $0.contains("=") }
        var parts: [String] = []
        if !mounts.isEmpty {
            parts.append(
                "RUN --mount type '\(mounts.joined(separator: ", "))' is not "
                + "supported by cocker. Unlike type=cache, dropping it would "
                + "change what the command sees and silently produce a wrong "
                + "image. Rewrite the step using COPY, or pass the value with "
                + "ARG/ENV.")
        }
        for flag in others {
            parts.append(
                "RUN --\(flag) is not supported by cocker. Ignoring it would "
                + "run the command under different conditions than the "
                + "Dockerfile asks for. Remove the flag if the step does not "
                + "actually depend on it.")
        }
        return parts.joined(separator: " ")
    }
}
