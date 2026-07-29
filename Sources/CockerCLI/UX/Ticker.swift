import Foundation

// Cocker UX charter §8.1/§8.3 — keeps a sticky view alive while the daemon
// is silent.
//
// A StickyView only repaints when the caller feeds it an event. That is
// fine for chatty phases, but a single `RUN apt-get install` or
// `trunk build --release` can run for minutes without emitting anything.
// The table then freezes mid-frame — same spinner glyph, same elapsed
// time — and looks exactly like a hung command.
//
// Ticker drives a repaint on the shared frame budget so the spinner keeps
// turning and per-row timers keep counting during those silences. It owns
// no state : it just asks the view to re-render whatever it currently has.
public extension UX {
    /// Repaint period for sticky views left alone by the daemon.
    ///
    /// Deliberately shorter than `spinnerFrameInterval` : StickyView drops
    /// any frame arriving within one frame budget of the previous one, so a
    /// ticker running *at* the budget would land on the boundary and lose
    /// roughly every other repaint, producing a visibly stuttering spinner.
    /// Half the budget guarantees one accepted frame per budget window.
    static let tickerInterval: TimeInterval = UX.spinnerFrameInterval / 2

    final class Ticker: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var stopped = false
        private let interval: TimeInterval
        private let onTick: @Sendable () -> Void

        /// - Parameters:
        ///   - interval: repaint period. Defaults to `tickerInterval`.
        ///   - onTick: repaint closure, invoked off the main actor.
        public init(interval: TimeInterval = UX.tickerInterval,
                    onTick: @escaping @Sendable () -> Void) {
            self.interval = interval
            self.onTick = onTick
        }

        public func start() {
            lock.lock()
            guard task == nil, !stopped else { lock.unlock(); return }
            let interval = self.interval
            let onTick = self.onTick
            task = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard let self, !self.isStopped(), !Task.isCancelled else { return }
                    onTick()
                }
            }
            lock.unlock()
        }

        public func stop() {
            lock.lock()
            stopped = true
            let t = task
            task = nil
            lock.unlock()
            t?.cancel()
        }

        private func isStopped() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        deinit { task?.cancel() }
    }

    /// Spinner frame for a given instant.
    ///
    /// Deriving the frame from elapsed time rather than from an event
    /// counter is what makes the animation smooth : the glyph advances on
    /// its own during long silent steps, and every row of a table stays in
    /// phase instead of each one advancing at its own event rate.
    ///
    /// The index is computed in whole milliseconds. Dividing the raw
    /// `TimeInterval`s directly loses the boundary : one full cycle is
    /// `0.080 * 10`, which in binary floating point is just under `0.8`, so
    /// the quotient truncates to 9 instead of wrapping to 0 and the
    /// animation skips a frame on every lap.
    static func spinnerFrame(at date: Date = Date(), since start: Date) -> String {
        let elapsedMs = Int((max(0, date.timeIntervalSince(start)) * 1000).rounded())
        let intervalMs = max(1, Int((UX.spinnerFrameInterval * 1000).rounded()))
        let idx = (elapsedMs / intervalMs) % UX.spinnerFrames.count
        return UX.spinnerFrames[idx]
    }
}
