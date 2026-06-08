import Foundation

enum VolumeNetworkTools {
    static func all(client: DockerHTTPClient) -> [ToolDefinition] {
        [
            volumesList(client: client),
            volumeInspect(client: client),
            volumeCreate(client: client),
            volumeRm(client: client),
            networksList(client: client),
            networkInspect(client: client),
            networkCreate(client: client),
            networkRm(client: client),
        ]
    }

    // MARK: - Volumes

    private static func volumesList(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_volumes_ls",
            description: "List named volumes.",
            inputSchema: schema(#"{ "type": "object", "properties": {} }"#)
        ) { _ in
            let resp = try await client.get("/volumes")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func volumeInspect(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_volume_inspect",
            description: "Inspect a named volume.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["name"],
              "properties": { "name": { "type": "string" } }
            }
            """#)
        ) { args in
            let name = try args.requireString("name")
            let resp = try await client.get("/volumes/\(URLBuilder.escape(name))")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func volumeCreate(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_volume_create",
            description: "Create a named volume.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["name"],
              "properties": {
                "name":   { "type": "string" },
                "driver": { "type": "string", "description": "Volume driver (default 'local')" }
              }
            }
            """#)
        ) { args in
            let name = try args.requireString("name")
            var body: [String: Any] = ["Name": name]
            if let d = args.optionalString("driver") { body["Driver"] = d }
            let data = try JSONSerialization.data(withJSONObject: body)
            let resp = try await client.post("/volumes/create", json: data)
            guard resp.isSuccess else { return errorResult("volume create failed (\(resp.status)): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func volumeRm(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_volume_rm",
            description: "Remove a named volume. Fails if a container references it (use `force=true` to override).",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["name"],
              "properties": {
                "name":  { "type": "string" },
                "force": { "type": "boolean" }
              }
            }
            """#)
        ) { args in
            let name = try args.requireString("name")
            var q: [String: String] = [:]
            if args.optionalBool("force") { q["force"] = "1" }
            let resp = try await client.delete("/volumes/\(URLBuilder.escape(name))" + URLBuilder.query(q))
            guard resp.isSuccess else { return errorResult("volume rm failed (\(resp.status)): \(resp.bodyString)") }
            return textResult("removed volume \(name)")
        }
    }

    // MARK: - Networks

    private static func networksList(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_networks_ls",
            description: "List networks.",
            inputSchema: schema(#"{ "type": "object", "properties": {} }"#)
        ) { _ in
            let resp = try await client.get("/networks")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func networkInspect(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_network_inspect",
            description: "Inspect a network by id or name.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["id"],
              "properties": { "id": { "type": "string" } }
            }
            """#)
        ) { args in
            let id = try args.requireString("id")
            let resp = try await client.get("/networks/\(URLBuilder.escape(id))")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func networkCreate(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_network_create",
            description: "Create a bridge network.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["name"],
              "properties": {
                "name":   { "type": "string" },
                "subnet": { "type": "string", "description": "CIDR (e.g. 10.55.0.0/24)" }
              }
            }
            """#)
        ) { args in
            let name = try args.requireString("name")
            var body: [String: Any] = ["Name": name, "Driver": "bridge"]
            if let sub = args.optionalString("subnet") {
                body["IPAM"] = ["Config": [["Subnet": sub]]]
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            let resp = try await client.post("/networks/create", json: data)
            guard resp.isSuccess else { return errorResult("network create failed (\(resp.status)): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func networkRm(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_network_rm",
            description: "Remove a network by id or name.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["id"],
              "properties": { "id": { "type": "string" } }
            }
            """#)
        ) { args in
            let id = try args.requireString("id")
            let resp = try await client.delete("/networks/\(URLBuilder.escape(id))")
            guard resp.isSuccess else { return errorResult("network rm failed (\(resp.status)): \(resp.bodyString)") }
            return textResult("removed network \(id)")
        }
    }
}
