import Foundation

// ASCII banner + colored UI primitives for the cockerd boot screen and the
// `cocker` no-args welcome. Output stays plain text when isatty(stderr) is
// false so piping to a file gives clean greppable content.
//
// Colors are 16-color ANSI ; we don't use 256-color or truecolor to keep
// compatibility with bare terminals.

public enum ANSIStyle {
    public static let reset = "\u{1B}[0m"
    public static let bold  = "\u{1B}[1m"
    public static let dim   = "\u{1B}[2m"

    // Basic 16-color (kept for compatibility — used by Prometheus + log code).
    public static let red     = "\u{1B}[31m"
    public static let green   = "\u{1B}[32m"
    public static let yellow  = "\u{1B}[33m"
    public static let blue    = "\u{1B}[34m"
    public static let magenta = "\u{1B}[35m"
    public static let cyan    = "\u{1B}[36m"
    public static let white   = "\u{1B}[37m"

    public static let brightCyan = "\u{1B}[96m"
    public static let brightGreen = "\u{1B}[92m"

    // Warm palette via xterm 256-color — used by the user-facing banner +
    // help screens. "team couleur chaude". Modern terminals (Terminal.app,
    // iTerm, Ghostty, kitty, alacritty…) all support 256 ; we only need
    // bare-terminal fallback for piping into files, in which case Banner
    // already strips all escapes when stdout/err isn't a tty.
    public static let warmOrange  = "\u{1B}[38;5;208m"  // ●  primary brand
    public static let warmAmber   = "\u{1B}[38;5;214m"  //    section headers
    public static let warmGold    = "\u{1B}[38;5;220m"  //    user-typed commands
    public static let warmMustard = "\u{1B}[38;5;178m"  //    options + env vars
    public static let warmPeach   = "\u{1B}[38;5;216m"  //    soft accents
    public static let warmRed     = "\u{1B}[38;5;203m"  //    errors / warnings
}

public enum Banner {

    /// Raw ASCII art for the cocker CLI — 5 lines, fits in 80 columns.
    public static let logo: String = """
       ____               __
      / __ \\____  _____  / /_____  _____
     / /  / / __ \\/ ___/ / //_/ _ \\/ ___/
    / /__/ / /_/ / /__  / ,< /  __/ /
    \\____/\\____/\\___/  /_/|_|\\___/_/
    """

    /// Daemon-specific logo — same font with a trailing `d` so users can
    /// tell at a glance whether they're looking at the CLI help or the
    /// daemon's help / boot screen.
    public static let logoDaemon: String = """
       ____               __                  __
      / __ \\____  _____  / /_____  _____  ____/ /
     / /  / / __ \\/ ___/ / //_/ _ \\/ ___/ / __  /
    / /__/ / /_/ / /__  / ,< /  __/ /    / /_/ /
    \\____/\\____/\\___/  /_/|_|\\___/_/    \\__,_/
    """

    /// Whether stderr is a real terminal — used to decide if we should send
    /// color codes. Pipes / redirected logs get plain text.
    public static var stderrIsTTY: Bool {
        isatty(fileno(stderr)) == 1
    }

    /// Build the cockerd boot screen as a string. Pure (no I/O) so the format
    /// is testable. The caller decides whether to colour it (tty) or not.
    public static func cockerdBanner(version: String,
                                     rootDir: String,
                                     ipcSocket: String,
                                     dockerSocket: String,
                                     dnsPort: UInt16,
                                     colored: Bool) -> String {
        let orange = colored ? ANSIStyle.warmOrange : ""
        let amber  = colored ? ANSIStyle.warmAmber : ""
        let gold   = colored ? ANSIStyle.warmGold : ""
        let dim    = colored ? ANSIStyle.dim : ""
        let bold   = colored ? ANSIStyle.bold : ""
        let reset  = colored ? ANSIStyle.reset : ""

        var out = "\n"
        out += orange + logoDaemon + reset + "\n"
        out += "      \(dim)container engine daemon · v\(version)\(reset)\n"
        out += "      \(dim)https://github.com/gloiiire/cocker\(reset)\n\n"

        out += "  \(bold)\(amber)Listeners\(reset)\n"
        out += "    \(orange)●\(reset) IPC          unix://\(ipcSocket)\n"
        out += "    \(orange)●\(reset) Docker API   unix://\(dockerSocket)\n"
        out += "    \(orange)●\(reset) DNS          0.0.0.0:\(dnsPort) (UDP + TCP)\n\n"

        out += "  \(bold)\(amber)Root\(reset)         \(rootDir)\n\n"

        out += "  \(orange)✓\(reset) \(bold)Ready.\(reset) "
        out += "\(dim)Daemon is running. Press \(reset)\(bold)Ctrl-C\(reset)\(dim) to stop.\(reset)\n"
        out += "  \(dim)Open another terminal and try: \(reset)\(gold)cocker run alpine echo hello\(reset)\n\n"

        return out
    }

    /// Pure version of the `cocker` no-args welcome. Used by the CLI to prepend
    /// the help text.
    public static func cockerWelcome(version: String, colored: Bool) -> String {
        let orange = colored ? ANSIStyle.warmOrange : ""
        let dim    = colored ? ANSIStyle.dim : ""
        let reset  = colored ? ANSIStyle.reset : ""

        var out = "\n"
        out += orange + logo + reset + "\n"
        out += "      \(dim)container engine for Apple Silicon · v\(version)\(reset)\n"
        out += "      \(dim)https://github.com/gloiiire/cocker\(reset)\n\n"
        return out
    }

    /// Beautified `cockerd --help` text. The previous plain-text version got
    /// dropped on the user with "c'est pas beau" — fair. This applies the
    /// same palette as the boot banner : bright cyan logo, bold cyan section
    /// headers, bright green for commands you'd actually type, dim for the
    /// descriptions and shell prefixes.
    public static func cockerdHelp(version: String, colored: Bool) -> String {
        let orange  = colored ? ANSIStyle.warmOrange : ""
        let amber   = colored ? ANSIStyle.warmAmber : ""
        let gold    = colored ? ANSIStyle.warmGold : ""
        let mustard = colored ? ANSIStyle.warmMustard : ""
        let dim     = colored ? ANSIStyle.dim : ""
        let bold    = colored ? ANSIStyle.bold : ""
        let reset   = colored ? ANSIStyle.reset : ""

        func header(_ s: String) -> String { "\n  \(bold)\(amber)\(s)\(reset)\n" }
        func cmd(_ s: String)    -> String { "\(gold)\(s)\(reset)" }
        func opt(_ s: String)    -> String { "\(mustard)\(s)\(reset)" }
        func d(_ s: String)      -> String { "\(dim)\(s)\(reset)" }
        func star(_ s: String)   -> String { "\(orange)\(s)\(reset)" }

        var out = "\n"
        out += orange + logoDaemon + reset + "\n"
        out += "      \(dim)container engine daemon · v\(version)\(reset)\n"
        out += "      \(dim)https://github.com/gloiiire/cocker\(reset)\n"

        // Pad helper for the USAGE / RUNNING tables.
        func row(_ rawCmd: String, _ desc: String, recommended: Bool = false) -> String {
            let visible = "$ " + rawCmd + (recommended ? "  ★" : "")
            let pad = max(0, 30 - visible.count)
            let marker = recommended ? " \(star("★"))" : ""
            return "    \(d("$")) \(cmd(rawCmd))\(marker)\(String(repeating: " ", count: pad))\(d(desc))\n"
        }

        out += header("USAGE")
        out += row("cocker daemon start", "Background, returns to shell — easy way", recommended: true)
        out += row("cockerd",             "Run in foreground (Ctrl-C to stop)")
        out += row("cockerd setup",       "Download + configure the Linux kernel for VMs")

        out += header("OPTIONS")
        out += "    \(opt("--root <path>"))         \(d("Data directory (default: ~/.cocker)"))\n"
        out += "    \(opt("--socket <path>"))       \(d("Unix socket path (default: ~/.cocker/cocker.sock)"))\n"
        out += "    \(opt("--version, -v"))         \(d("Show version"))\n"
        out += "    \(opt("--help, -h"))            \(d("Show this help"))\n"

        // Inner table for the COMMANDS section — wider padding so longer
        // strings like "cocker daemon restart" stay on one line.
        func srow(_ rawCmd: String, _ desc: String) -> String {
            let visible = "$ " + rawCmd
            let pad = max(0, 30 - visible.count)
            return "    \(d("$")) \(cmd(rawCmd))\(String(repeating: " ", count: pad))\(d(desc))\n"
        }

        out += header("DAEMON LIFECYCLE")
        out += "\n    \(bold)Via the cocker CLI \(star("★")) \(reset)\(dim)— recommended :\(reset)\n\n"
        out += srow("cocker daemon start",   "Spawn in background, return to shell")
        out += srow("cocker daemon status",  "PID, uptime, log path, socket reachable?")
        out += srow("cocker daemon logs -f", "Follow the log")
        out += srow("cocker daemon stop",    "Graceful shutdown (SIGTERM)")
        out += srow("cocker daemon restart", "Stop + start")

        out += "\n    \(bold)Auto-start at login\(reset) \(dim)(launchd) :\(reset)\n\n"
        out += srow("brew services start cocker", "")
        out += srow("brew services stop cocker",  "")

        out += "\n    \(bold)Debugging\(reset) \(dim)(foreground, see logs live) :\(reset)\n\n"
        out += srow("cockerd", "Banner + listeners + \"Ready\", Ctrl-C to stop")

        out += header("ENVIRONMENT")
        out += "    \(opt("COCKER_ROOT"))           \(d("Override data directory"))\n"
        out += "    \(opt("COCKER_SOCKET"))         \(d("Override IPC socket path"))\n"
        out += "    \(opt("COCKER_LOG_LEVEL"))      \(d("debug | info | warn | error (default: info)"))\n"
        out += "    \(opt("COCKER_LOG_FORMAT"))     \(d("text | json"))\n"
        out += "    \(opt("COCKER_TRACE"))          \(d("stderr — emit OTLP-compatible JSON spans"))\n"
        out += "    \(opt("COCKER_DNS_PORT"))       \(d("Override DNS server port (default: 5300)"))\n"

        out += header("ENTITLEMENTS")
        out += "    \(orange)com.apple.security.virtualization\(reset)\n\n"
        out += "    \(dim)cockerd must be code-signed with this entitlement to start VMs :\(reset)\n"
        out += "    \(d("$")) \(cmd("codesign -s 'Your Dev ID' \\"))\n"
        out += "    \(dim)           --entitlements entitlements/cockerd.entitlements \\\(reset)\n"
        out += "    \(dim)           .build/release/cockerd\(reset)\n"

        return out
    }

    /// Beautified `cocker --help` text. We replace ArgumentParser's default
    /// flat subcommand list with a hand-grouped layout (containers / images
    /// / network / orchestration / daemon) and the same warm palette as the
    /// rest of the UI.
    public static func cockerCLIHelp(version: String, colored: Bool) -> String {
        let orange  = colored ? ANSIStyle.warmOrange : ""
        let amber   = colored ? ANSIStyle.warmAmber : ""
        let gold    = colored ? ANSIStyle.warmGold : ""
        let mustard = colored ? ANSIStyle.warmMustard : ""
        let dim     = colored ? ANSIStyle.dim : ""
        let bold    = colored ? ANSIStyle.bold : ""
        let reset   = colored ? ANSIStyle.reset : ""

        func header(_ s: String) -> String { "\n  \(bold)\(amber)\(s)\(reset)\n" }
        func d(_ s: String) -> String { "\(dim)\(s)\(reset)" }
        func star() -> String { "\(orange)★\(reset)" }

        // Right-padded command name (gold) + dim description. `colW` is the
        // visible width before the description starts.
        func row(_ name: String, _ desc: String, recommended: Bool = false, colW: Int = 16) -> String {
            let marker = recommended ? " \(star())" : ""
            let visible = name + (recommended ? "  ★" : "")
            let pad = max(0, colW - visible.count)
            return "    \(gold)\(name)\(reset)\(marker)\(String(repeating: " ", count: pad))\(d(desc))\n"
        }

        // Shell-style "$ command" row for the GET STARTED quick examples.
        func shell(_ cmd: String, _ desc: String, recommended: Bool = false) -> String {
            let marker = recommended ? " \(star())" : ""
            let visible = "$ " + cmd + (recommended ? "  ★" : "")
            let pad = max(0, 36 - visible.count)
            return "    \(d("$")) \(gold)\(cmd)\(reset)\(marker)\(String(repeating: " ", count: pad))\(d(desc))\n"
        }

        var out = "\n"
        out += orange + logo + reset + "\n"
        out += "      \(dim)container engine for Apple Silicon · v\(version)\(reset)\n"
        out += "      \(dim)Docker-compatible CLI — alternative to docker on macOS\(reset)\n"
        out += "      \(dim)https://github.com/gloiiire/cocker\(reset)\n"

        out += header("USAGE")
        out += "    \(d("$")) \(gold)cocker\(reset) \(mustard)<command>\(reset) \(d("[options]"))\n"
        out += "    \(d("$")) \(gold)cocker\(reset) \(mustard)<command>\(reset) \(gold)-h\(reset)  \(d("command-specific help"))\n"

        out += header("GET STARTED")
        out += shell("cocker daemon start",         "Start the cockerd background process", recommended: true)
        out += shell("cocker pull alpine:latest",   "Download an image")
        out += shell("cocker run alpine echo hi",   "Run a command in a new container")
        out += shell("cocker ps",                   "List running containers")

        out += header("DAEMON")
        out += row("daemon",   "Manage the cockerd background process", recommended: true)

        out += header("CONTAINERS")
        out += row("run",       "Run a command in a new container")
        out += row("ps, ls",    "List containers")
        out += row("start",     "Start one or more stopped containers")
        out += row("stop",      "Stop one or more running containers")
        out += row("kill",      "Send a signal to running containers")
        out += row("restart",   "Restart one or more containers")
        out += row("pause",     "Pause processes in container(s)")
        out += row("unpause",   "Unpause processes in container(s)")
        out += row("rm",        "Remove one or more containers")
        out += row("rename",    "Rename a container")
        out += row("exec",      "Run a command in a running container")
        out += row("attach",    "Attach to a running container")
        out += row("logs",      "Fetch the logs of a container")
        out += row("inspect",   "Show detailed container info")
        out += row("top",       "Display running processes in a container")
        out += row("stats",     "Display resource usage statistics")
        out += row("port",      "List port mappings for a container")
        out += row("cp",        "Copy files between container and host")
        out += row("diff",      "Inspect changes on a container's filesystem")
        out += row("commit",    "Create a new image from a container's changes")
        out += row("update",    "Update configuration of one or more containers")

        out += header("IMAGES")
        out += row("pull",      "Pull an image from a registry")
        out += row("push",      "Push an image to a registry")
        out += row("build",     "Build an image from a Dockerfile")
        out += row("images",    "List images")
        out += row("rmi",       "Remove one or more images")
        out += row("tag",       "Tag an image with a new name")
        out += row("save",      "Save image(s) to a tar archive")
        out += row("load",      "Load an image from a tar archive")
        out += row("export",    "Export a container's filesystem to a tarball")
        out += row("import",    "Import a tarball as an image")
        out += row("buildx",    "Multi-platform build (cross-arch)")

        out += header("NETWORK & VOLUMES")
        out += row("network",   "Manage networks")
        out += row("volume",    "Manage volumes")

        out += header("ORCHESTRATION")
        out += row("compose",   "Define and run multi-container applications")
        out += row("swarm",     "Manage Swarm (cluster mode)")
        out += row("stack",     "Deploy stacks to a Swarm")
        out += row("service",   "Manage Swarm services")
        out += row("node",      "Manage Swarm nodes")

        out += header("ICLOUD (macOS)")
        out += row("icloud",     "Inspect & control iCloud-aware behavior (status, prefetch, cache-clear)")

        out += header("SHELL INTEGRATION")
        out += row("shell-completion", "Generate bash/zsh/fish completion script (native TAB completion)")
        out += row("autocomplete",     "Install rich popup spec for Kiro CLI / Fig (install, status)")

        out += header("SYSTEM & AUTH")
        out += row("system, s",  "Manage Cocker (df, prune, info, events)")
        out += row("info",       "Display system-wide information")
        out += row("version",    "Show the Cocker version (or use `-v`)")
        out += row("context",    "Manage daemon connection contexts")
        out += row("login",      "Log in to a container registry")
        out += row("logout",     "Log out from a container registry")

        out += "\n  \(d("Run"))  \(gold)cocker <command> -h\(reset)  \(d("for command-specific help."))\n\n"

        return out
    }

    /// Take a plain ArgumentParser help string (e.g. the output of
    /// `MyCommand.helpMessage()`) and re-render it with the warm palette so
    /// every subcommand looks like the top-level ones. Pure — no I/O.
    ///
    /// Patterns we recognise :
    ///   OVERVIEW: / USAGE: / ARGUMENTS: / OPTIONS: / SUBCOMMANDS: / FLAGS:
    ///        → bold amber section headers
    ///   `  -x` or `  --flag` at start of line → mustard for the flag
    ///   `  <arg>` at start of line            → mustard
    ///   subcommand names (the word before a single `:` in subcommands list)
    ///                                         → gold
    public static func colorizeArgumentParserHelp(_ raw: String,
                                                  colored: Bool) -> String {
        guard colored else { return raw }

        let amber   = ANSIStyle.warmAmber
        let gold    = ANSIStyle.warmGold
        let mustard = ANSIStyle.warmMustard
        let dim     = ANSIStyle.dim
        let bold    = ANSIStyle.bold
        let reset   = ANSIStyle.reset

        var inSubcommands = false
        var lines: [String] = []

        // Recognise an ArgumentParser section header. Three shapes :
        //   "OVERVIEW: A docker-like CLI ..."   ← header + inline content
        //   "USAGE: cocker run [..]"            ← idem
        //   "OPTIONS:"                          ← header on its own line
        // The header word is uppercase letters / spaces, followed by ":".
        func headerSplit(_ line: String) -> (prefix: String, rest: String)? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
            let head = trimmed[trimmed.startIndex..<colonIdx]
            guard !head.isEmpty,
                  head.allSatisfy({ $0.isUppercase || $0 == " " }) else { return nil }
            let rest = String(trimmed[trimmed.index(after: colonIdx)...])
            return (String(head) + ":", rest)
        }

        for var line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let (prefix, rest) = headerSplit(line) {
                inSubcommands = prefix == "SUBCOMMANDS:"
                line = "\(bold)\(amber)\(prefix)\(reset)\(rest)"
                lines.append(line)
                continue
            }

            // Inside SUBCOMMANDS — colorize the command name (first word in
            // the indented block) gold, leave the rest dim.
            if inSubcommands, line.hasPrefix("  "),
               let firstNonSpace = line.firstIndex(where: { $0 != " " }) {
                let after = line[firstNonSpace...]
                // Subcommand "name" can be "ps, ls" (alias list) — grab up to
                // the first run of 2+ spaces or end of meaningful name.
                let split = after.range(of: #"\s{2,}"#, options: .regularExpression)
                if let s = split {
                    let name = String(after[..<s.lowerBound])
                    let rest = String(after[s.upperBound...])
                    let pad = line[..<firstNonSpace]
                    lines.append("\(pad)\(gold)\(name)\(reset)  \(dim)\(rest)\(reset)")
                    continue
                }
            }

            // Inside OPTIONS / ARGUMENTS / FLAGS — flag or arg name at start.
            // Recognise leading whitespace + `-x` or `--xxx` or `<arg>`.
            if let r = line.range(of: #"^(\s+)(-{1,2}[A-Za-z0-9][\w\-]*(,\s*-{1,2}[A-Za-z0-9][\w\-]*)?(\s+<[\w\-]+>)?|<[\w\-]+>(\s+<[\w\-]+>)*)"#,
                                  options: .regularExpression) {
                let head = String(line[r])
                let leading = head.prefix(while: { $0 == " " })
                let flag = head.dropFirst(leading.count)
                let rest = String(line[r.upperBound...])
                lines.append("\(leading)\(mustard)\(flag)\(reset)\(dim)\(rest)\(reset)")
                continue
            }

            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - I/O wrappers (the bits we can't unit-test)

    public static func printCockerdBanner(version: String,
                                          rootDir: String,
                                          ipcSocket: String,
                                          dockerSocket: String,
                                          dnsPort: UInt16) {
        let out = cockerdBanner(
            version: version, rootDir: rootDir, ipcSocket: ipcSocket,
            dockerSocket: dockerSocket, dnsPort: dnsPort,
            colored: stderrIsTTY
        )
        FileHandle.standardError.write(Data(out.utf8))
    }

    public static func printCockerWelcome(version: String) {
        let out = cockerWelcome(version: version, colored: isatty(fileno(stdout)) == 1)
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}
