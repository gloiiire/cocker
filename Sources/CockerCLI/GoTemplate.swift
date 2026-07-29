import Foundation

// Minimal Go-template evaluator for `--format`, the shape Docker users
// reach for constantly :
//
//   cocker inspect web --format '{{.State.Status}}'
//   cocker inspect web --format '{{.NetworkSettings.IPAddress}}'
//   cocker inspect web --format '{{json .State}}'
//
// Scope is deliberately small : field paths, `{{json .X}}`, and literal
// text around them. Control flow (`if`, `range`, pipelines) is NOT
// supported — a template using them is reported as an error instead of
// silently producing something wrong.
//
// Evaluation runs against the JSON the command already produces, so
// `--format` can never drift from the plain output.
public enum GoTemplate {

    public enum Error: Swift.Error, CustomStringConvertible {
        case unsupported(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .unsupported(let s):
                return "unsupported --format template: \(s) (only field paths and `json` are supported)"
            case .malformed(let s):
                return "malformed --format template: \(s)"
            }
        }
    }

    /// Render `template` against one decoded JSON value.
    public static func render(_ template: String, value: Any) throws -> String {
        var out = ""
        var rest = Substring(template)

        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                throw Error.malformed("unclosed {{ in \(template)")
            }
            let expr = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            out += try evaluate(expr, value: value)
            rest = afterOpen[close.upperBound...]
        }
        out += rest
        return out
    }

    /// Evaluate a single `{{ ... }}` expression.
    private static func evaluate(_ expr: String, value: Any) throws -> String {
        if expr.hasPrefix("json ") {
            let path = String(expr.dropFirst("json ".count)).trimmingCharacters(in: .whitespaces)
            let resolved = try resolve(path: path, in: value)
            return jsonString(resolved)
        }
        // Reject what we do not implement rather than mis-render it.
        for keyword in ["if ", "range ", "with ", "printf ", "|"] where expr.contains(keyword) {
            throw Error.unsupported(expr)
        }
        return stringify(try resolve(path: expr, in: value))
    }

    /// Walk a dotted path such as `.State.Health.Status`.
    ///
    /// A missing key yields `<no value>`, matching Go's behaviour for a nil
    /// field, so a script asking for something absent gets a readable
    /// marker rather than a crash.
    private static func resolve(path: String, in value: Any) throws -> Any? {
        var trimmed = path.trimmingCharacters(in: .whitespaces)
        // `{{.}}` — the whole document.
        if trimmed == "." { return value }
        guard trimmed.hasPrefix(".") else { throw Error.unsupported(path) }
        trimmed.removeFirst()

        var current: Any? = value
        for component in trimmed.split(separator: ".") {
            // Templates run against the top-level array `inspect` prints ;
            // index 0 is the natural target for a single container.
            if let array = current as? [Any] {
                current = array.first
            }
            guard let dict = current as? [String: Any] else { return nil }
            current = lookup(String(component), in: dict)
            if current == nil { return nil }
        }
        return current
    }

    /// Case-insensitive key lookup.
    ///
    /// Docker templates are written in Go's exported-field style
    /// (`.State.Status`), while cocker's JSON is lowerCamelCase
    /// (`state.status`). Matching case-insensitively lets the same
    /// template work against both without maintaining a mapping table.
    private static func lookup(_ key: String, in dict: [String: Any]) -> Any? {
        if let exact = dict[key] { return exact }
        let lowered = key.lowercased()
        for (k, v) in dict where k.lowercased() == lowered { return v }
        return nil
    }

    /// Render a resolved value the way Go's text/template would.
    private static func stringify(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<no value>" }
        switch value {
        case let s as String: return s
        case let b as Bool:   return b ? "true" : "false"
        case let n as NSNumber:
            // NSNumber bridges Bool too ; the case above catches those
            // only when the JSON decoder produced a real Bool.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15
                ? String(n.int64Value) : String(d)
        default:
            return jsonString(value)
        }
    }

    private static func jsonString(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }
}
