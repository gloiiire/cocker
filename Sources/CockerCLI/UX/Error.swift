import Foundation
import ArgumentParser

// Cocker UX charter §6 — three-line error formatter. Every error a
// command emits answers the same three questions :
//   what failed   →  red ✗ + headline
//   why           →  "reason :"  (dim label, default text)
//   how to fix    →  "hint   :"  (dim label, default text)
// An optional 4th "details:" line points to logs / stack traces.

public extension UX {
    /// Thread-safe failure latch for streaming commands. `sendStreaming`'s
    /// handler is `@Sendable (StreamEvent) -> Void` and can't throw, so a
    /// `.error` stream event trips this and the command calls
    /// `throwIfTripped()` after the stream drains — otherwise it would
    /// print an error yet exit 0.
    final class FailFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        public init() {}
        public func trip() { lock.lock(); value = true; lock.unlock() }
        public var tripped: Bool { lock.lock(); defer { lock.unlock() }; return value }
        public func throwIfTripped(code: Int32 = 1) throws {
            if tripped { throw ExitCode(code) }
        }
    }

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

        /// Emit the §6 block AND fail the command with `code`. Use this at
        /// the ~dozens of sites that printed an error then `return`ed —
        /// which silently exited 0 (a script couldn't tell success from
        /// failure). `try UX.Failure.fail(...)` replaces `emit(...)` +
        /// `return`, and the CLI's top-level catch exits with `code`.
        @discardableResult
        public static func fail(
            headline: String, reason: String? = nil, hint: String? = nil,
            details: String? = nil, code: Int32 = 1
        ) throws -> Never {
            emit(headline: headline, reason: reason, hint: hint, details: details)
            throw ExitCode(code)
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
