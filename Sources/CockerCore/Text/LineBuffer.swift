import Foundation

// Reassemble a chunked stream into whole lines.
//
// The daemon forwards container output as it arrives, so one log line can
// reach the CLI split across several events ("[api] API-LOG-" then "3\n").
// That is harmless when the output just scrolls, but a sticky footer
// redraws between every event — and redrawing mid-line tears the line in
// half, leaving the footer wedged inside it:
//
//     [footdemo_api_1] API-LOG- → Attached api
//        press d detach · q quit
//     3
//
// Buffering until a newline keeps each line intact, so the footer only
// ever redraws between lines.
//
// Everything here works on `unicodeScalars`, never on `Character`. Swift
// treats "\r\n" as a *single* Character — one grapheme cluster — so
// `"API-LOG-3\r\n".contains("\n")` is false. Container output arrives over
// a serial console and ends in CRLF, so Character-based line splitting
// matches nothing at all and holds every line forever: measured against a
// real container, 36 stream events in, 0 lines out, 0 bytes on stdout.
// Scalars have no such ambiguity.
//
// A reference type with a lock, because the streaming callbacks it is used
// from are `@Sendable` and may run off different threads.
public final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = String.UnicodeScalarView()

    public init() {}

    /// Feed a chunk, get back the complete lines it finished (line ending
    /// included and unmodified, so callers can print them verbatim).
    public func feed(_ chunk: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(contentsOf: chunk.unicodeScalars)

        var lines: [String] = []
        // Cut after each LF. A CR that precedes it stays part of the line,
        // which keeps the output byte-for-byte what the container emitted.
        while let lf = pending.firstIndex(of: "\n") {
            let after = pending.index(after: lf)
            lines.append(String(String.UnicodeScalarView(pending[..<after])))
            pending = String.UnicodeScalarView(pending[after...])
        }
        return lines
    }

    /// Whatever is left when the stream ends — a final line with no
    /// trailing newline must not be swallowed.
    public func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let rest = String(pending)
        pending = String.UnicodeScalarView()
        return rest
    }

    /// True when nothing is held back.
    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending.isEmpty
    }
}

/// Line-ending helpers that do not fall into the grapheme-cluster trap.
public enum LineEndings {
    /// True when `text` ends in a line feed.
    ///
    /// Must be asked at scalar level: `"API-LOG-2\r\n"` ends in a *single*
    /// Character, the CRLF cluster, so `hasSuffix("\n")` answers false and
    /// callers happily append a second newline — or, worse, skip appending
    /// the one that was missing.
    public static func isTerminated(_ text: String) -> Bool {
        text.unicodeScalars.last == "\n"
    }

    /// `text` with a trailing newline, added only if there isn't one.
    public static func terminated(_ text: String) -> String {
        isTerminated(text) ? text : text + "\n"
    }
}
