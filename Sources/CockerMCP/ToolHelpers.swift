import Foundation

// Helpers used by every tool group to build input schemas, parse arguments,
// and shape results into the MCP "text content" payload (the only content
// type Claude renders natively today).

enum ToolError: Error, CustomStringConvertible {
    case missingArgument(String)
    case wrongType(String)

    var description: String {
        switch self {
        case .missingArgument(let n): return "missing required argument: \(n)"
        case .wrongType(let n): return "wrong type for argument: \(n)"
        }
    }
}

// JSON Schema parsed from a string literal — keeps the tool definitions
// readable instead of pages of nested `.object([...])`.
func schema(_ json: String) -> JSONValue {
    guard let data = json.data(using: .utf8),
          let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        return .object([:])
    }
    return v
}

// Argument extraction. Tools call these directly on the incoming JSONValue.
extension JSONValue {
    func requireString(_ key: String) throws -> String {
        guard case .object(let obj) = self, let v = obj[key]?.stringValue else {
            throw ToolError.missingArgument(key)
        }
        return v
    }

    func optionalString(_ key: String) -> String? {
        if case .object(let obj) = self { return obj[key]?.stringValue }
        return nil
    }

    func optionalBool(_ key: String, default def: Bool = false) -> Bool {
        if case .object(let obj) = self { return obj[key]?.boolValue ?? def }
        return def
    }

    func optionalInt(_ key: String) -> Int? {
        if case .object(let obj) = self { return obj[key]?.intValue }
        return nil
    }
}

// Tools return text. For JSON-shaped responses we pretty-print so Claude
// can read structure at a glance, falling back to the raw string when the
// upstream body isn't JSON.
func textResult(_ s: String) -> MCPToolCallResult {
    MCPToolCallResult(text: s)
}

func jsonResult(_ data: Data) -> MCPToolCallResult {
    if let pretty = prettyPrintJSON(data) {
        return MCPToolCallResult(text: pretty)
    }
    return MCPToolCallResult(text: String(data: data, encoding: .utf8) ?? "")
}

func errorResult(_ msg: String) -> MCPToolCallResult {
    MCPToolCallResult(text: msg, isError: true)
}

private func prettyPrintJSON(_ data: Data) -> String? {
    guard !data.isEmpty,
          let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          let pretty = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: pretty, encoding: .utf8) else {
        return nil
    }
    return s
}
