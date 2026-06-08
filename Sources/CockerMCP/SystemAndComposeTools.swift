import Foundation
import CockerCore

// System info, version, events, and compose. Most go through the Docker
// socket; compose lives in cockerd and is only reachable over the native
// IPC socket — so we reuse CockerCore.IPCClient for those.

enum SystemAndComposeTools {
    static func all(http: DockerHTTPClient) -> [ToolDefinition] {
        [
            info(http: http),
            version(http: http),
            events(http: http),
            composeLs(),
            composePs(),
            composeUp(),
            composeDown(),
        ]
    }

    // MARK: - System (Docker socket)

    private static func info(http: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_info",
            description: "Daemon-wide info: container/image/volume counts, kernel, architecture, resource totals, socket paths.",
            inputSchema: schema(#"{ "type": "object", "properties": {} }"#)
        ) { _ in
            let resp = try await http.get("/info")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func version(http: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_version",
            description: "Daemon + API version.",
            inputSchema: schema(#"{ "type": "object", "properties": {} }"#)
        ) { _ in
            let resp = try await http.get("/version")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func events(http: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_events",
            description: "Recent daemon events since a given time. Non-streaming snapshot — pass `since` and `until` as RFC3339 timestamps or unix epoch seconds.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "since": { "type": "string", "description": "RFC3339 timestamp or unix seconds" },
                "until": { "type": "string", "description": "RFC3339 timestamp or unix seconds" }
              }
            }
            """#)
        ) { args in
            var q: [String: String] = [:]
            if let s = args.optionalString("since") { q["since"] = s }
            if let u = args.optionalString("until") { q["until"] = u }
            // Default until=now so the stream completes immediately.
            if q["until"] == nil { q["until"] = String(Int(Date().timeIntervalSince1970)) }
            let resp = try await http.get("/events" + URLBuilder.query(q))
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return textResult(resp.bodyString)
        }
    }

    // MARK: - Compose (native IPC)

    private static func composeLs() -> ToolDefinition {
        ToolDefinition(
            name: "cocker_compose_ls",
            description: "List known compose projects.",
            inputSchema: schema(#"{ "type": "object", "properties": {} }"#)
        ) { _ in
            try await runIPC(.composeLs, payload: EmptyPayload()) { resp in
                jsonResult(resp.payload)
            }
        }
    }

    private static func composePs() -> ToolDefinition {
        ToolDefinition(
            name: "cocker_compose_ps",
            description: "List services for a compose project.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["composePath"],
              "properties": {
                "composePath": { "type": "string", "description": "Absolute path to docker-compose.yml" },
                "projectName": { "type": "string" }
              }
            }
            """#)
        ) { args in
            let path = try args.requireString("composePath")
            let req = ComposeRequest(composePath: path, projectName: args.optionalString("projectName"))
            return try await runIPC(.composePs, payload: req) { resp in
                jsonResult(resp.payload)
            }
        }
    }

    private static func composeUp() -> ToolDefinition {
        ToolDefinition(
            name: "cocker_compose_up",
            description: "Bring up a compose project (detached). Returns the container ids that were started.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["composePath"],
              "properties": {
                "composePath": { "type": "string", "description": "Absolute path to docker-compose.yml" },
                "projectName": { "type": "string" },
                "services":    { "type": "array", "items": { "type": "string" } }
              }
            }
            """#)
        ) { args in
            let path = try args.requireString("composePath")
            var services: [String] = []
            if case .object(let obj) = args, case .array(let a) = obj["services"] ?? .null {
                services = a.compactMap { $0.stringValue }
            }
            let req = ComposeRequest(
                composePath: path,
                projectName: args.optionalString("projectName"),
                services: services,
                detach: true
            )
            return try await runIPC(.composeUp, payload: req) { resp in
                jsonResult(resp.payload)
            }
        }
    }

    private static func composeDown() -> ToolDefinition {
        ToolDefinition(
            name: "cocker_compose_down",
            description: "Bring down a compose project. Pass `removeVolumes=true` to also drop named volumes.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["composePath"],
              "properties": {
                "composePath":   { "type": "string", "description": "Absolute path to docker-compose.yml" },
                "projectName":   { "type": "string" },
                "removeVolumes": { "type": "boolean" }
              }
            }
            """#)
        ) { args in
            let path = try args.requireString("composePath")
            let req = ComposeRequest(
                composePath: path,
                projectName: args.optionalString("projectName"),
                removeVolumes: args.optionalBool("removeVolumes")
            )
            return try await runIPC(.composeDown, payload: req) { resp in
                jsonResult(resp.payload)
            }
        }
    }

    // MARK: - IPC plumbing

    private static func runIPC<P: Encodable & Sendable>(
        _ type: IPCRequestType,
        payload: P,
        shape: (IPCResponse) -> MCPToolCallResult
    ) async throws -> MCPToolCallResult {
        let client = IPCClient()
        let req = try IPCRequest(type: type, payload: payload)
        do {
            let resp = try await client.send(req)
            await client.disconnect()
            return shape(resp)
        } catch {
            await client.disconnect()
            return errorResult("native IPC failed: \(error)")
        }
    }
}
