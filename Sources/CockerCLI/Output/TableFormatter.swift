import Foundation

// ANSI color codes
public enum ANSI {
    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let blue = "\u{001B}[34m"
    public static let cyan = "\u{001B}[36m"
    public static let red = "\u{001B}[31m"
    public static let white = "\u{001B}[37m"

    public static var isEnabled: Bool = {
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        return term != "dumb" && isatty(STDOUT_FILENO) != 0
    }()

    public static func colored(_ text: String, _ code: String) -> String {
        isEnabled ? "\(code)\(text)\(reset)" : text
    }
}

// Simple table renderer for CLI output
public struct TableFormatter {
    public struct Column {
        public let header: String
        public let minWidth: Int
        public let maxWidth: Int?

        public init(_ header: String, min: Int = 0, max: Int? = nil) {
            self.header = header
            self.minWidth = min
            self.maxWidth = max
        }
    }

    public static func format(columns: [Column], rows: [[String]]) -> String {
        var widths = columns.map { $0.minWidth }

        // Compute column widths
        for row in rows {
            for (i, cell) in row.prefix(columns.count).enumerated() {
                let width = min(cell.count, columns[i].maxWidth ?? cell.count)
                widths[i] = max(widths[i], max(columns[i].header.count, width))
            }
        }

        var lines: [String] = []

        // Header
        let header = zip(columns, widths).map { col, w in
            ANSI.colored(col.header.padding(toLength: w, withPad: " ", startingAt: 0), ANSI.bold)
        }.joined(separator: "   ")
        lines.append(header)

        // Rows
        for row in rows {
            let line = zip(row.prefix(widths.count), widths).map { cell, w in
                let truncated = cell.count > w ? String(cell.prefix(w - 3)) + "..." : cell
                return truncated.padding(toLength: w, withPad: " ", startingAt: 0)
            }.joined(separator: "   ")
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}

// Progress indicator for pull/build
public final class ProgressReporter: @unchecked Sendable {
    private var lastLines = 0
    private let lock = NSLock()

    public init() {}

    public func update(_ layers: [String: LayerProgress]) {
        lock.lock()
        defer { lock.unlock() }

        // Clear previous output
        if lastLines > 0 {
            let up = "\u{001B}[\(lastLines)A\u{001B}[J"
            print(up, terminator: "")
        }

        var output: [String] = []
        for (id, progress) in layers.sorted(by: { $0.key < $1.key }) {
            let bar = makeBar(progress.fraction, width: 20)
            let status = progress.status.padding(toLength: 12, withPad: " ", startingAt: 0)
            let shortId = String(id.prefix(12))
            output.append("\(ANSI.colored(shortId, ANSI.cyan))  \(status)  \(bar)  \(progress.detail)")
        }

        print(output.joined(separator: "\n"))
        lastLines = output.count
    }

    private func makeBar(_ fraction: Double, width: Int) -> String {
        let filled = Int(fraction * Double(width))
        let empty = width - filled
        return ANSI.colored("[" + String(repeating: "=", count: filled) + String(repeating: " ", count: empty) + "]", ANSI.green)
    }

    public func done() {
        lock.lock()
        defer { lock.unlock() }
        lastLines = 0
    }
}

public struct LayerProgress: Sendable {
    public var status: String
    public var current: Int64
    public var total: Int64
    public var detail: String

    public var fraction: Double {
        total > 0 ? min(1.0, Double(current) / Double(total)) : 0
    }

    public init(status: String, current: Int64 = 0, total: Int64 = 0, detail: String = "") {
        self.status = status
        self.current = current
        self.total = total
        self.detail = detail
    }
}

// Human-readable byte sizes
public func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
}

// Relative time ("2 hours ago")
public func relativeTime(from date: Date) -> String {
    let diff = Date().timeIntervalSince(date)
    switch diff {
    case ..<60: return "Just now"
    case ..<3600: return "\(Int(diff / 60)) minutes ago"
    case ..<86400: return "\(Int(diff / 3600)) hours ago"
    case ..<2592000: return "\(Int(diff / 86400)) days ago"
    default: return "\(Int(diff / 2592000)) months ago"
    }
}
