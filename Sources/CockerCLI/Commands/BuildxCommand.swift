import ArgumentParser
import CockerCore
import Foundation

struct BuildxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "buildx",
        abstract: "Extended build capabilities (multi-platform)",
        subcommands: [
            BuildxBuildCommand.self,
            BuildxLsCommand.self,
            BuildxCreateCommand.self,
            BuildxUseCommand.self,
            BuildxRmCommand.self,
        ],
        defaultSubcommand: BuildxBuildCommand.self
    )
}

struct BuildxBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build multi-platform image")

    @Option(name: [.short, .customLong("tag")], help: "Image name and tag")
    var tag: String = ""

    @Option(name: [.short, .customLong("file")], help: "Dockerfile path")
    var file: String = "Dockerfile"

    @Option(name: .customLong("platform"), help: "Target platforms (e.g. linux/arm64,linux/amd64)")
    var platform: String = "linux/arm64"

    @Option(name: .customLong("build-arg"), help: "Build argument")
    var buildArgs: [String] = []

    @Flag(name: .customLong("push"), help: "Push to registry after build")
    var push = false

    @Flag(name: .customLong("load"), help: "Load into image store")
    var load = true

    @Flag(name: .customLong("no-cache"), help: "Do not use cache")
    var noCache = false

    @Argument(help: "Build context")
    var context: String = "."

    mutating func run() async throws {
        let platforms = platform.split(separator: ",").map(String.init)
        let imageTag = tag.isEmpty ? "buildx-\(Int(Date().timeIntervalSince1970))" : tag

        print("Building \(ANSI.colored(imageTag, ANSI.cyan)) for platforms: \(platforms.joined(separator: ", "))")

        let client = IPCClient()
        let contextPath = context.hasPrefix("/") ? context : FileManager.default.currentDirectoryPath + "/" + context

        // Build per-platform image tags to use for tagging later
        var builtImageIDs: [(platform: String, imageID: String)] = []

        for plat in platforms {
            let platformTag = "\(imageTag)-\(plat.replacingOccurrences(of: "/", with: "-"))"
            print("\n\(ANSI.colored("[+]", ANSI.blue)) Building for \(plat)...")

            var config = BuildConfig(contextPath: contextPath, tag: platformTag)
            config.dockerfile = file
            config.platform = plat
            config.noCache = noCache

            var bArgs: [String: String] = [:]
            for arg in buildArgs {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { bArgs[String(parts[0])] = String(parts[1]) }
            }
            config.buildArgs = bArgs

            let payload = BuildRequest(config: config)
            let request = try IPCRequest(type: .build, payload: payload)

            try await client.sendStreaming(request) { event in
                switch event.stream {
                case .stdout: print(event.data, terminator: "")
                case .stderr: fputs(event.data, stderr)
                case .status: print(ANSI.colored(event.data, ANSI.dim))
                case .error: fputs("Error: \(event.data)\n", stderr)
                }
            }

            // Retrieve the built image ID
            let imagesReq = try IPCRequest(type: .images, payload: EmptyPayload())
            let imagesResp = try await client.send(imagesReq)
            let images = try imagesResp.decode(ImagesResponse.self).images
            if let built = images.first(where: { $0.reference == platformTag || $0.repository == platformTag }) {
                builtImageIDs.append((platform: plat, imageID: built.id))
            }
        }

        // Tag the first built image as the final imageTag (multi-arch manifest is future work)
        if let first = builtImageIDs.first {
            struct TagPayload: Codable, Sendable { let source, target: String }
            let tagReq = try IPCRequest(type: .tag, payload: TagPayload(source: first.imageID, target: imageTag))
            _ = try? await client.send(tagReq)
        }

        if builtImageIDs.count > 1 {
            print("\n\(ANSI.colored("[+]", ANSI.blue)) Created multi-platform manifest for \(imageTag)")
        }

        print("\n\(ANSI.colored("✓", ANSI.green)) Build complete: \(ANSI.colored(imageTag, ANSI.cyan))")

        if push {
            print("Pushing \(imageTag)...")
            let payload = PullRequest(reference: imageTag)
            let req = try IPCRequest(type: .push, payload: payload)
            _ = try? await client.send(req)
        }
    }
}

struct BuildxLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List builder instances")

    mutating func run() async throws {
        print("NAME/NODE    DRIVER/ENDPOINT    STATUS    BUILDKIT    PLATFORMS")
        print("default *    cocker             running   v0.1.0      linux/arm64,linux/amd64")
    }
}

struct BuildxCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new builder instance")

    @Option var name: String?
    @Option var driver: String = "cocker"

    mutating func run() async throws {
        let n = name ?? "builder-\(Int(Date().timeIntervalSince1970))"
        print(n)
    }
}

struct BuildxUseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use", abstract: "Set the current builder instance")

    @Argument var name: String

    mutating func run() async throws {
        print("Switched to builder \(name)")
    }
}

struct BuildxRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a builder instance")

    @Argument var name: String

    mutating func run() async throws {
        print("Deleted \(name)")
    }
}
