import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Cocker UX charter §10 — terminal-capabilities gate. Every UX primitive
// (color, spinner, sticky table, progress bar) checks this before emitting
// anything that would garble a file or pipe.

public extension UX {
    enum TTY {
        public struct Capabilities: Sendable, Equatable {
            public let isInteractive: Bool   // stdout is a TTY
            public let colorEnabled: Bool    // emit ANSI color
            public let animationEnabled: Bool // sticky/spinner/cursor moves allowed

            public init(isInteractive: Bool, colorEnabled: Bool, animationEnabled: Bool) {
                self.isInteractive = isInteractive
                self.colorEnabled = colorEnabled
                self.animationEnabled = animationEnabled
            }
        }

        // Detection follows the charter §10 priority order :
        //   1. NO_COLOR (any value) → no color, no animation
        //   2. FORCE_COLOR (any value) → color even when not a TTY
        //   3. --no-color in argv → no color
        //   4. isatty(stdout) == 0 → no color, no animation
        // Animation always requires a real TTY (cursor moves need it),
        // regardless of FORCE_COLOR.
        public static func detect(
            stdoutFD: Int32 = STDOUT_FILENO,
            env: [String: String] = ProcessInfo.processInfo.environment,
            argv: [String] = CommandLine.arguments
        ) -> Capabilities {
            let isTTY = isatty(stdoutFD) != 0
            let term = env["TERM"] ?? ""
            let dumbTerm = term == "dumb"
            let noColor = env["NO_COLOR"] != nil
            let forceColor = env["FORCE_COLOR"] != nil
            let noColorFlag = argv.contains("--no-color")

            let colorEnabled: Bool = {
                if noColor || dumbTerm || noColorFlag { return false }
                if forceColor { return true }
                return isTTY
            }()

            // Animation needs both : a real TTY (cursor escape codes) and
            // color permission (NO_COLOR users typically want pure text).
            let animationEnabled = isTTY && !noColor && !dumbTerm && !noColorFlag

            return Capabilities(
                isInteractive: isTTY,
                colorEnabled: colorEnabled,
                animationEnabled: animationEnabled
            )
        }

        // Mutable so tests and CLI flags can override at startup. Detection
        // runs once on first access ; CLI may call `set(...)` early in main.
        public static var current: Capabilities = detect()

        public static func set(_ caps: Capabilities) { current = caps }

        // Convenience : paint a string in a color/with modifiers, no-op if
        // color is disabled or the chosen color is .default.
        public static func paint(_ text: String, _ color: UX.Color, _ mods: [UX.Modifier] = []) -> String {
            guard current.colorEnabled else { return text }
            if color == .default && mods.isEmpty { return text }
            var prefix = ""
            for m in mods { prefix += m.ansi }
            prefix += color.ansi
            if prefix.isEmpty { return text }
            return "\(prefix)\(text)\u{001B}[0m"
        }
    }
}

extension UX.Color: Equatable {}
