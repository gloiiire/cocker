import Foundation

// Cocker UX charter §6 — three-line error formatter. Every error a
// command emits answers the same three questions :
//   what failed   →  red ✗ + headline
//   why           →  "reason :"  (dim label, default text)
//   how to fix    →  "hint   :"  (dim label, default text)
// An optional 4th "details:" line points to logs / stack traces.

public extension UX {
    enum Failure {
        public static func render(
            headline: String,
            reason: String? = nil,
            hint: String? = nil,
            details: String? = nil
        ) -> String {
            var lines: [String] = []
            let icon = UX.TTY.paint(Icon.failure.rawValue, .failure)
            let head = UX.TTY.paint(headline, .failure)
            lines.append(" \(icon) \(head)")
            if let reason {
                lines.append("   " + UX.TTY.paint("reason :", .dim) + " \(reason)")
            }
            if let hint {
                lines.append("   " + UX.TTY.paint("hint   :", .dim) + " \(hint)")
            }
            if let details {
                lines.append("   " + UX.TTY.paint("details:", .dim) + " \(details)")
            }
            return lines.joined(separator: "\n")
        }

        // Emit to stderr, matching Docker convention (errors don't pollute
        // a command's stdout pipe).
        public static func emit(
            headline: String,
            reason: String? = nil,
            hint: String? = nil,
            details: String? = nil
        ) {
            let text = render(headline: headline, reason: reason, hint: hint, details: details) + "\n"
            FileHandle.standardError.write(Data(text.utf8))
        }
    }

    // Warnings (yellow ⚠ + headline). Same shape, lighter weight — no
    // reason/hint discipline required.
    enum Warning {
        public static func render(_ headline: String, note: String? = nil) -> String {
            let icon = UX.TTY.paint(Icon.warn.rawValue, .warn)
            let head = UX.TTY.paint(headline, .warn)
            var line = " \(icon) \(head)"
            if let note {
                line += "\n   " + UX.TTY.paint(note, .dim)
            }
            return line
        }

        public static func emit(_ headline: String, note: String? = nil) {
            let text = render(headline, note: note) + "\n"
            FileHandle.standardError.write(Data(text.utf8))
        }
    }
}
