import Foundation

// Build a Prometheus exposition-format text payload. Spec :
//   https://prometheus.io/docs/instrumenting/exposition_formats/#text-based-format
//
// We only emit counter + gauge metrics — cocker doesn't need histograms or
// summaries yet. Each metric carries a `# HELP` line and a `# TYPE` line,
// followed by one line per (metric, labels) tuple.

public enum PromMetricType: String, Sendable {
    case counter
    case gauge
}

public struct PromMetric: Sendable {
    public let name: String
    public let help: String
    public let type: PromMetricType
    public let samples: [PromSample]

    public init(name: String, help: String, type: PromMetricType, samples: [PromSample]) {
        self.name = name; self.help = help; self.type = type; self.samples = samples
    }
}

public struct PromSample: Sendable {
    public let value: Double
    public let labels: [(String, String)]

    public init(value: Double, labels: [(String, String)] = []) {
        self.value = value
        self.labels = labels
    }
}

public enum PrometheusExposition {

    public static let contentType = "text/plain; version=0.0.4; charset=utf-8"

    /// Render an exposition-format payload from a list of metrics. Order is
    /// preserved. Trailing newline included.
    public static func render(_ metrics: [PromMetric]) -> String {
        var out = ""
        for m in metrics {
            out += "# HELP \(m.name) \(escapeHelp(m.help))\n"
            out += "# TYPE \(m.name) \(m.type.rawValue)\n"
            for s in m.samples {
                out += "\(m.name)"
                if !s.labels.isEmpty {
                    let parts = s.labels.map { "\($0.0)=\"\(escapeLabel($0.1))\"" }
                    out += "{" + parts.joined(separator: ",") + "}"
                }
                out += " \(format(value: s.value))\n"
            }
        }
        return out
    }

    // MARK: - Escaping (spec §"Comments, help text, and type information")

    /// HELP values escape backslash and newline.
    public static func escapeHelp(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.append(c)
            }
        }
        return out
    }

    /// Label values escape backslash, newline, and double-quote.
    public static func escapeLabel(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default: out.append(c)
            }
        }
        return out
    }

    /// Sample values use the shortest unambiguous text rendering. Integers
    /// emit without a decimal point ("3"), non-integers use up to 6
    /// decimals ("0.000123"). Spec allows scientific notation, but human-
    /// readable wins for our small metric set.
    public static func format(value v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v > 0 ? "+Inf" : "-Inf" }
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(format: "%.6f", v)
    }
}
