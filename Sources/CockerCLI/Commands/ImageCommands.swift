import ArgumentParser
import CockerCore
import Foundation

struct ImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "images",
        abstract: "List images"
    )

    @Flag(name: [.short, .customLong("all")], help: "Show all images")
    var all = false

    @Flag(name: [.short, .customLong("quiet")], help: "Only show image IDs")
    var quiet = false

    @Argument(help: "Filter by repository name", completion: .none)
    var repository: String?

    mutating func run() async throws {
        let client = IPCClient()
        let request = try IPCRequest(type: .images, payload: EmptyPayload())
        let response = try await client.send(request)
        var images = try response.decode(ImagesResponse.self).images

        if let repo = repository {
            images = images.filter { $0.repository.contains(repo) || $0.reference.contains(repo) }
        }

        if quiet {
            images.forEach { print($0.id.prefix(12)) }
            return
        }

        let columns: [TableFormatter.Column] = [
            .init("REPOSITORY", min: 20, max: 40),
            .init("TAG", min: 10, max: 20),
            .init("IMAGE ID", min: 12, max: 12),
            .init("CREATED", min: 16),
            .init("SIZE", min: 10),
        ]

        let rows = images.map { img -> [String] in [
            img.repository,
            img.tag,
            String(img.id.prefix(12)),
            relativeTime(from: img.createdAt),
            formatBytes(img.size),
        ]}

        if !rows.isEmpty {
            print(TableFormatter.format(columns: columns, rows: rows))
        }
    }
}

struct RmiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rmi",
        abstract: "Remove one or more images"
    )

    @Flag(name: [.short, .customLong("force")], help: "Force removal")
    var force = false

    @Argument(help: "Image ID(s) or reference(s)")
    var images: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for image in images {
            let payload = ContainerIDRequest(id: image)
            let request = try IPCRequest(type: .rmi, payload: payload)
            do {
                _ = try await client.send(request)
                print("Deleted: \(image)")
            } catch let error as CockerError {
                fputs("Error: \(error.description)\n", stderr)
                if !force { throw error }
            }
        }
    }
}

struct TagCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag",
        abstract: "Create a tag TARGET_IMAGE that refers to SOURCE_IMAGE"
    )

    @Argument(help: "Source image")
    var source: String

    @Argument(help: "Target image")
    var target: String

    mutating func run() async throws {
        let client = IPCClient()

        struct TagPayload: Codable, Sendable { let source, target: String }
        let request = try IPCRequest(type: .tag, payload: TagPayload(source: source, target: target))
        _ = try await client.send(request)
    }
}

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build an image from a Dockerfile"
    )

    @Option(name: [.short, .customLong("tag")], help: "Name and optionally a tag (name:tag)")
    var tag: String = ""

    @Option(name: [.short, .customLong("file")], help: "Dockerfile path")
    var file: String = "Dockerfile"

    @Option(name: .customLong("build-arg"), help: "Build argument (KEY=VALUE)")
    var buildArgs: [String] = []

    @Flag(name: .customLong("no-cache"), help: "Do not use cache")
    var noCache = false

    @Option(name: .customLong("target"), help: "Set the target build stage")
    var target: String?

    @Option(name: .customLong("platform"), help: "Set target platform")
    var platform: String?

    @Argument(help: "Build context path (default: .)")
    var context: String = "."

    mutating func run() async throws {
        var config = BuildConfig(contextPath: context, tag: tag.isEmpty ? "cocker-image:\(Int(Date().timeIntervalSince1970))" : tag)
        config.dockerfile = file
        config.buildArgs = try parseKV(buildArgs)
        config.noCache = noCache
        config.target = target
        config.platform = platform

        print("Building \(ANSI.colored(config.tag, ANSI.cyan)) from \(context)/\(file)...")

        let client = IPCClient()
        let payload = BuildRequest(config: config)
        let request = try IPCRequest(type: .build, payload: payload)

        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status: print(ANSI.colored(event.data, ANSI.cyan))
            case .error: fputs("\nError: \(event.data)\n", stderr)
            }
        }
    }

    private func parseKV(_ pairs: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }
}

struct SaveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Save one or more images to a tar archive"
    )

    @Option(name: [.short, .customLong("output")], help: "Write to a file, instead of STDOUT")
    var output: String

    @Argument(help: "Image name or ID")
    var image: String

    mutating func run() async throws {
        let client = IPCClient()
        let payload = SaveRequest(image: image)
        let request = try IPCRequest(type: .save, payload: payload)
        let response = try await client.send(request)
        let result = try response.decode(SaveResponse.self)

        let url = URL(fileURLWithPath: output.hasPrefix("/") ? output : FileManager.default.currentDirectoryPath + "/" + output)
        try result.tarData.write(to: url)
        print("Image \(image) saved to \(output)")
    }
}

struct LoadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "load",
        abstract: "Load an image from a tar archive"
    )

    @Option(name: [.short, .customLong("input")], help: "Read from tar archive file")
    var input: String

    mutating func run() async throws {
        let url = URL(fileURLWithPath: input.hasPrefix("/") ? input : FileManager.default.currentDirectoryPath + "/" + input)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fputs("Error: file not found: \(input)\n", stderr)
            throw ExitCode.failure
        }
        let tarData = try Data(contentsOf: url)
        let client = IPCClient()
        let payload = LoadRequest(tarData: tarData)
        let request = try IPCRequest(type: .load, payload: payload)
        let response = try await client.send(request)
        let msg = try response.decode(String.self)
        print(msg)
    }
}

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show the history of an image"
    )

    @Flag(name: [.short, .customLong("quiet")], help: "Only show image IDs")
    var quiet = false

    @Argument(help: "Image name or ID")
    var image: String

    mutating func run() async throws {
        let client = IPCClient()
        let payload = ContainerIDRequest(id: image)
        let request = try IPCRequest(type: .imageHistory, payload: payload)
        let response = try await client.send(request)
        let result = try response.decode(ImageHistoryResponse.self)

        if quiet {
            result.entries.forEach { print(String($0.id.prefix(12))) }
            return
        }

        let columns: [TableFormatter.Column] = [
            .init("IMAGE", min: 12, max: 12),
            .init("CREATED", min: 16),
            .init("CREATED BY", min: 40, max: 60),
            .init("SIZE", min: 10),
            .init("COMMENT", min: 10),
        ]

        let rows = result.entries.map { e -> [String] in [
            String(e.id.prefix(12)),
            relativeTime(from: e.createdAt),
            e.createdBy,
            formatBytes(e.size),
            e.comment,
        ]}

        if !rows.isEmpty { print(TableFormatter.format(columns: columns, rows: rows)) }
    }
}

struct ImagePruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Remove unused images"
    )

    @Flag(name: [.short, .customLong("force")], help: "Do not prompt for confirmation")
    var force = false

    mutating func run() async throws {
        if !force {
            print("WARNING! This will remove all images not referenced by any container.")
            print("Are you sure you want to continue? [y/N] ", terminator: "")
            let answer = readLine()?.lowercased() ?? "n"
            guard answer == "y" || answer == "yes" else { return }
        }

        let client = IPCClient()
        let request = try IPCRequest(type: .imagePrune, payload: EmptyPayload())
        let response = try await client.send(request)
        let result = try response.decode(PruneResponse.self)

        if result.imagesDeleted.isEmpty {
            print("Total reclaimed space: 0 B")
        } else {
            print("Deleted Images:")
            result.imagesDeleted.forEach { print("untagged: \($0)") }
            print("Total reclaimed space: \(formatBytes(result.spaceReclaimed))")
        }
    }
}

struct ImageInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Manage images",
        subcommands: [
            ImagesCommand.self,
            BuildCommand.self,
            RmiCommand.self,
            TagCommand.self,
            ImageInspectSubcommand.self,
            HistoryCommand.self,
            ImagePruneCommand.self,
        ],
        defaultSubcommand: ImagesCommand.self
    )
}

struct ImageInspectSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Display detailed information on one or more images"
    )

    @Argument(help: "Image ID(s) or reference(s)")
    var images: [String]

    mutating func run() async throws {
        let client = IPCClient()
        var results: [ImageInfo] = []

        for image in images {
            let payload = ContainerIDRequest(id: image)
            let request = try IPCRequest(type: .imageInspect, payload: payload)
            let response = try await client.send(request)
            results.append(try response.decode(ImageInfo.self))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(results), encoding: .utf8) ?? "")
    }
}
