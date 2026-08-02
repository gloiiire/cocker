import Foundation

/// The UX charter §6 failure block, as a pure function.
///
///     ✗ <what failed>
///       reason : <why>
///       hint   : <how to fix it>
///
/// This lived only in `CockerCLI`, so `cockerd` — which users see every time
/// they run it in the foreground, and whose output is what lands in
/// `cockerd.log` — never adopted it. It printed `Error:` / `Warning:`
/// prefixes and bare `✗` lines instead, so `cocker daemon setup` read like a
/// different product from `cocker run`.
///
/// Rendering lives here rather than being copied so the two can't drift.
/// Colour is a parameter because the CLI decides it from `UX.TTY` and the
/// daemon from `Banner.stderrIsTTY`.
public enum FailureBlock {
    public static func render(
        headline: String,
        reason: String? = nil,
        hint: String? = nil,
        details: String? = nil,
        colored: Bool
    ) -> String {
        let red = colored ? ANSIStyle.warmRed : ""
        let dim = colored ? ANSIStyle.dim : ""
        let reset = colored ? ANSIStyle.reset : ""

        var lines = [" \(red)✗\(reset) \(red)\(headline)\(reset)"]
        if let reason  { lines.append("   \(dim)reason :\(reset) \(reason)") }
        if let hint    { lines.append("   \(dim)hint   :\(reset) \(hint)") }
        if let details { lines.append("   \(dim)details:\(reset) \(details)") }
        return lines.joined(separator: "\n")
    }

    /// Same shape, amber, for a non-fatal advisory.
    public static func renderWarning(
        headline: String,
        note: String? = nil,
        colored: Bool
    ) -> String {
        let amber = colored ? ANSIStyle.warmAmber : ""
        let dim = colored ? ANSIStyle.dim : ""
        let reset = colored ? ANSIStyle.reset : ""

        var lines = [" \(amber)⚠\(reset) \(amber)\(headline)\(reset)"]
        if let note { lines.append("   \(dim)note   :\(reset) \(note)") }
        return lines.joined(separator: "\n")
    }
}

/// `cockerd`'s user-facing output, in the charter's shape.
///
/// Everything here goes to stderr: the daemon's stdout is its banner and
/// progress, and an operator piping one shouldn't get the other mixed in.
public enum DaemonMessage {
    public static func failure(
        _ headline: String,
        reason: String? = nil,
        hint: String? = nil,
        details: String? = nil
    ) {
        let text = FailureBlock.render(headline: headline, reason: reason, hint: hint,
                                       details: details, colored: Banner.stderrIsTTY)
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    public static func warning(_ headline: String, note: String? = nil) {
        let text = FailureBlock.renderWarning(headline: headline, note: note,
                                              colored: Banner.stderrIsTTY)
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
