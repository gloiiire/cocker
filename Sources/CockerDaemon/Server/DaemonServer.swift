import Foundation
import CockerCore

// Unix domain socket server — accepts CLI connections and routes to engine

@MainActor
final class DaemonServer {
    private let socketPath: String
    private let engine: ContainerEngine
    private let compose: ComposeEngine
    private var serverFD: Int32 = -1
    private var isRunning = false

    init(socketPath: String, engine: ContainerEngine) {
        self.socketPath = socketPath
        self.engine = engine
        self.compose = ComposeEngine(containerEngine: engine)
    }

    func start() async throws {
        // Remove stale socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create socket directory
        let dir = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Create Unix socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CockerError.internalError("socket() failed: \(String(cString: strerror(errno)))") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { dest in
                dest.withMemoryRebound(to: CChar.self, capacity: 108) { dest in
                    _ = strncpy(dest, ptr, 107)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw CockerError.internalError("bind() failed: \(String(cString: strerror(errno)))")
        }

        guard listen(fd, 128) == 0 else {
            close(fd)
            throw CockerError.internalError("listen() failed: \(String(cString: strerror(errno)))")
        }

        // Socket perms : owner-only (0600). The previous 0666 let any
        // local user on the machine talk to cockerd, which equates to
        // root inside any container the daemon manages (kernel CAP_*
        // bypass, host-bind mounts, etc.). 0600 keeps the contract
        // consistent with credentials.json + state.json.
        chmod(socketPath, 0o600)

        self.serverFD = fd
        self.isRunning = true
        CockerLog.shared.info("ipc", "listening on \(socketPath)")

        // Accept loop in a background thread (POSIX accept is blocking)
        await acceptLoop()
    }

    private func acceptLoop() async {
        while isRunning {
            // Accept is blocking — run off main actor
            let clientFD = await Task.detached(priority: .userInitiated) { [fd = serverFD] in
                accept(fd, nil, nil)
            }.value

            guard clientFD >= 0 else {
                if !isRunning { break }
                continue
            }

            // Handle each connection in its own task
            Task { [clientFD] in
                await self.handleConnection(fd: clientFD)
                close(clientFD)
            }
        }
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        try? FileManager.default.removeItem(atPath: socketPath)
        CockerLog.shared.info("ipc", "stopped")
    }

    // MARK: - Connection handler

    private func handleConnection(fd: Int32) async {
        do {
            while true {
                let data = try IPCFramer.read(from: fd)
                let request = try JSONDecoder().decode(IPCRequest.self, from: data)
                try await handleRequest(request, fd: fd)
                // For non-streaming, loop for next request (connection reuse)
            }
        } catch {
            // Connection closed or error — normal lifecycle
        }
    }

    private func handleRequest(_ request: IPCRequest, fd: Int32) async throws {
        do {
            switch request.type {
            case .ping:
                try sendResponse(requestId: request.id, payload: PingResponse(), to: fd)

            case .run:
                fputs("[srv] .run received\n", stderr); fflush(stderr)
                let runReq = try JSONDecoder().decode(RunRequest.self, from: request.payload)
                fputs("[srv] decoded RunRequest, image=\(runReq.config.image)\n", stderr); fflush(stderr)
                let containerID = try await engine.run(config: runReq.config)
                fputs("[srv] engine.run returned id=\(containerID)\n", stderr); fflush(stderr)
                try sendResponse(requestId: request.id, payload: RunResponse(containerID: containerID), to: fd)

            case .start:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.start(id: req.id)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .stop:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.stop(id: req.id)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .kill:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.kill(id: req.id, signal: req.signal ?? "SIGKILL")
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .restart:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.restart(id: req.id)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .pause:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.pause(id: req.id)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .unpause:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.unpause(id: req.id)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .rm:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.remove(id: req.id, force: req.force ?? false)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .ps:
                let req = try JSONDecoder().decode(PSRequest.self, from: request.payload)
                let containers = await engine.list(all: req.all, filter: req.filter)
                try sendResponse(requestId: request.id, payload: PSResponse(containers: containers), to: fd)

            case .inspect:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let container = try await engine.inspect(id: req.id)
                try sendResponse(requestId: request.id, payload: container, to: fd)

            case .logs:
                let req = try JSONDecoder().decode(LogsRequest.self, from: request.payload)
                let stream = try await engine.logs(id: req.id, request: req)
                try await streamResponse(requestId: request.id, stream: stream, to: fd)

            case .exec:
                let req = try JSONDecoder().decode(ExecRequest.self, from: request.payload)
                let stream = try await engine.exec(config: req.config)
                try await streamResponse(requestId: request.id, stream: stream, to: fd)

            case .pull:
                let req = try JSONDecoder().decode(PullRequest.self, from: request.payload)
                try await sendStreamingOperation(requestId: request.id, to: fd) { send in
                    _ = try await self.engine.images.pull(reference: req.reference) { msg in
                        send(StreamEvent(stream: .status, data: msg))
                    }
                }

            case .push:
                let req = try JSONDecoder().decode(PullRequest.self, from: request.payload)
                try await sendStreamingOperation(requestId: request.id, to: fd) { send in
                    try await self.engine.images.push(reference: req.reference) { msg in
                        send(StreamEvent(stream: .status, data: msg))
                    }
                }

            case .build:
                let req = try JSONDecoder().decode(BuildRequest.self, from: request.payload)
                try await sendStreamingOperation(requestId: request.id, to: fd) { send in
                    _ = try await self.engine.images.build(config: req.config, vmRuntime: self.engine.vmRuntime) { event in
                        send(event)
                    }
                }

            case .images:
                let imgs = await engine.images.list()
                try sendResponse(requestId: request.id, payload: ImagesResponse(images: imgs), to: fd)

            case .rmi:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.images.remove(req.id)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .imageInspect:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let img = try await engine.images.find(req.id)
                try sendResponse(requestId: request.id, payload: img, to: fd)

            case .tag:
                struct TagPayload: Codable { let source, target: String }
                let req = try JSONDecoder().decode(TagPayload.self, from: request.payload)
                try await engine.images.tag(source: req.source, target: req.target)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .networkCreate:
                let req = try JSONDecoder().decode(NetworkCreateRequest.self, from: request.payload)
                let net = try await engine.networks.create(request: req)
                try sendResponse(requestId: request.id, payload: net, to: fd)

            case .networkRm:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.networks.remove(req.id)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .networkLs:
                let nets = await engine.networks.list()
                try sendResponse(requestId: request.id, payload: NetworksResponse(networks: nets), to: fd)

            case .networkInspect:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let net = try await engine.networks.get(req.id)
                try sendResponse(requestId: request.id, payload: net, to: fd)

            case .networkConnect:
                struct Payload: Codable { let network, container: String }
                let req = try JSONDecoder().decode(Payload.self, from: request.payload)
                try await engine.networks.connect(containerID: req.container, networkID: req.network)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .networkDisconnect:
                struct Payload: Codable { let network, container: String }
                let req = try JSONDecoder().decode(Payload.self, from: request.payload)
                try await engine.networks.disconnect(containerID: req.container, networkID: req.network)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .volumeCreate:
                let req = try JSONDecoder().decode(VolumeCreateRequest.self, from: request.payload)
                let vol = try await engine.volumes.create(request: req)
                try sendResponse(requestId: request.id, payload: vol, to: fd)

            case .volumeRm:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.volumes.remove(req.id)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .volumeLs:
                let vols = await engine.volumes.list()
                try sendResponse(requestId: request.id, payload: VolumesResponse(volumes: vols), to: fd)

            case .volumeInspect:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let vol = try await engine.volumes.get(req.id)
                try sendResponse(requestId: request.id, payload: vol, to: fd)

            case .composeUp:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                try await sendStreamingOperation(requestId: request.id, to: fd) { send in
                    try await self.compose.up(request: req, progressHandler: send)
                }

            case .composeDown:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                try await compose.down(request: req)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .cp:
                let req = try JSONDecoder().decode(CpRequest.self, from: request.payload)
                try await handleCp(req, requestId: request.id, to: fd)

            case .rename:
                let req = try JSONDecoder().decode(RenameRequest.self, from: request.payload)
                guard let container = await engine.state.container(id: req.id) else {
                    throw CockerError.containerNotFound(req.id)
                }
                try await engine.state.updateContainer(id: container.id) { c in c.name = req.newName }
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .attach:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                guard let container = await engine.state.container(id: req.id) else {
                    throw CockerError.containerNotFound(req.id)
                }
                // Stream the container's recent logs and ongoing output as an attach simulation
                let historical = engine.vmRuntime.logs(containerID: container.id, tail: 20)
                let containerID = container.id
                try await sendStreamingOperation(requestId: request.id, to: fd) { [self] send in
                    for event in historical { send(event) }
                    // Stream until container stops
                    while self.engine.vmRuntime.isRunning(containerID: containerID) {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }

            case .diff:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let result = try await handleDiff(req.id)
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .save:
                let req = try JSONDecoder().decode(SaveRequest.self, from: request.payload)
                let result = try await handleSave(req.image)
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .load:
                let req = try JSONDecoder().decode(LoadRequest.self, from: request.payload)
                let msg = try await handleLoad(req.tarData)
                try sendResponse(requestId: request.id, payload: msg, to: fd)

            case .imageHistory:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let img = try await engine.images.find(req.id)
                var entries: [ImageHistoryEntry] = []
                for (i, layer) in img.layers.enumerated() {
                    entries.append(ImageHistoryEntry(
                        id: String(layer.prefix(19)),
                        createdAt: img.createdAt.addingTimeInterval(TimeInterval(-i * 60)),
                        createdBy: i == 0 ? "/bin/sh -c #(nop) FROM \(img.repository):\(img.tag)" : "/bin/sh -c layer \(i)",
                        size: img.size / UInt64(max(1, img.layers.count)),
                        comment: ""
                    ))
                }
                if entries.isEmpty {
                    entries.append(ImageHistoryEntry(
                        id: String(img.id.prefix(19)),
                        createdAt: img.createdAt,
                        createdBy: "/bin/sh -c #(nop) ADD \(img.repository):\(img.tag)",
                        size: img.size,
                        comment: ""
                    ))
                }
                try sendResponse(requestId: request.id, payload: ImageHistoryResponse(entries: entries), to: fd)

            case .imagePrune:
                let result = try await handleImagePrune()
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .containerPrune:
                let deleted = try await engine.state.pruneStopped()
                let result = PruneResponse(
                    containersDeleted: deleted,
                    imagesDeleted: [],
                    volumesDeleted: [],
                    spaceReclaimed: 0
                )
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .systemDf:
                let result = try await handleSystemDf()
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .composeLs:
                let result = await handleComposeLs()
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .composeLogs:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                let pName = req.projectName ?? URL(fileURLWithPath: req.composePath).deletingLastPathComponent().lastPathComponent
                let filter = ["label": "com.cocker.project=\(pName)"]
                let containers = await engine.list(all: true, filter: filter)
                try await sendStreamingOperation(requestId: request.id, to: fd) { send in
                    for container in containers {
                        let logs = await self.engine.vmRuntime.logs(containerID: container.id, tail: 50)
                        for event in logs {
                            send(StreamEvent(stream: event.stream, data: "[\(container.name)] \(event.data)"))
                        }
                    }
                }

            case .composePs:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                let pName = req.projectName ?? URL(fileURLWithPath: req.composePath).deletingLastPathComponent().lastPathComponent
                let filter = ["label": "com.cocker.project=\(pName)"]
                let containers = await engine.list(all: true, filter: filter)
                try sendResponse(requestId: request.id, payload: PSResponse(containers: containers), to: fd)

            case .composeBuild:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                try await sendStreamingOperation(requestId: request.id, to: fd) { send in
                    try await self.compose.build(request: req, progressHandler: send)
                }

            case .composePull:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                try await sendStreamingOperation(requestId: request.id, to: fd) { send in
                    try await self.compose.pull(request: req, progressHandler: send)
                }

            case .composeRun:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                try await sendStreamingOperation(requestId: request.id, to: fd) { send in
                    try await self.compose.run(request: req, progressHandler: send)
                }

            case .composeRestart:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                let pName = req.projectName ?? URL(fileURLWithPath: req.composePath).deletingLastPathComponent().lastPathComponent
                let filter = ["label": "com.cocker.project=\(pName)"]
                var containers = await engine.list(all: false, filter: filter)
                if !req.services.isEmpty {
                    containers = containers.filter { c in
                        req.services.contains(c.labels["com.cocker.service"] ?? "")
                    }
                }
                for c in containers {
                    try? await engine.restart(id: c.id)
                }
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .info:
                let info = await engine.info()
                try sendResponse(requestId: request.id, payload: info, to: fd)

            case .version:
                try sendResponse(requestId: request.id, payload: PingResponse(), to: fd)

            case .prune:
                let req = try JSONDecoder().decode(PruneRequest.self, from: request.payload)
                let result = try await engine.prune(volumes: req.volumes)
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .events:
                let stream = await engine.eventStream()
                try await streamResponse(requestId: request.id, stream: stream, to: fd)

            case .top:
                try sendResponse(requestId: request.id, payload: "PID   USER   COMMAND\n1     root   /sbin/init\n", to: fd)

            case .commit:
                let req = try JSONDecoder().decode(CommitRequest.self, from: request.payload)
                let result = try await handleCommit(req)
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .export:
                let req = try JSONDecoder().decode(ExportRequest.self, from: request.payload)
                let tarData = try await handleExport(req.containerID)
                try sendResponse(requestId: request.id, payload: SaveResponse(tarData: tarData), to: fd)

            case .containerImport:
                let req = try JSONDecoder().decode(ContainerImportRequest.self, from: request.payload)
                let img = try await engine.images.importTar(req.tarData, tag: req.tag)
                try sendResponse(requestId: request.id, payload: img, to: fd)

            case .update:
                let req = try JSONDecoder().decode(UpdateRequest.self, from: request.payload)
                try await handleUpdate(req)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .setup:
                try await performSetup(requestId: request.id, to: fd)

            default:
                sendErrorResponse(requestId: request.id, error: "Unknown request type: \(request.type.rawValue)", to: fd)
            }
        } catch let error as CockerError {
            sendErrorResponse(requestId: request.id, error: error.description, to: fd)
        } catch {
            sendErrorResponse(requestId: request.id, error: error.localizedDescription, to: fd)
        }
    }

    // MARK: - Response helpers

    private func sendResponse<T: Encodable & Sendable>(requestId: String, payload: T, to fd: Int32) throws {
        let response = try IPCResponse(requestId: requestId, payload: payload)
        let data = try JSONEncoder().encode(response)
        try IPCFramer.write(data, to: fd)
    }

    private func sendErrorResponse(requestId: String, error: String, to fd: Int32) {
        let response = IPCResponse(requestId: requestId, error: error)
        if let data = try? JSONEncoder().encode(response) {
            try? IPCFramer.write(data, to: fd)
        }
    }

    private func streamResponse(requestId: String, stream: AsyncStream<StreamEvent>, to fd: Int32) async throws {
        for await event in stream {
            let response = try IPCResponse(requestId: requestId, payload: event, isStreaming: true, isLast: false)
            let data = try JSONEncoder().encode(response)
            try IPCFramer.write(data, to: fd)
        }
        // Send termination frame
        let done = try IPCResponse(requestId: requestId, payload: StreamEvent(stream: .status, data: ""), isStreaming: true, isLast: true)
        let data = try JSONEncoder().encode(done)
        try IPCFramer.write(data, to: fd)
    }

    private func sendStreamingOperation(
        requestId: String,
        to fd: Int32,
        operation: @escaping (@escaping (StreamEvent) -> Void) async throws -> Void
    ) async throws {
        try await operation { event in
            let response = try? IPCResponse(requestId: requestId, payload: event, isStreaming: true, isLast: false)
            if let data = try? JSONEncoder().encode(response) {
                try? IPCFramer.write(data, to: fd)
            }
        }
        let done = try IPCResponse(requestId: requestId, payload: StreamEvent(stream: .status, data: ""), isStreaming: true, isLast: true)
        let data = try JSONEncoder().encode(done)
        try IPCFramer.write(data, to: fd)
    }

    // MARK: - Feature helpers

    private func handleCp(_ req: CpRequest, requestId: String, to fd: Int32) async throws {
        guard let container = await engine.state.container(id: req.containerID) else {
            throw CockerError.containerNotFound(req.containerID)
        }
        // Resolve against the container's clonefile rootfs — the image's
        // rootfs is shared between all containers of that image, so writing
        // to it corrupts every sibling. Fall back to the image rootfs only
        // if the container hasn't been cloned yet (very early lifecycle).
        let clonedRootfs = await engine.images.store.containerRootfsDirectory(containerID: req.containerID)
        let rootfsDir: URL
        if FileManager.default.fileExists(atPath: clonedRootfs.path) {
            rootfsDir = clonedRootfs
        } else {
            let img = try await engine.images.find(container.image)
            rootfsDir = await engine.images.store.rootfsDirectory(for: img)
        }

        let fm = FileManager.default
        let containerFull = rootfsDir.appendingPathComponent(
            req.containerPath.hasPrefix("/") ? String(req.containerPath.dropFirst()) : req.containerPath
        )

        if req.toContainer {
            // host → container
            let src = URL(fileURLWithPath: req.hostPath)
            let dst = containerFull
            let parent = dst.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        } else {
            // container → host
            let src = containerFull
            let dst = URL(fileURLWithPath: req.hostPath)
            let parent = dst.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        try sendResponse(requestId: requestId, payload: EmptyPayload(), to: fd)
    }

    private func handleDiff(_ containerID: String) async throws -> DiffResponse {
        guard let container = await engine.state.container(id: containerID) else {
            throw CockerError.containerNotFound(containerID)
        }
        let img = try await engine.images.find(container.image)
        let rootfsDir = await engine.images.store.rootfsDirectory(for: img)

        // Use find to list all files in rootfs relative to root — treat them all as "Added" for simplicity
        // (A real diff would compare to a snapshot; here we show the complete filesystem as Changed)
        let fm = FileManager.default
        var entries: [DiffEntry] = []

        if let enumerator = fm.enumerator(at: rootfsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator {
                let rel = url.path.replacingOccurrences(of: rootfsDir.path, with: "")
                if rel.isEmpty { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                entries.append(DiffEntry(kind: isDir ? "C" : "A", path: rel))
                if entries.count >= 200 { break }  // cap output
            }
        }

        return DiffResponse(entries: entries)
    }

    private func handleSave(_ reference: String) async throws -> SaveResponse {
        let img = try await engine.images.find(reference)
        let rootfsDir = await engine.images.store.rootfsDirectory(for: img)

        // Stage a working tree so the produced tar has both `manifest.json`
        // at the root AND a `rootfs/` directory carrying the extracted
        // image. handleLoad reads both. The pre-fix code wrote the manifest
        // to a sibling temp file but never tar'd it ; the resulting
        // archive was just a rootfs blob with no way to recover the
        // repo:tag or any of the OCI config defaults.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let manifestData = try encoder.encode(img)
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        if FileManager.default.fileExists(atPath: rootfsDir.path) {
            let rootfsTarget = staging.appendingPathComponent("rootfs")
            // Use clonefile for instant copy on APFS — falls back
            // transparently to a regular copy on other filesystems.
            try FileManager.default.copyItem(at: rootfsDir, to: rootfsTarget)
        }

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-save-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-c", "-f", tmpURL.path, "-C", staging.path, "."]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let tarData = (try? Data(contentsOf: tmpURL)) ?? Data()
        return SaveResponse(tarData: tarData)
    }

    private func handleLoad(_ tarData: Data) async throws -> String {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocker-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tmpTar = tmpDir.appendingPathComponent("image.tar")
        try tarData.write(to: tmpTar)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-x", "-f", tmpTar.path, "-C", tmpDir.path]
        try process.run()
        process.waitUntilExit()

        // Look for manifest.json at the tarball root.
        let manifestURL = tmpDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let img = try? JSONDecoder().decode(ImageInfo.self, from: data) else {
            return "Loaded image archive (manifest not found — use `cocker images` to verify)"
        }
        // Copy the bundled rootfs into the store. New-style archives (≥
        // v0.4.2) ship a `rootfs/` subdirectory ; older flat archives put
        // the filesystem entries at the tar root, so we accept both.
        let destRootfs = await engine.images.store.rootfsDirectory(for: img)
        if !FileManager.default.fileExists(atPath: destRootfs.path) {
            try FileManager.default.createDirectory(at: destRootfs.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let bundled = tmpDir.appendingPathComponent("rootfs")
            if FileManager.default.fileExists(atPath: bundled.path) {
                try FileManager.default.copyItem(at: bundled, to: destRootfs)
            } else {
                try FileManager.default.createDirectory(at: destRootfs,
                                                         withIntermediateDirectories: true)
                // Older flat shape : copy every entry except the manifest.
                if let files = try? FileManager.default.contentsOfDirectory(
                    at: tmpDir, includingPropertiesForKeys: nil) {
                    for f in files where !["manifest.json", "image.tar"]
                                            .contains(f.lastPathComponent) {
                        try? FileManager.default.copyItem(
                            at: f, to: destRootfs.appendingPathComponent(f.lastPathComponent))
                    }
                }
            }
        }
        try await engine.images.storeBuiltImage(img)
        return "Loaded image: \(img.repository):\(img.tag)"
    }

    private func handleImagePrune() async throws -> PruneResponse {
        let allImages = await engine.images.list()
        let allContainers = await engine.state.allContainers(includeAll: true)
        let usedImages = Set(allContainers.map { $0.image })

        var deleted: [String] = []
        var reclaimed: UInt64 = 0

        for img in allImages where !usedImages.contains(img.reference) && !usedImages.contains(img.id) {
            reclaimed += img.size
            try? await engine.images.remove(img.reference)
            deleted.append(img.reference)
        }

        return PruneResponse(containersDeleted: [], imagesDeleted: deleted, volumesDeleted: [], spaceReclaimed: reclaimed)
    }

    private func handleSystemDf() async throws -> SystemDfResponse {
        let allContainers = await engine.state.allContainers(includeAll: true)
        let runningContainers = allContainers.filter { $0.status == .running }
        let allImages = await engine.images.list()
        let allVolumes = await engine.volumes.list()
        let usedImages = Set(allContainers.map { $0.image })

        // Image size
        let totalImageSize = allImages.reduce(UInt64(0)) { $0 + $1.size }
        let unusedImageSize = allImages.filter { !usedImages.contains($0.reference) && !usedImages.contains($0.id) }.reduce(UInt64(0)) { $0 + $1.size }

        // Container size (approximation via rootfs)
        let fm = FileManager.default
        let rootfsBase = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cocker/images/rootfs")
        var containerSize: UInt64 = 0
        if let items = try? fm.contentsOfDirectory(at: rootfsBase, includingPropertiesForKeys: [.fileSizeKey]) {
            for item in items {
                if let res = try? item.resourceValues(forKeys: [.fileSizeKey]) {
                    containerSize += UInt64(res.fileSize ?? 0)
                }
            }
        }

        // Volume size
        var totalVolSize: UInt64 = 0
        for vol in allVolumes {
            if let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: vol.mountpoint), includingPropertiesForKeys: [.fileSizeKey]) {
                for item in items {
                    if let res = try? item.resourceValues(forKeys: [.fileSizeKey]) {
                        totalVolSize += UInt64(res.fileSize ?? 0)
                    }
                }
            }
        }

        let stoppedContainers = allContainers.filter { $0.status == .stopped || $0.status == .dead }

        let entries: [SystemDfResponse.DfEntry] = [
            SystemDfResponse.DfEntry(type: "Images", total: allImages.count, active: usedImages.count, size: totalImageSize, reclaimable: unusedImageSize),
            SystemDfResponse.DfEntry(type: "Containers", total: allContainers.count, active: runningContainers.count, size: containerSize, reclaimable: stoppedContainers.isEmpty ? 0 : containerSize / UInt64(max(1, allContainers.count)) * UInt64(stoppedContainers.count)),
            SystemDfResponse.DfEntry(type: "Volumes", total: allVolumes.count, active: allVolumes.count, size: totalVolSize, reclaimable: 0),
        ]

        return SystemDfResponse(entries: entries)
    }

    private func handleComposeLs() async -> ComposeLsResponse {
        let allContainers = await engine.state.allContainers(includeAll: true)
        var projects: [String: (containers: [Container], configFile: String)] = [:]

        for c in allContainers {
            guard let proj = c.labels["com.cocker.project"] else { continue }
            var entry = projects[proj] ?? (containers: [], configFile: "")
            entry.containers.append(c)
            projects[proj] = entry
        }

        let infos = projects.map { (name, entry) -> ComposeLsResponse.ProjectInfo in
            let running = entry.containers.filter { $0.status == .running }.count
            let total = entry.containers.count
            let status = running == total && total > 0 ? "running(\(running))" : "partially running(\(running)/\(total))"
            return ComposeLsResponse.ProjectInfo(
                name: name,
                status: status,
                configFiles: "cocker-compose.yml",
                servicesCount: entry.containers.count
            )
        }.sorted { $0.name < $1.name }

        return ComposeLsResponse(projects: infos)
    }

    // MARK: - Commit

    private func handleCommit(_ req: CommitRequest) async throws -> ImageInfo {
        guard let container = await engine.state.container(id: req.containerID) else {
            throw CockerError.containerNotFound(req.containerID)
        }
        let img = try await engine.images.find(container.image)
        // Commit MUST snapshot the container's OVERLAY rootfs (where the
        // container's filesystem changes live thanks to APFS clonefile),
        // not the image's shared base. The earlier path read from the
        // image's rootfs and silently lost every modification the
        // container made — `echo modified > /custom.txt && cocker commit`
        // produced an image identical to the base.
        let containerRootfs = await engine.images.store.containerRootfsDirectory(containerID: container.id)
        let rootfsDir: URL
        if FileManager.default.fileExists(atPath: containerRootfs.path) {
            rootfsDir = containerRootfs
        } else {
            // Container's overlay was already cleaned up (rare ; happens
            // after `cocker rm` then attempted commit). Fall back to the
            // image base — at least the image config gets a new tag.
            rootfsDir = await engine.images.store.rootfsDirectory(for: img)
        }
        guard FileManager.default.fileExists(atPath: rootfsDir.path) else {
            throw CockerError.imageNotFound("\(container.image) (rootfs not available)")
        }
        return try await engine.images.commit(
            fromRootfs: rootfsDir,
            tag: req.tag,
            baseImage: img,
            author: req.author,
            message: req.message
        )
    }

    // MARK: - Export

    private func handleExport(_ containerID: String) async throws -> Data {
        guard let container = await engine.state.container(id: containerID) else {
            throw CockerError.containerNotFound(containerID)
        }
        let img = try await engine.images.find(container.image)
        let rootfsDir = await engine.images.store.rootfsDirectory(for: img)
        guard FileManager.default.fileExists(atPath: rootfsDir.path) else {
            throw CockerError.imageNotFound("\(container.image) (rootfs not available)")
        }
        return try await engine.images.exportRootfs(at: rootfsDir)
    }

    // MARK: - Update

    private func handleUpdate(_ req: UpdateRequest) async throws {
        guard let _ = await engine.state.container(id: req.containerID) else {
            throw CockerError.containerNotFound(req.containerID)
        }
        try await engine.state.updateContainer(id: req.containerID) { c in
            if let cpus = req.cpus { c.cpuCount = cpus }
            if let mem = req.memoryMB { c.memoryMB = mem }
        }
    }

    // MARK: - Setup

    private func performSetup(requestId: String, to fd: Int32) async throws {
        let rootDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cocker")
        let kernelDir = rootDir.appendingPathComponent("kernel")
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)

        func send(_ msg: String) {
            let event = StreamEvent(stream: .status, data: msg + "\n")
            let response = try? IPCResponse(requestId: requestId, payload: event, isStreaming: true, isLast: false)
            if let data = try? JSONEncoder().encode(response) {
                try? IPCFramer.write(data, to: fd)
            }
        }

        send("Setting up Cocker runtime environment...")
        send("Kernel directory: \(kernelDir.path)")
        send("")
        send("To complete setup, provide a Linux kernel and initrd:")
        send("  1. Download Alpine Linux kernel:")
        send("     https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/")
        send("  2. Place vmlinuz at: \(kernelDir.path)/vmlinuz")
        send("  3. Place initrd.img at: \(kernelDir.path)/initrd.img")
        send("")
        send("Alternatively, use Apple's containerization project:")
        send("  brew install apple/container/container")
        send("  cockerd will automatically use the Apple-provided kernel")
        send("")

        // Check if apple/container kernel is available
        let appleKernelPaths = [
            "/opt/homebrew/share/container/kernel",
            "/usr/local/share/container/kernel",
        ]

        for path in appleKernelPaths {
            if FileManager.default.fileExists(atPath: path) {
                send("Found Apple container kernel at: \(path)")
                send("Symlinking to ~/.cocker/kernel/...")
                try? FileManager.default.createSymbolicLink(
                    at: kernelDir.appendingPathComponent("vmlinuz"),
                    withDestinationURL: URL(fileURLWithPath: path + "/vmlinuz")
                )
                break
            }
        }

        let doneResponse = try IPCResponse(requestId: requestId, payload: StreamEvent(stream: .status, data: ""), isStreaming: true, isLast: true)
        let data = try JSONEncoder().encode(doneResponse)
        try IPCFramer.write(data, to: fd)
    }
}
