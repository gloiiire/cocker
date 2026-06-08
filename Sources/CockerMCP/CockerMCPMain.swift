import Foundation

// Entry point. Wires the tool catalog into an MCPServer and runs the
// stdio loop. All structured I/O happens over stdout — anything we want
// the user (or Claude Desktop logs) to see goes to stderr.

@main
struct CockerMCPMain {
    static func main() async {
        FileHandle.standardError.write(Data("cocker-mcp starting (docker.sock: \(DockerHTTPClient.defaultSocketPath))\n".utf8))

        let docker = DockerHTTPClient()
        var tools: [ToolDefinition] = []
        tools.append(contentsOf: ContainerTools.all(client: docker))
        tools.append(contentsOf: ImageTools.all(client: docker))
        tools.append(contentsOf: VolumeNetworkTools.all(client: docker))
        tools.append(contentsOf: SystemAndComposeTools.all(http: docker))

        let server = MCPServer(tools: tools)
        await server.run()
    }
}
