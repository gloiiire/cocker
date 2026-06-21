import Foundation

// Cocker UX charter §8.3 — the multi-line redraw container used by
// `cocker build`, `cocker compose up`, `cocker compose watch`. Each call
// to render() rewrites the last N lines in place using ANSI cursor moves.
//
// When stdout is not a TTY (pipe, file, CI without PTY), redraw is a
// no-op : we keep only the FINAL state (printed on finalize()) so files
// stay clean and chronological.
//
// Frame budget : 80ms minimum between actual redraws. Burst events get
// coalesced into a single frame.

public extension UX {
    final class StickyView: @unchecked Sendable {
        private let lock = NSLock()
        private var lastLineCount = 0
        private var lastFrameAt: Date?
        private var lastLines: [String] = []
        private let animated: Bool

        public init() {
            self.animated = UX.TTY.current.animationEnabled
        }

        // Replace the current view with `lines`. Coalesces calls that arrive
        // within the §8.4 frame budget unless `force: true`.
        public func render(_ lines: [String], force: Bool = false) {
            lock.lock()
            let now = Date()
            if !force, let last = lastFrameAt,
               now.timeIntervalSince(last) < UX.spinnerFrameInterval {
                lastLines = lines  // remember for finalize/next frame
                lock.unlock()
                return
            }
            lastFrameAt = now
            lastLines = lines
            let prev = lastLineCount
            lastLineCount = animated ? lines.count : 0
            lock.unlock()

            guard animated else { return } // non-TTY : print only on finalize

            var out = ""
            if prev > 0 {
                // Move up `prev` lines, erase from cursor to end of screen.
                out += "\u{001B}[\(prev)A\u{001B}[J"
            }
            out += lines.joined(separator: "\n")
            if !lines.isEmpty { out += "\n" }
            FileHandle.standardOutput.write(Data(out.utf8))
        }

        // Replace the view with the final state. Always prints (no frame
        // coalescing), and on non-TTY this is the only call that actually
        // emits output for the whole session.
        public func finalize(_ lines: [String]) {
            lock.lock()
            let prev = lastLineCount
            lastLineCount = 0
            lastFrameAt = nil
            lock.unlock()

            var out = ""
            if animated && prev > 0 {
                out += "\u{001B}[\(prev)A\u{001B}[J"
            }
            out += lines.joined(separator: "\n")
            if !lines.isEmpty { out += "\n" }
            FileHandle.standardOutput.write(Data(out.utf8))
        }

        // Discard the in-flight view without printing anything new. Used
        // on Ctrl-C abort before the cleanup message is printed by the
        // caller.
        public func abandon() {
            lock.lock()
            let prev = lastLineCount
            lastLineCount = 0
            lastFrameAt = nil
            lock.unlock()

            guard animated, prev > 0 else { return }
            FileHandle.standardOutput.write(Data("\u{001B}[\(prev)A\u{001B}[J".utf8))
        }

        public var isAnimated: Bool { animated }
    }
}
