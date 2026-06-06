import Foundation
import Darwin

// Tiny structured logger used by both cockerd and the CLI. Format :
//
//   2026-06-06T14:23:01.234Z  INFO   [vm]  starting container 0d24123290c9
//   2026-06-06T14:23:01.235Z  WARN   [dns] no cocker IP for container x — falling back to vmnet
//   2026-06-06T14:23:01.236Z  ERROR  [eng] failed to write state.json: <reason>
//
// Set COCKER_LOG_FORMAT=json for one-line JSON per record (suitable for
// piping into journald, Loki, Datadog…). Set COCKER_LOG_LEVEL=debug,info,
// warn,error to filter. Defaults : text format, info level.
//
// We deliberately don't pull in swift-log : it's a single dependency we'd
// have to vendor and would gain almost nothing for our two consumers.

public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info  = 1
    case warn  = 2
    case error = 3

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Parse a value from `$COCKER_LOG_LEVEL`. Unknown / empty → info.
    public static func parse(_ raw: String?) -> LogLevel {
        switch (raw ?? "").lowercased() {
        case "debug": return .debug
        case "info":  return .info
        case "warn", "warning": return .warn
        case "error": return .error
        default:      return .info
        }
    }
}

public enum LogFormat: String, Sendable {
    case text
    case json

    public static func parse(_ raw: String?) -> LogFormat {
        (raw ?? "").lowercased() == "json" ? .json : .text
    }
}

public struct CockerLog: Sendable {
    public let minimum: LogLevel
    public let format: LogFormat

    public init(minimum: LogLevel = .info, format: LogFormat = .text) {
        self.minimum = minimum
        self.format = format
    }

    /// Read level + format from the process environment.
    public static func fromEnvironment() -> CockerLog {
        let env = ProcessInfo.processInfo.environment
        return CockerLog(
            minimum: LogLevel.parse(env["COCKER_LOG_LEVEL"]),
            format:  LogFormat.parse(env["COCKER_LOG_FORMAT"])
        )
    }

    /// Shared default — env-configured at first access. Use this from any
    /// daemon component that doesn't have a logger injected ; that way the
    /// boot output stays consistent (single timestamped+leveled format
    /// instead of a mix of `[cockerd]` bare prints and structured records).
    public static let shared: CockerLog = .fromEnvironment()

    public func debug(_ module: String, _ message: String) { emit(.debug, module, message) }
    public func info(_ module: String, _ message: String)  { emit(.info,  module, message) }
    public func warn(_ module: String, _ message: String)  { emit(.warn,  module, message) }
    public func error(_ module: String, _ message: String) { emit(.error, module, message) }

    public func emit(_ level: LogLevel, _ module: String, _ message: String) {
        guard level >= minimum else { return }
        let line: String
        switch format {
        case .text:
            line = Self.formatText(level: level, module: module, message: message)
        case .json:
            line = Self.formatJSON(level: level, module: module, message: message)
        }
        fputs(line + "\n", stderr)
        fflush(stderr)
    }

    // MARK: - Formatters (pure, testable)

    public static func formatText(level: LogLevel, module: String, message: String,
                                  timestamp: Date = Date()) -> String {
        "\(iso(timestamp))  \(pad(level.label, 5))  [\(module)] \(message)"
    }

    public static func formatJSON(level: LogLevel, module: String, message: String,
                                  timestamp: Date = Date()) -> String {
        // Hand-roll the JSON so we don't allocate a JSONEncoder per call.
        // Module and message are escaped to keep newlines / quotes safe.
        var s = "{\"ts\":\"\(iso(timestamp))\",\"level\":\"\(level.label.lowercased())\",\"module\":\"\(escape(module))\",\"msg\":\"\(escape(message))\"}"
        s.makeContiguousUTF8()
        return s
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if c.asciiValue.map({ $0 < 0x20 }) ?? false {
                    out += String(format: "\\u%04x", c.asciiValue!)
                } else {
                    out.append(c)
                }
            }
        }
        return out
    }
}
