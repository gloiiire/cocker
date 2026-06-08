import Foundation

enum ContainerTools {
    static func all(client: DockerHTTPClient) -> [ToolDefinition] {
        [
            list(client: client),
            inspect(client: client),
            logs(client: client),
            stats(client: client),
            start(client: client),
            stop(client: client),
            restart(client: client),
            remove(client: client),
            run(client: client),
            exec(client: client),
        ]
    }

    // MARK: - Read

    private static func list(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_ps",
            description: "List containers. By default returns only running ones. Set `all=true` to include stopped containers.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "all":   { "type": "boolean", "description": "Include stopped containers" },
                "limit": { "type": "integer", "description": "Max number of containers to return" }
              }
            }
            """#)
        ) { args in
            var q: [String: String] = [:]
            if args.optionalBool("all") { q["all"] = "1" }
            if let limit = args.optionalInt("limit") { q["limit"] = String(limit) }
            let resp = try await client.get("/containers/json" + URLBuilder.query(q))
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func inspect(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_inspect",
            description: "Inspect a container by id or name. Returns the full Docker inspect payload (config, state, network, healthcheck).",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["id"],
              "properties": {
                "id": { "type": "string", "description": "Container id or name" }
              }
            }
            """#)
        ) { args in
            let id = try args.requireString("id")
            let resp = try await client.get("/containers/\(URLBuilder.escape(id))/json")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func logs(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_logs",
            description: "Fetch the last N log lines of a container. Non-streaming (follow=false). Use `tail` to bound output.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["id"],
              "properties": {
                "id":         { "type": "string", "description": "Container id or name" },
                "tail":       { "type": "integer", "description": "Number of trailing lines (default 100)" },
                "timestamps": { "type": "boolean" },
                "stdout":     { "type": "boolean", "description": "Include stdout (default true)" },
                "stderr":     { "type": "boolean", "description": "Include stderr (default true)" }
              }
            }
            """#)
        ) { args in
            let id = try args.requireString("id")
            var q: [String: String] = [
                "stdout": args.optionalBool("stdout", default: true) ? "1" : "0",
                "stderr": args.optionalBool("stderr", default: true) ? "1" : "0",
                "tail":   String(args.optionalInt("tail") ?? 100),
            ]
            if args.optionalBool("timestamps") { q["timestamps"] = "1" }
            let resp = try await client.get("/containers/\(URLBuilder.escape(id))/logs" + URLBuilder.query(q))
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            // Docker multiplexes stdout/stderr with an 8-byte header per
            // frame when the container has no TTY. Strip those headers so
            // Claude sees readable text.
            return textResult(demuxDockerLog(resp.body))
        }
    }

    private static func stats(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_stats",
            description: "One-shot resource usage snapshot for a container (CPU, memory, network, block I/O).",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["id"],
              "properties": { "id": { "type": "string" } }
            }
            """#)
        ) { args in
            let id = try args.requireString("id")
            let resp = try await client.get("/containers/\(URLBuilder.escape(id))/stats?stream=false")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    // MARK: - Lifecycle

    private static func start(client: DockerHTTPClient) -> ToolDefinition {
        lifecycle(
            client: client,
            name: "cocker_start",
            description: "Start an existing stopped container.",
            verb: "start"
        )
    }

    private static func stop(client: DockerHTTPClient) -> ToolDefinition {
        lifecycle(
            client: client,
            name: "cocker_stop",
            description: "Stop a running container (graceful, then SIGKILL after timeout).",
            verb: "stop"
        )
    }

    private static func restart(client: DockerHTTPClient) -> ToolDefinition {
        lifecycle(
            client: client,
            name: "cocker_restart",
            description: "Restart a container.",
            verb: "restart"
        )
    }

    private static func lifecycle(client: DockerHTTPClient, name: String, description: String, verb: String) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["id"],
              "properties": { "id": { "type": "string" } }
            }
            """#)
        ) { args in
            let id = try args.requireString("id")
            let resp = try await client.post("/containers/\(URLBuilder.escape(id))/\(verb)")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return textResult("\(verb): ok (\(id))")
        }
    }

    private static func remove(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_rm",
            description: "Remove a container. By default fails if running — pass `force=true` to kill+remove.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["id"],
              "properties": {
                "id":      { "type": "string" },
                "force":   { "type": "boolean", "description": "Kill and remove" },
                "volumes": { "type": "boolean", "description": "Also remove anonymous volumes" }
              }
            }
            """#)
        ) { args in
            let id = try args.requireString("id")
            var q: [String: String] = [:]
            if args.optionalBool("force")   { q["force"] = "1" }
            if args.optionalBool("volumes") { q["v"] = "1" }
            let resp = try await client.delete("/containers/\(URLBuilder.escape(id))" + URLBuilder.query(q))
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return textResult("rm: ok (\(id))")
        }
    }

    // MARK: - Create / Exec

    private static func run(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_run",
            description: "Create and start a container from an image. Returns the new container id.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["image"],
              "properties": {
                "image":   { "type": "string", "description": "Image reference (e.g. nginx:alpine)" },
                "name":    { "type": "string", "description": "Optional container name" },
                "cmd":     { "type": "array", "items": { "type": "string" }, "description": "Command and args" },
                "env":     { "type": "array", "items": { "type": "string" }, "description": "Env vars as KEY=VALUE" },
                "ports":   { "type": "array", "items": { "type": "string" }, "description": "Port mappings (e.g. '8080:80')" },
                "detach":  { "type": "boolean", "description": "Detached (default true)" }
              }
            }
            """#)
        ) { args in
            let image = try args.requireString("image")
            var spec: [String: Any] = ["Image": image]
            if case .object(let obj) = args {
                if case .array(let a) = obj["cmd"] ?? .null {
                    spec["Cmd"] = a.compactMap { $0.stringValue }
                }
                if case .array(let a) = obj["env"] ?? .null {
                    spec["Env"] = a.compactMap { $0.stringValue }
                }
                if case .array(let a) = obj["ports"] ?? .null {
                    var bindings: [String: [[String: String]]] = [:]
                    var exposed: [String: [String: String]] = [:]
                    for p in a.compactMap({ $0.stringValue }) {
                        let parts = p.split(separator: ":").map(String.init)
                        guard parts.count == 2 else { continue }
                        let key = "\(parts[1])/tcp"
                        bindings[key] = [["HostPort": parts[0]]]
                        exposed[key] = [:]
                    }
                    spec["HostConfig"] = ["PortBindings": bindings]
                    spec["ExposedPorts"] = exposed
                }
            }
            guard let body = try? JSONSerialization.data(withJSONObject: spec) else {
                return errorResult("failed to serialize run spec")
            }
            var path = "/containers/create"
            if let name = args.optionalString("name") {
                path += URLBuilder.query(["name": name])
            }
            let createResp = try await client.post(path, json: body)
            guard createResp.isSuccess else {
                return errorResult("create failed (\(createResp.status)): \(createResp.bodyString)")
            }
            let id = (try? JSONSerialization.jsonObject(with: createResp.body) as? [String: Any])?["Id"] as? String ?? ""
            let startResp = try await client.post("/containers/\(URLBuilder.escape(id))/start")
            guard startResp.isSuccess else {
                return errorResult("created \(id) but start failed (\(startResp.status)): \(startResp.bodyString)")
            }
            return textResult("started \(id)")
        }
    }

    private static func exec(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_exec",
            description: "Run a one-off command inside a running container. Returns captured stdout/stderr after the command exits.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["id", "cmd"],
              "properties": {
                "id":  { "type": "string" },
                "cmd": { "type": "array", "items": { "type": "string" } }
              }
            }
            """#)
        ) { args in
            let id = try args.requireString("id")
            guard case .object(let obj) = args,
                  case .array(let cmd) = obj["cmd"] ?? .null else {
                throw ToolError.missingArgument("cmd")
            }
            let cmdStrs = cmd.compactMap { $0.stringValue }
            let createSpec: [String: Any] = [
                "AttachStdout": true,
                "AttachStderr": true,
                "Cmd": cmdStrs,
            ]
            let createBody = try JSONSerialization.data(withJSONObject: createSpec)
            let createResp = try await client.post("/containers/\(URLBuilder.escape(id))/exec", json: createBody)
            guard createResp.isSuccess else {
                return errorResult("exec create failed (\(createResp.status)): \(createResp.bodyString)")
            }
            guard let execId = (try? JSONSerialization.jsonObject(with: createResp.body) as? [String: Any])?["Id"] as? String else {
                return errorResult("exec create: no Id in response")
            }
            let startBody = try JSONSerialization.data(withJSONObject: ["Detach": false, "Tty": false])
            let startResp = try await client.post("/exec/\(execId)/start", json: startBody)
            guard startResp.isSuccess else {
                return errorResult("exec start failed (\(startResp.status)): \(startResp.bodyString)")
            }
            return textResult(demuxDockerLog(startResp.body))
        }
    }
}

// MARK: - Docker stream demuxer

// Docker prefixes each chunk with an 8-byte header when there's no TTY:
//   [stream(1)] [0 0 0] [size(4 BE)] [payload(size)]
// stream: 1 = stdout, 2 = stderr.
// Older / cocker code paths sometimes ship raw bytes. We try to demux but
// fall back to the raw body if the headers don't look right.
func demuxDockerLog(_ data: Data) -> String {
    var out = ""
    var i = data.startIndex
    while i < data.endIndex {
        let remaining = data.distance(from: i, to: data.endIndex)
        guard remaining >= 8 else { break }
        let stream = data[i]
        // Sanity: must be 0/1/2/3 (stdin/stdout/stderr/system).
        guard stream <= 3 else { return String(data: data, encoding: .utf8) ?? "" }
        let sizeStart = data.index(i, offsetBy: 4)
        let size = Int(data[sizeStart]) << 24
            | Int(data[data.index(after: sizeStart)]) << 16
            | Int(data[data.index(sizeStart, offsetBy: 2)]) << 8
            | Int(data[data.index(sizeStart, offsetBy: 3)])
        let payloadStart = data.index(i, offsetBy: 8)
        guard let payloadEnd = data.index(payloadStart, offsetBy: size, limitedBy: data.endIndex) else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        out += String(data: data[payloadStart..<payloadEnd], encoding: .utf8) ?? ""
        i = payloadEnd
    }
    return out.isEmpty ? (String(data: data, encoding: .utf8) ?? "") : out
}
