import Foundation
import CockerCore

/// Renders a continuous log stream underneath a pinned interactive footer.
///
/// Every streaming command wants the same three things: keep the footer
/// glued to the bottom, never let a redraw cut a log line in half, and stay
/// completely transparent when the output is piped. Doing that by hand at
/// each call site is how the two bugs below got in, so it lives here once.
///
/// The footer used to be skipped entirely for these commands on the grounds
/// that a bottom-pinned region "would fight a fast, unbounded log stream".
/// It only fights it when output is written mid-line: buffering to line
/// boundaries removes the conflict, so the footer can stay.
///
/// Off-TTY (`logs -f | grep`) `InteractiveFooter` is inert, clear/refresh do
/// nothing, and this writes the stream straight through.
final class StreamingLogView: @unchecked Sendable {
    private let footer: InteractiveFooter
    // One assembler per stream: stdout and stderr are independent, and
    // sharing a buffer would splice a half-written stderr line onto stdout.
    private let outBuffer = LineBuffer()
    private let errBuffer = LineBuffer()
    private let lock = NSLock()

    init(footer: InteractiveFooter) {
        self.footer = footer
    }

    /// Feed one stream event. Complete lines are emitted between footer
    /// redraws; a partial line is held until it is whole.
    func emit(_ event: StreamEvent, transform: (String) -> String = { $0 }) {
        switch event.stream {
        case .stdout:
            write(outBuffer.feed(event.data).map(transform), isError: false)
        case .stderr:
            write(errBuffer.feed(event.data).map(transform), isError: true)
        default:
            break
        }
    }

    /// Emit one already-complete line (event streams, which the daemon
    /// hands over pre-split). Bypasses the assembler but keeps the same
    /// clear/refresh discipline, and the same single write path: `print` is
    /// buffered while StickyView writes directly, and mixing the two lets
    /// the footer's erase-to-end-of-screen wipe lines still sitting in the
    /// stdio buffer.
    func emitLine(_ text: String) {
        write([LineEndings.terminated(text)], isError: false)
    }

    /// Flush anything held back. A container that exits without a trailing
    /// newline must not have its last line swallowed.
    func finish(transform: (String) -> String = { $0 }) {
        let out = outBuffer.flush().map(transform)
        let err = errBuffer.flush().map(transform)
        guard out != nil || err != nil else { return }
        lock.lock(); defer { lock.unlock() }
        footer.clear()
        if let out { UX.writeStreamChunk(out) }
        if let err { UX.writeStderr(err) }
        footer.refresh()
    }

    private func write(_ lines: [String], isError: Bool) {
        guard !lines.isEmpty else { return }
        // Serialised: concurrent containers stream through one footer, and
        // interleaving a clear/refresh pair would leave the region orphaned.
        lock.lock(); defer { lock.unlock() }
        footer.clear()
        for line in lines {
            if isError { UX.writeStderr(line) } else { UX.writeStreamChunk(line) }
        }
        footer.refresh()
    }
}
