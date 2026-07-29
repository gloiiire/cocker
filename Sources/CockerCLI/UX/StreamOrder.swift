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

    /// Write a chunk of a never-ending stream (`logs -f`, `attach`,
    /// `events`, attached `compose up`) to stdout.
    ///
    /// These commands only end when the user interrupts them, so a
    /// block-buffered stdout — which is what a redirect or a pipe gives —
    /// never gets flushed and the consumer sees nothing at all. Measured
    /// on `compose up -a`: 0 bytes written after 14 seconds of live output.
    ///
    /// Writes through `FileHandle`, not `print`. StickyView moves the
    /// cursor with direct `FileHandle` writes; mixing the two paths lets
    /// them overtake each other, and the footer's erase-to-end-of-screen
    /// then wipes log lines that were still sitting in the stdio buffer.
    /// One path, one ordering.
    static func writeStreamChunk(_ text: String) {
        fflush(stdout)   // anything a plain `print` left behind goes first
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
