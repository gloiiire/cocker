import Foundation
import CockerCore

// Newline-delimited JSON-RPC dispatcher reading stdin, writing stdout.
// Stderr is reserved for logs — MCP clients (Claude Desktop) discard it
// from the protocol stream but show it in their own logs.

public actor MCPServer {
    private let tools: [String: ToolHandler]
    private let toolDescriptors: [MCPTool]

    public init(tools: [ToolDefinition]) {
        var map: [String: ToolHandler] = [:]
        var descriptors: [MCPTool] = []
        for t in tools {
            map[t.descriptor.name] = t.handler
            descriptors.append(t.descriptor)
        }
        self.tools = map
        self.toolDescriptors = descriptors
    }

    public func run() async {
        let stdin = FileHandle.standardInput
        var buffer = Data()

        while let chunk = try? stdin.read(upToCount: 4096), !chunk.isEmpty {
            buffer.append(chunk)
            while let nlIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: nlIndex)
                buffer.removeSubrange(buffer.startIndex...nlIndex)
                if line.isEmpty { continue }
                await handleLine(Data(line))
            }
        }
    }

    private func handleLine(_ data: Data) async {
        let decoder = JSONDecoder()
        let req: JSONRPCRequest
        do {
            req = try decoder.decode(JSONRPCRequest.self, from: data)
        } catch {
            // Can't extract id → respond with null id per spec
            writeResponse(JSONRPCResponse(
                id: nil,
                error: JSONRPCError(code: JSONRPCError.parseError, message: "Parse error: \(error)")
            ))
            return
        }

        // Notifications (no id) get no response.
        let isNotification = (req.id == nil)

        switch req.method {
        case "initialize":
            let result = MCPInitializeResult(
                protocolVersion: "2024-11-05",
                capabilities: MCPCapabilities(tools: MCPToolsCapability(listChanged: false)),
                serverInfo: MCPServerInfo(name: "cocker-mcp", version: CockerVersion.version)
            )
            respond(id: req.id, result: result)

        case "notifications/initialized":
            return  // client ready signal, no response expected

        case "tools/list":
            let result = MCPToolListResult(tools: toolDescriptors)
            respond(id: req.id, result: result)

        case "tools/call":
            await handleToolCall(req)

        case "ping":
            respond(id: req.id, result: [String: JSONValue]())

        default:
            if isNotification { return }
            writeResponse(JSONRPCResponse(
                id: req.id,
                error: JSONRPCError(code: JSONRPCError.methodNotFound, message: "Method not found: \(req.method)")
            ))
        }
    }

    private func handleToolCall(_ req: JSONRPCRequest) async {
        guard
            let paramsValue = req.params,
            let params = try? roundTrip(paramsValue, as: MCPToolCallParams.self)
        else {
            writeResponse(JSONRPCResponse(
                id: req.id,
                error: JSONRPCError(code: JSONRPCError.invalidParams, message: "Invalid tools/call params")
            ))
            return
        }

        guard let handler = tools[params.name] else {
            let result = MCPToolCallResult(text: "Unknown tool: \(params.name)", isError: true)
            respond(id: req.id, result: result)
            return
        }

        do {
            let result = try await handler(params.arguments ?? .null)
            respond(id: req.id, result: result)
        } catch {
            let result = MCPToolCallResult(text: "Tool error: \(error)", isError: true)
            respond(id: req.id, result: result)
        }
    }

    // MARK: - I/O helpers

    private func respond<T: Encodable>(id: JSONValue?, result: T) {
        do {
            let data = try JSONEncoder().encode(result)
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            writeResponse(JSONRPCResponse(id: id, result: value))
        } catch {
            writeResponse(JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: JSONRPCError.internalError, message: "Encode failure: \(error)")
            ))
        }
    }

    private func writeResponse(_ resp: JSONRPCResponse) {
        guard var data = try? JSONEncoder().encode(resp) else { return }
        data.append(0x0A)  // newline-delimited
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private func roundTrip<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Tool registration

public typealias ToolHandler = @Sendable (JSONValue) async throws -> MCPToolCallResult

public struct ToolDefinition: Sendable {
    public let descriptor: MCPTool
    public let handler: ToolHandler

    public init(name: String, description: String, inputSchema: JSONValue, handler: @escaping ToolHandler) {
        self.descriptor = MCPTool(name: name, description: description, inputSchema: inputSchema)
        self.handler = handler
    }
}
