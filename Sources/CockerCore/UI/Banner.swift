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

    public static let red     = "\u{1B}[31m"
    public static let green   = "\u{1B}[32m"
    public static let yellow  = "\u{1B}[33m"
    public static let blue    = "\u{1B}[34m"
    public static let magenta = "\u{1B}[35m"
    public static let cyan    = "\u{1B}[36m"
    public static let white   = "\u{1B}[37m"

    public static let brightCyan = "\u{1B}[96m"
    public static let brightGreen = "\u{1B}[92m"
}

public enum Banner {

    /// Raw ASCII art — 5 lines, fits in 80 columns. Stable across terminals.
    public static let logo: String = """
       ____               __
      / __ \\____  _____  / /_____  _____
     / /  / / __ \\/ ___/ / //_/ _ \\/ ___/
    / /__/ / /_/ / /__  / ,< /  __/ /
    \\____/\\____/\\___/  /_/|_|\\___/_/
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
        let cyan   = colored ? ANSIStyle.brightCyan : ""
        let green  = colored ? ANSIStyle.brightGreen : ""
        let dim    = colored ? ANSIStyle.dim : ""
        let bold   = colored ? ANSIStyle.bold : ""
        let reset  = colored ? ANSIStyle.reset : ""

        var out = "\n"
        out += cyan + logo + reset + "\n"
        out += "      \(dim)container engine for Apple Silicon · v\(version)\(reset)\n"
        out += "      \(dim)https://github.com/gloiiire/cocker\(reset)\n\n"

        out += "  \(bold)Listeners\(reset)\n"
        out += "    \(green)●\(reset) IPC          unix://\(ipcSocket)\n"
        out += "    \(green)●\(reset) Docker API   unix://\(dockerSocket)\n"
        out += "    \(green)●\(reset) DNS          0.0.0.0:\(dnsPort) (UDP + TCP)\n\n"

        out += "  \(bold)Root\(reset)         \(rootDir)\n\n"

        out += "  \(green)✓\(reset) \(bold)Ready.\(reset) "
        out += "\(dim)Daemon is running. Press \(reset)\(bold)Ctrl-C\(reset)\(dim) to stop.\(reset)\n"
        out += "  \(dim)Open another terminal and try: \(reset)\(bold)cocker run alpine echo hello\(reset)\n\n"

        return out
    }

    /// Pure version of the `cocker` no-args welcome. Used by the CLI to prepend
    /// the help text.
    public static func cockerWelcome(version: String, colored: Bool) -> String {
        let cyan  = colored ? ANSIStyle.brightCyan : ""
        let dim   = colored ? ANSIStyle.dim : ""
        let reset = colored ? ANSIStyle.reset : ""

        var out = "\n"
        out += cyan + logo + reset + "\n"
        out += "      \(dim)container engine for Apple Silicon · v\(version)\(reset)\n"
        out += "      \(dim)https://github.com/gloiiire/cocker\(reset)\n\n"
        return out
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
