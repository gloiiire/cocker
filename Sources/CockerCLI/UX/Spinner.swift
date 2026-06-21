import Foundation

// Cocker UX charter §8.1 — animated Braille spinner. Renders inline (single
// line, carriage-return overwrite) when stdout is a TTY ; degrades to a
// single static "→ <label>..." line otherwise.
//
// Frame budget : 80ms (~12.5 fps), shared with StickyView. Never spam
// the terminal faster than that.

public extension UX {
    static let spinnerFrames: [String] = [
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]
    static let spinnerFrameInterval: TimeInterval = 0.080

    final class Spinner: @unchecked Sendable {
        private let lock = NSLock()
        private var label: String
        private var task: Task<Void, Never>?
        private var frameIdx = 0
        private let startedAt = Date()
        private var stopped = false
        private let animate: Bool

        public init(label: String) {
            self.label = label
            self.animate = UX.TTY.current.animationEnabled
        }

        public func start() {
            if animate {
                task = Task.detached(priority: .userInitiated) { [weak self] in
                    while let self, !Task.isCancelled, !self.isStopped() {
                        self.tick()
                        try? await Task.sleep(nanoseconds: UInt64(UX.spinnerFrameInterval * 1_000_000_000))
                    }
                }
            } else {
                // Static fallback : one line, no \r.
                let icon = UX.TTY.paint(Icon.action.rawValue, .progress)
                FileHandle.standardOutput.write(Data(" \(icon) \(label)...\n".utf8))
            }
        }

        public func update(label newLabel: String) {
            lock.lock(); defer { lock.unlock() }
            label = newLabel
        }

        public func succeed(_ message: String? = nil, elapsed: TimeInterval? = nil) {
            finish(icon: .success, message: message, elapsed: elapsed)
        }

        public func fail(_ message: String? = nil) {
            finish(icon: .failure, message: message, elapsed: nil)
        }

        public func stop() {
            finish(icon: nil, message: nil, elapsed: nil)
        }

        private func finish(icon: Icon?, message: String?, elapsed: TimeInterval?) {
            lock.lock()
            stopped = true
            let finalLabel = message ?? label
            lock.unlock()

            task?.cancel()
            task = nil

            if animate {
                clearLine()
                if let icon {
                    let elapsedStr = elapsed.map { "  " + UX.TTY.paint(UX.formatElapsed($0), .dim) } ?? ""
                    let line = " \(UX.TTY.paint(icon.rawValue, icon.color)) \(finalLabel)\(elapsedStr)\n"
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
            } else {
                if let icon {
                    let elapsedStr = elapsed.map { "  " + UX.formatElapsed($0) } ?? ""
                    let line = " \(icon.rawValue) \(finalLabel)\(elapsedStr)\n"
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
            }
        }

        private func tick() {
            lock.lock()
            let frame = UX.spinnerFrames[frameIdx % UX.spinnerFrames.count]
            frameIdx += 1
            let labelSnap = label
            lock.unlock()

            let painted = UX.TTY.paint(frame, .progress)
            let line = "\r \(painted) \(labelSnap)\u{001B}[K"
            FileHandle.standardOutput.write(Data(line.utf8))
        }

        private func clearLine() {
            FileHandle.standardOutput.write(Data("\r\u{001B}[K".utf8))
        }

        private func isStopped() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }
    }

    // Convenience : run a closure with a spinner that always cleans up.
    static func withSpinner<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let spinner = Spinner(label: label)
        spinner.start()
        let start = Date()
        do {
            let result = try await body()
            spinner.succeed(elapsed: Date().timeIntervalSince(start))
            return result
        } catch {
            spinner.fail()
            throw error
        }
    }
}
