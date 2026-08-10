import ArgumentParser
import CockerCore
import Foundation

struct ImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "images",
        abstract: "List images"
    )

    /// Docker hides intermediate build layers without `-a`. Cocker never
    /// records them as images, so the listing is already complete and this
    /// flag has nothing to reveal. Accepted for script compatibility.
    @Flag(name: [.short, .customLong("all")],
          help: "No-op: cocker records no intermediate images, all are listed")
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

        let rows: [UX.Table.Row] = images.map { img in
            .init([
                .init(img.repository),
                .init(img.tag),
                .init(String(img.id.prefix(12)), color: .accent),
                .init(relativeTime(from: img.createdAt), color: .dim),
                .init(formatBytes(img.size), color: .dim),
            ])
        }
        let table = UX.Table(
            columns: [
                .init("REPOSITORY", maxWidth: 40),
                .init("TAG", maxWidth: 20),
                .init("IMAGE ID", maxWidth: 12),
                .init("CREATED"),
                .init("SIZE", align: .right),
            ],
            rows: rows,
            emptyMessage: "no images — run `cocker pull <ref>` to fetch one or `cocker build` to build one"
        )
        print(table.render())
    }
}

struct RmiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rmi",
        abstract: "Remove one or more images"
    )

    /// Declared, never plumbed. The payload carries no force field, the
    /// daemon calls `remove(_:)` with the default, and `ImageManager.remove`
    /// takes a `force` it does not read. It was worse than inert: the hint
    /// promised `-f` would remove a referenced image, and passing it
    /// swallowed the error, so the command printed a failure block and then
    /// exited 0 with the image still there.
    @Flag(name: [.short, .customLong("force")],
          help: "Not honoured: an image referenced by a container is never force-removed")
    var force = false

    @Argument(help: "Image ID(s) or reference(s)")
    var images: [String]

    mutating func run() async throws {
        if force {
            UX.IgnoredFlag.warn("--force",
                "an image referenced by a container is still refused")
        }
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
                    hint: "remove the containers referencing it first, then retry"
                )
                // Always. Suppressing the throw under `--force` turned a
                // failure the user could see into an exit status that said
                // it had worked.
                throw error
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
            throw ExitCode(error.exitCode)
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

        // `-f` may be absolute or relative. A relative `-f` is anchored on the
        // context ; an absolute `-f` is taken verbatim. Naively doing
        // `absContext + "/" + file` concatenates the two absolute paths into
        // garbage (`/ctx//abs/Dockerfile`) — the bug behind PRO-78.
        let dockerfileFullPath = file.hasPrefix("/") ? file : absContext + "/" + file

        // Stage iCloud-resident build contexts to a local cache. cockerd
        // can't read iCloud files reliably (`bird` coordinator deadlocks
        // inside the daemon process) ; the CLI has full TCC access and
        // can copy via rsync. Same staging mechanism `cocker compose up`
        // uses ; benefits from the same incremental cache on repeat runs.
        //
        // Stage the CONTEXT, not the Dockerfile's directory. Deriving the
        // context from `-f` made `cocker build -f other/Dockerfile ctx/`
        // copy from `other/` and ignore `ctx/` entirely — the opposite of
        // Docker, where COPY always resolves against the context. A build
        // then silently produced an image built from the wrong files.
        let stage = try await ICloudStaging.stageIfNeeded(
            originalPath: absContext + "/." ) { msg in
            // bird (iCloud) staging is one of the macOS-daemon touch-points
            // the charter §12 says we name explicitly so users see what's
            // happening behind a slow first build.
            print(" " + UX.TTY.paint("→ bird (iCloud) " + msg, .progress))
        }
        let effectiveContext = (stage.path as NSString).deletingLastPathComponent

        // Where the daemon will read the Dockerfile from. When `-f` points
        // inside the context we pass the relative path so a staged copy
        // resolves correctly ; when it points outside (a legitimate Docker
        // usage) we pass it verbatim, because only the context is staged.
        let dockerfileForDaemon: String = {
            let ctxPrefix = absContext.hasSuffix("/") ? absContext : absContext + "/"
            if dockerfileFullPath.hasPrefix(ctxPrefix) {
                return String(dockerfileFullPath.dropFirst(ctxPrefix.count))
            }
            return dockerfileFullPath
        }()

        var config = BuildConfig(contextPath: effectiveContext, tag: tag.isEmpty ? "cocker-image:\(Int(Date().timeIntervalSince1970))" : tag)
        config.dockerfile = dockerfileForDaemon
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
            print(" " + UX.TTY.paint("→ Building", .progress) + " " + UX.TTY.paint(config.tag, .accent) + " " + UX.TTY.paint("from \(dockerfileFullPath)", .dim))
            // Animate from the start : a long RUN emits nothing for
            // minutes, and an event-driven view freezes mid-frame.
            view.startAnimating()
            try await client.sendStreaming(request) { event in
                view.ingest(stream: event.stream, line: event.data)
            }
            view.finalize()
        } else {
            print(" → Building \(config.tag) from \(dockerfileFullPath)")
            let fail = UX.FailFlag()
            try await client.sendStreaming(request) { event in
                switch event.stream {
                case .stdout: print(event.data, terminator: "")
                case .stderr:
                    // stdout is block-buffered when redirected while stderr
                    // is not, so an unsynchronised write puts the failure
                    // diagnostic BEFORE the step list it explains.
                    UX.writeStderr(event.data)
                case .status: print(event.data, terminator: event.data.hasSuffix("\n") ? "" : "\n")
                case .error:
                    UX.syncStdout()
                    fail.trip()
                    UX.Failure.emit(headline: event.data)
                }
            }
            UX.syncStdout()
            try fail.throwIfTripped()
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
        let url = URL(fileURLWithPath: output.hasPrefix("/") ? output : FileManager.default.currentDirectoryPath + "/" + output)
        // v2 : the daemon writes the tar straight to `output` (same host,
        // same user). Keeps multi-GB images out of the JSON frame — the
        // legacy in-band path failed past ~75 MB (100 MB frame cap on
        // base64-inflated payloads) and buffered everything in RAM.
        let payload = SaveRequest(image: image, outputPath: url.path)
        let request = try IPCRequest(type: .save, payload: payload)
        let response = try await client.send(request)
        let result = try response.decode(SaveResponse.self)

        let byteCount: Int64
        if result.filePath != nil {
            byteCount = Int64(result.byteCount ?? 0)
        } else {
            // Legacy daemon : bytes came in-band, write them ourselves.
            try result.tarData.write(to: url)
            byteCount = Int64(result.tarData.count)
        }
        if UX.TTY.current.isInteractive {
            let trailing = "\(UX.formatBytes(byteCount)) → \(output) · " + UX.formatElapsed(Date().timeIntervalSince(start))
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
        // v2 : hand the daemon the file PATH — it reads from disk directly.
        // No base64, no 100 MB frame cap, no double-buffering in RAM.
        let client = IPCClient()
        let start = Date()
        let payload = LoadRequest(tarData: Data(), inputPath: url.path)
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

    @Flag(name: [.short, .customLong("all")], help: "Also remove images held by stopped containers (keeps only images used by a running container)")
    var all = false

    @Flag(name: [.short, .customLong("force")], help: "Do not prompt for confirmation")
    var force = false

    mutating func run() async throws {
        guard UX.Confirm.ask(
            summary: all
                ? "This will remove ALL images, including those held by stopped containers (only images used by a running container are kept)."
                : "This will remove all images not referenced by any container.",
            force: force
        ) else { return }

        let client = IPCClient()
        let request = try IPCRequest(type: .imagePrune, payload: ImagePruneRequest(all: all))
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

        if let outPath = output {
            // v2 path handoff : daemon writes the tar to the requested file.
            let url = URL(fileURLWithPath: outPath.hasPrefix("/") ? outPath : FileManager.default.currentDirectoryPath + "/" + outPath)
            let payload = ExportRequest(containerID: container, outputPath: url.path)
            let request = try IPCRequest(type: .export, payload: payload)
            let response = try await client.send(request)
            let result = try response.decode(SaveResponse.self)
            let byteCount: Int64
            if result.filePath != nil {
                byteCount = Int64(result.byteCount ?? 0)
            } else {
                // Legacy daemon : bytes in-band.
                try result.tarData.write(to: url)
                byteCount = Int64(result.tarData.count)
            }
            if UX.TTY.current.isInteractive {
                let trailing = "\(UX.formatBytes(byteCount)) → \(outPath) · " + UX.formatElapsed(Date().timeIntervalSince(start))
                print(UX.ActionLine(
                    icon: .success, type: .container, name: container,
                    status: "Exported", trailing: trailing
                ).render())
            } else {
                print(outPath)
            }
        } else {
            // stdout streaming : no destination file exists, keep in-band.
            let payload = ExportRequest(containerID: container)
            let request = try IPCRequest(type: .export, payload: payload)
            let response = try await client.send(request)
            let result = try response.decode(SaveResponse.self)
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
        var inputPath: String? = nil
        if file == "-" {
            // stdin : no file on disk, ship bytes in-band (legacy path).
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
            // v2 path handoff : daemon reads the tar straight from disk.
            tarData = Data()
            inputPath = url.path
        }

        let client = IPCClient()
        let start = Date()
        let payload = ContainerImportRequest(tarData: tarData, tag: tag, inputPath: inputPath)
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
        let failures = FailureCode()
        for id in containers {
            let start = Date()
            do {
                let request = try IPCRequest(type: .update, payload: UpdateRequest(containerID: id, cpus: cpus, memoryMB: memory))
                let live = try await client.send(request)
                UX.printResult(.container, id, verb: .update, elapsed: Date().timeIntervalSince(start))
                // Docker applies --cpus / -m to a running container. cocker
                // can't: VMRuntime reads cpuCount/memoryMB when it builds the
                // VM configuration, so a running container keeps what it
                // booted with. Measured: update --cpus 4 -m 1024 recorded 4
                // and 1024 while the VM still reported `nproc` 2 and
                // MemTotal 501344 kB. The record changed; the container
                // didn't, and nothing said so.
                let status = (try? live.decode(Container.self))?.status
                if status == .running || status == .paused {
                    UX.Warning.emit(
                        "resource limits apply at the next start",
                        note: "\(id) is running with the values it booted with; "
                            + "`cocker restart \(id)` to pick these up"
                    )
                }
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot update container \(id)",
                    reason: error.description
                )
            }
        }
        try failures.throwIfFailed()
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
