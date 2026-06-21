import Foundation

// Cocker UX charter §7 — unified [y/N] confirmation prompt. Every
// destructive command (prune, system prune, rm -f, etc.) calls this so
// the wording, default behavior, and visual feel stay identical.
//
// Default answer is always N. Empty input (just Enter) = abort.
// `force: true` skips the prompt but still prints the summary so the
// scrollback shows what was actually about to happen.

public extension UX {
    enum Confirm {
        // Returns true if the user explicitly confirmed (y / yes / Y / Yes /
        // YES). Anything else, including empty input or stdin closed, is
        // treated as N.
        public static func ask(summary: String, force: Bool = false, prompt: String = "Continue?") -> Bool {
            let warnIcon = UX.TTY.paint(Icon.warn.rawValue, .warn)
            let line = " \(warnIcon) \(summary)\n   \(prompt) [y/N] "
            FileHandle.standardOutput.write(Data(line.utf8))

            if force {
                let auto = UX.TTY.paint("(--force : assumed yes)", .dim)
                FileHandle.standardOutput.write(Data("\(auto)\n".utf8))
                return true
            }

            guard let raw = readLine(strippingNewline: true) else { return false }
            return parse(raw)
        }

        // Public for unit testing the parser without touching stdin.
        public static func parse(_ input: String) -> Bool {
            let v = input.trimmingCharacters(in: .whitespaces).lowercased()
            return v == "y" || v == "yes"
        }
    }
}
