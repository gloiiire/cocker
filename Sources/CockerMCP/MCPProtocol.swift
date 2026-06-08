import Foundation

// MCP = JSON-RPC 2.0 over stdio, newline-delimited.
// Spec: https://spec.modelcontextprotocol.io/specification/

// MARK: - JSON value (untyped — MCP params/results are free-form JSON)

public indirect enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self)   { self = .bool(b);   return }
        if let i = try? c.decode(Int.self)    { self = .int(i);    return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self)        { self = .array(a);  return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:        try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i):  try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // Convenience accessors used by tool handlers
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool?     { if case .bool(let b) = self   { return b } else { return nil } }
    public var intValue: Int?       {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var arrayValue: [JSONValue]?          { if case .array(let a) = self { return a } else { return nil } }
}

// MARK: - JSON-RPC 2.0 envelope

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONValue?     // null for notifications
    public let method: String
    public let params: JSONValue?
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: JSONValue?, result: JSONValue) {
        self.jsonrpc = "2.0"; self.id = id; self.result = result; self.error = nil
    }
    public init(id: JSONValue?, error: JSONRPCError) {
        self.jsonrpc = "2.0"; self.id = id; self.result = nil; self.error = error
    }
}

public struct JSONRPCError: Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public static let parseError       = -32700
    public static let invalidRequest   = -32600
    public static let methodNotFound   = -32601
    public static let invalidParams    = -32602
    public static let internalError    = -32603

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code; self.message = message; self.data = data
    }
}

// MARK: - MCP-specific payloads

public struct MCPInitializeResult: Codable, Sendable {
    public let protocolVersion: String
    public let capabilities: MCPCapabilities
    public let serverInfo: MCPServerInfo
}

public struct MCPCapabilities: Codable, Sendable {
    public let tools: MCPToolsCapability
}

public struct MCPToolsCapability: Codable, Sendable {
    public let listChanged: Bool
}

public struct MCPServerInfo: Codable, Sendable {
    public let name: String
    public let version: String
}

public struct MCPTool: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue   // JSON Schema describing arguments
}

public struct MCPToolListResult: Codable, Sendable {
    public let tools: [MCPTool]
}

public struct MCPToolCallParams: Codable, Sendable {
    public let name: String
    public let arguments: JSONValue?
}

public struct MCPToolCallResult: Codable, Sendable {
    public let content: [MCPContent]
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.content = [MCPContent(type: "text", text: text)]
        self.isError = isError
    }
}

public struct MCPContent: Codable, Sendable {
    public let type: String
    public let text: String
}
