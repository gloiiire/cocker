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
            let start = Date()
            do {
                let request = try IPCRequest(type: .rmi, payload: ContainerIDRequest(id: image))
                _ = try await client.send(request)
                UX.printResult(.image, image, verb: .remove, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                UX.Failure.emit(
                    headline: "Cannot remove image \(image)",
                    reason: error.description,
                    hint: force ? nil : "use `--force` (-f) to remove an image referenced by stopped containers"
                )
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
        let start = Date()
        do {
            let request = try IPCRequest(type: .tag, payload: TagPayload(source: source, target: target))
            _ = try await client.send(request)
            UX.printResult(.image, target, verb: .tag, elapsed: Date().timeIntervalSince(start))
        } catch let error as CockerError {
            UX.Failure.emit(
                headline: "Cannot tag image",
                reason: error.description,
                hint: "verify source `\(source)` exists with `cocker images`"
            )
            throw ExitCode.failure
        }
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
        // The daemon runs in its own cwd, so relative build paths sent over
        // IPC resolve against the daemon's directory, not the user's. Always
        // anchor against the CLI's cwd before sending.
        let cwd = FileManager.default.currentDirectoryPath
        let absContext = context.hasPrefix("/") ? context : cwd + "/" + context

        // Stage iCloud-resident build contexts to a local cache. cockerd
        // can't read iCloud files reliably (`bird` coordinator deadlocks
        // inside the daemon process) ; the CLI has full TCC access and
        // can copy via rsync. Same staging mechanism `cocker compose up`
        // uses ; benefits from the same incremental cache on repeat runs.
        let dockerfileFullPath = absContext + "/" + file
        let stage = try await ICloudStaging.stageIfNeeded(originalPath: dockerfileFullPath) { msg in
            // bird (iCloud) staging is one of the macOS-daemon touch-points
            // the charter §12 says we name explicitly so users see what's
            // happening behind a slow first build.
            print(" " + UX.TTY.paint("→ bird (iCloud) " + msg, .progress))
        }
        let effectiveContext = (stage.path as NSString).deletingLastPathComponent

        var config = BuildConfig(contextPath: effectiveContext, tag: tag.isEmpty ? "cocker-image:\(Int(Date().timeIntervalSince1970))" : tag)
        config.dockerfile = file
        config.buildArgs = try parseKV(buildArgs)
        config.noCache = noCache
        config.target = target
        config.platform = platform

        let client = IPCClient()
        let payload = BuildRequest(config: config)
        let request = try IPCRequest(type: .build, payload: payload)

        // Charter §13.3 — when stdout is a TTY, route every event through
        // a BuildView that maintains a redraw-in-place table (one row per
        // Dockerfile step, CACHED marker, per-step timer, final summary).
        // Outside a TTY (CI, file redirect, pipe) fall back to plain
        // chronological prints so logs and grep tooling stay clean.
        if UX.TTY.current.animationEnabled {
            let view = UX.BuildView()
            // Pre-header so users see "what is being built" before the
            // first Step event arrives from the daemon.
            print(" " + UX.TTY.paint("→ Building", .progress) + " " + UX.TTY.paint(config.tag, .accent) + " " + UX.TTY.paint("from \(absContext)/\(file)", .dim))
            try await client.sendStreaming(request) { event in
                view.ingest(stream: event.stream, line: event.data)
            }
            view.finalize()
        } else {
            print(" → Building \(config.tag) from \(absContext)/\(file)")
            try await client.sendStreaming(request) { event in
                switch event.stream {
                case .stdout: print(event.data, terminator: "")
                case .stderr: fputs(event.data, stderr)
                case .status: print(event.data, terminator: event.data.hasSuffix("\n") ? "" : "\n")
                case .error:  UX.Failure.emit(headline: event.data)
                }
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
        let start = Date()
        let payload = SaveRequest(image: image)
        let request = try IPCRequest(type: .save, payload: payload)
        let response = try await client.send(request)
        let result = try response.decode(SaveResponse.self)

        let url = URL(fileURLWithPath: output.hasPrefix("/") ? output : FileManager.default.currentDirectoryPath + "/" + output)
        try result.tarData.write(to: url)
        if UX.TTY.current.isInteractive {
            let trailing = "\(UX.formatBytes(Int64(result.tarData.count))) → \(output) · " + UX.formatElapsed(Date().timeIntervalSince(start))
            print(UX.ActionLine(
                icon: .success, type: .image, name: image,
                status: "Saved", trailing: trailing
            ).render())
        } else {
            print(output)
        }
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
            UX.Failure.emit(
                headline: "Cannot load image archive",
                reason: "file not found at \(input)",
                hint: "verify the path — the CLI's current directory is \(FileManager.default.currentDirectoryPath)"
            )
            throw ExitCode.failure
        }
        let tarData = try Data(contentsOf: url)
        let client = IPCClient()
        let start = Date()
        let payload = LoadRequest(tarData: tarData)
        let request = try IPCRequest(type: .load, payload: payload)
        let response = try await client.send(request)
        let msg = try response.decode(String.self)
        UX.printResult(.image, msg, verb: .load, elapsed: Date().timeIntervalSince(start))
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
        guard UX.Confirm.ask(
            summary: "This will remove all images not referenced by any container.",
            force: force
        ) else { return }

        let client = IPCClient()
        let request = try IPCRequest(type: .imagePrune, payload: EmptyPayload())
        let response = try await client.send(request)
        let result = try response.decode(PruneResponse.self)

        if result.imagesDeleted.isEmpty {
            print(" " + UX.TTY.paint("nothing to prune — 0 B reclaimed", .dim, [.italic]))
        } else {
            for img in result.imagesDeleted {
                UX.printResult(.image, img, verb: .remove)
            }
            print(" " + UX.TTY.paint("reclaimed \(UX.formatBytes(Int64(result.spaceReclaimed)))", .dim))
        }
    }
}

struct CommitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "commit",
        abstract: "Create a new image from a container's changes"
    )

    @Option(name: [.short, .customLong("author")], help: "Author (e.g. \"Alice <alice@example.com>\")")
    var author: String?

    @Option(name: [.short, .customLong("message")], help: "Commit message")
    var message: String?

    @Argument(help: "Container ID or name")
    var container: String

    @Argument(help: "Repository and tag (image:tag)")
    var repository: String

    mutating func run() async throws {
        let client = IPCClient()
        let start = Date()
        let payload = CommitRequest(containerID: container, tag: repository, author: author, message: message)
        let request = try IPCRequest(type: .commit, payload: payload)
        let response = try await client.send(request)
        let img = try response.decode(ImageInfo.self)
        let shortID = String(img.id.prefix(12))
        if UX.TTY.current.isInteractive {
            let trailing = UX.TTY.paint(shortID, .accent) + " · " + UX.formatElapsed(Date().timeIntervalSince(start))
            print(UX.ActionLine(
                icon: .success, type: .image, name: repository,
                status: "Committed", trailing: trailing
            ).render())
        } else {
            print(shortID)
        }
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a container's filesystem as a tar archive"
    )

    @Option(name: [.short, .customLong("output")], help: "Write to a file (default: stdout)")
    var output: String?

    @Argument(help: "Container ID or name")
    var container: String

    mutating func run() async throws {
        let client = IPCClient()
        let start = Date()
        let payload = ExportRequest(containerID: container)
        let request = try IPCRequest(type: .export, payload: payload)
        let response = try await client.send(request)
        let result = try response.decode(SaveResponse.self)

        if let outPath = output {
            let url = URL(fileURLWithPath: outPath.hasPrefix("/") ? outPath : FileManager.default.currentDirectoryPath + "/" + outPath)
            try result.tarData.write(to: url)
            if UX.TTY.current.isInteractive {
                let trailing = "\(UX.formatBytes(Int64(result.tarData.count))) → \(outPath) · " + UX.formatElapsed(Date().timeIntervalSince(start))
                print(UX.ActionLine(
                    icon: .success, type: .container, name: container,
                    status: "Exported", trailing: trailing
                ).render())
            } else {
                print(outPath)
            }
        } else {
            FileHandle.standardOutput.write(result.tarData)
        }
    }
}

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a tarball as an image"
    )

    @Argument(help: "Path to tar file (- for stdin)")
    var file: String

    @Argument(help: "Repository and tag (image:tag)")
    var tag: String

    mutating func run() async throws {
        let tarData: Data
        if file == "-" {
            tarData = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            let url = URL(fileURLWithPath: file.hasPrefix("/") ? file : FileManager.default.currentDirectoryPath + "/" + file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                UX.Failure.emit(
                    headline: "Cannot import image",
                    reason: "file not found at \(file)",
                    hint: "verify the path — the CLI's current directory is \(FileManager.default.currentDirectoryPath)"
                )
                throw ExitCode.failure
            }
            tarData = try Data(contentsOf: url)
        }

        let client = IPCClient()
        let start = Date()
        let payload = ContainerImportRequest(tarData: tarData, tag: tag)
        let request = try IPCRequest(type: .containerImport, payload: payload)
        let response = try await client.send(request)
        let img = try response.decode(ImageInfo.self)
        let sha = "sha256:\(img.id.hasPrefix("sha256:") ? String(img.id.dropFirst(7)) : img.id)"
        if UX.TTY.current.isInteractive {
            let trailing = UX.TTY.paint(String(sha.prefix(19)), .accent) + " · " + UX.formatElapsed(Date().timeIntervalSince(start))
            print(UX.ActionLine(
                icon: .success, type: .image, name: tag,
                status: "Imported", trailing: trailing
            ).render())
        } else {
            print(sha)
        }
    }
}

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update configuration of one or more containers"
    )

    @Option(name: .customLong("cpus"), help: "Number of CPUs")
    var cpus: Int?

    @Option(name: .customShort("m"), help: "Memory limit in MB")
    var memory: UInt64?

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for id in containers {
            let start = Date()
            do {
                let request = try IPCRequest(type: .update, payload: UpdateRequest(containerID: id, cpus: cpus, memoryMB: memory))
                _ = try await client.send(request)
                UX.printResult(.container, id, verb: .update, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                UX.Failure.emit(
                    headline: "Cannot update container \(id)",
                    reason: error.description
                )
            }
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
