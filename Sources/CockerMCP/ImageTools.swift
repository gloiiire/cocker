import Foundation

enum ImageTools {
    static func all(client: DockerHTTPClient) -> [ToolDefinition] {
        [list(client: client), inspect(client: client), pull(client: client), remove(client: client)]
    }

    private static func list(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_images",
            description: "List images present in the local store.",
            inputSchema: schema(#"""
            { "type": "object", "properties": {} }
            """#)
        ) { _ in
            let resp = try await client.get("/images/json")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func inspect(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_image_inspect",
            description: "Inspect an image by id or reference (e.g. nginx:alpine).",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["name"],
              "properties": { "name": { "type": "string" } }
            }
            """#)
        ) { args in
            let name = try args.requireString("name")
            let resp = try await client.get("/images/\(URLBuilder.escape(name))/json")
            guard resp.isSuccess else { return errorResult("docker API \(resp.status): \(resp.bodyString)") }
            return jsonResult(resp.body)
        }
    }

    private static func pull(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_pull",
            description: "Pull an image from a registry. Blocks until the pull completes.",
            inputSchema: schema(#"""
            {
              "type": "object",
              "required": ["reference"],
              "properties": {
                "reference": { "type": "string", "description": "Image reference (e.g. nginx:alpine)" }
              }
            }
            """#)
        ) { args in
            let ref = try args.requireString("reference")
            let resp = try await client.post("/images/create" + URLBuilder.query(["fromImage": ref]))
            guard resp.isSuccess else { return errorResult("pull failed (\(resp.status)): \(resp.bodyString)") }
            // Response is a stream of JSON status lines — keep last for context.
            let lines = resp.bodyString.split(separator: "\n").suffix(5)
            return textResult("pulled \(ref)\n" + lines.joined(separator: "\n"))
        }
    }

    private static func remove(client: DockerHTTPClient) -> ToolDefinition {
        ToolDefinition(
            name: "cocker_rmi",
            description: "Remove an image by id or reference. Pass `force=true` to remove even if in use by stopped containers.",
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
            let resp = try await client.delete("/images/\(URLBuilder.escape(name))" + URLBuilder.query(q))
            guard resp.isSuccess else { return errorResult("rmi failed (\(resp.status)): \(resp.bodyString)") }
            return textResult("removed \(name)")
        }
    }
}
