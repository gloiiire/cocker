import Foundation

// Ordered passthrough of a daemon stream event.
//
// stdout is block-buffered when redirected (CI, `cocker build > log`)
// while stderr never is. Writing to each independently reorders the
// output: a build's failure diagnostic overtook the whole step list and
// appeared BEFORE it, so anyone tailing the log saw "Build failed" with
// no visible cause.
//
// Flushing stdout before touching stderr restores chronological order at
// negligible cost — these are line-rate events, not a hot loop.
public extension UX {
    /// Write `text` to stderr without letting it jump ahead of stdout.
    static func writeStderr(_ text: String) {
        fflush(stdout)
        fputs(text, stderr)
        fflush(stderr)
    }

    /// Flush pending stdout so a subsequent stderr write stays in order.
    /// Call before emitting a failure through another channel.
    static func syncStdout() {
        fflush(stdout)
    }
}
