import Foundation

// Cocker UX charter §8.2 — fixed-width progress bar used by pull, build,
// push, save, load, icloud prefetch. 18 chars wide, █ filled / ░ empty.

public extension UX {
    static let progressBarWidth = 18

    enum ProgressBar {
        public static func render(fraction: Double, width: Int = UX.progressBarWidth) -> String {
            let clamped = max(0.0, min(1.0, fraction.isFinite ? fraction : 0))
            let filled = Int(clamped * Double(width))
            let empty = width - filled
            let bar = "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
            return UX.TTY.paint(bar, .progress)
        }

        // "12.4 MB / 18.0 MB". Pure string, no padding.
        public static func bytes(current: Int64, total: Int64) -> String {
            "\(formatBytes(current)) / \(formatBytes(total))"
        }

        // "  65%" — 4 chars (3-digit + %), right-aligned.
        public static func percent(fraction: Double) -> String {
            let clamped = max(0.0, min(1.0, fraction.isFinite ? fraction : 0))
            return String(format: "%3d%%", Int(clamped * 100))
        }

        // Full bar + bytes + percent. Used by pull / save / load.
        public static func full(current: Int64, total: Int64) -> String {
            guard total > 0 else { return render(fraction: 0) + "  \(formatBytes(current))" }
            let f = Double(current) / Double(total)
            return "\(render(fraction: f))  \(bytes(current: current, total: total))   \(percent(fraction: f))"
        }
    }

    // Human-readable byte size. 1 decimal, IEC units.
    static func formatBytes(_ bytes: Int64) -> String {
        let absVal = abs(bytes)
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(absVal)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[idx])
    }

    // Stateful tracker for multi-layer pulls (replaces ProgressReporter
    // for new callers — the old one stays for backward compat until PR #2).
    final class LayerTracker: @unchecked Sendable {
        public struct Layer: Sendable {
            public var status: String   // "Pulling", "Downloading", "Extracting"
            public var current: Int64
            public var total: Int64
            public init(status: String, current: Int64 = 0, total: Int64 = 0) {
                self.status = status; self.current = current; self.total = total
            }
            public var fraction: Double {
                total > 0 ? max(0, min(1, Double(current) / Double(total))) : 0
            }
        }

        private let lock = NSLock()
        private var layers: [String: Layer] = [:]
        private var order: [String] = []

        public init() {}

        public func update(layerID: String, status: String, current: Int64 = 0, total: Int64 = 0) {
            lock.lock(); defer { lock.unlock() }
            if layers[layerID] == nil { order.append(layerID) }
            layers[layerID] = Layer(status: status, current: current, total: total)
        }

        public func render() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return order.compactMap { id in
                guard let l = layers[id] else { return nil }
                let shortID = UX.TTY.paint(String(id.prefix(12)), .accent)
                let status = l.status.padding(toLength: 12, withPad: " ", startingAt: 0)
                let bar = ProgressBar.render(fraction: l.fraction)
                let detail = l.total > 0 ? ProgressBar.bytes(current: l.current, total: l.total) : ""
                return " \(shortID)  \(status)  \(bar)  \(detail)"
            }
        }
    }
}
