import Foundation
import CockerCore

// Unix domain socket server — accepts CLI connections and routes to engine

@MainActor
final class DaemonServer {
    private let socketPath: String
    private let engine: ContainerEngine
    private let compose: ComposeEngine
    private let composeProjectGate = ComposeProjectGate()
    // Both are only ever read/written from the MainActor : `acceptLoop`
    // stays actor-isolated and only the blocking accept(2) syscall runs
    // off-actor in a detached Task (the `await` suspends without blocking
    // the actor). No `nonisolated(unsafe)`, no benign-race hand-waving —
    // same pattern as DockerAPIServer.
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

        var addr: sockaddr_un
        do { addr = try makeUnixSocketAddress(path: socketPath) }
        catch { close(fd); throw error }

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
            // accept(2) blocks until a client connects. The loop itself is
            // actor-isolated (so serverFD/isRunning reads are race-free) ;
            // only the blocking syscall runs on a GCD worker. Do NOT use
            // Task.detached here : it shares Swift's cooperative executor,
            // whose threads must never block in POSIX I/O. A few idle
            // clients could otherwise occupy every executor thread.
            let clientFD = await Self.acceptConnection(on: serverFD)

            guard clientFD >= 0 else {
                if !isRunning { break }
                continue
            }

            // **B4 fix** : `Task { ... }` would inherit @MainActor isolation
            // and pin the per-connection read loop to the main actor — a
            // single slow client could then freeze every other command,
            // every watcher and every healthcheck. `Task.detached` cuts
            // the isolation so each connection gets its own cooperative
            // pool slot for the blocking `read()`s.
            Task.detached { [weak self, clientFD] in
                await self?.handleConnection(fd: clientFD)
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

    /// Per-connection read loop. `nonisolated` so the blocking POSIX read
    /// runs off the main actor — only the JSON dispatch hops back into
    /// MainActor via the `await` on `handleRequest`. Without this every
    /// client kept the daemon's main actor parked inside `read()` between
    /// frames, blocking every watcher / healthcheck / other command.
    private nonisolated func handleConnection(fd: Int32) async {
        do {
            while true {
                // Same rule as accept(2) : a client may stay connected and
                // silent indefinitely. Keep blocking read(2) on GCD rather
                // than parking one Swift cooperative-executor thread per
                // idle connection.
                let data = try await Self.readFrame(from: fd)
                // Decode off-actor too — IPCRequest is Sendable so this is
                // safe. Only the engine call below requires MainActor.
                let request = try JSONDecoder().decode(IPCRequest.self, from: data)
                try await handleRequest(request, fd: fd)
            }
        } catch {
            // EOF / framing error / shutdown — normal lifecycle for a CLI
            // client that issued one command and disconnected. We swallow
            // the error here ; sendErrorResponse-worthy failures already
            // emitted their reply earlier in the dispatch.
        }
    }

    /// POSIX accept bridged from a blocking GCD queue into async Swift.
    /// Closing `fd` from stop() wakes accept with -1 and resumes exactly
    /// once.
    private nonisolated static func acceptConnection(on fd: Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: accept(fd, nil, nil))
            }
        }
    }

    /// One complete length-prefixed IPC frame, read on GCD so slow/idle
    /// clients never occupy Swift cooperative-executor threads.
    private nonisolated static func readFrame(from fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try IPCFramer.read(from: fd))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func handleRequest(_ request: IPCRequest, fd: Int32) async throws {
        // **A10 — protocol version gate**. A CLI claiming a version newer
        // than this daemon knows about is rejected with an actionable error.
        // Missing field == legacy (pre-0.6) client, allowed for compat.
        if let clientVersion = request.protocolVersion,
           clientVersion > CockerVersion.ipcProtocolVersion {
            sendErrorResponse(
                requestId: request.id,
                error:
                "cocker CLI is newer than cockerd (client IPC v\(clientVersion), " +
                "daemon v\(CockerVersion.ipcProtocolVersion)). " +
                "Upgrade cockerd to match the CLI : `brew upgrade gloiiire/cocker/cocker`.",
                to: fd)
            return
        }
        do {
            switch request.type {
            case .ping:
                try sendResponse(requestId: request.id, payload: PingResponse(), to: fd)

            case .run:
                CockerLog.shared.debug("srv", ".run received")
                let runReq = try JSONDecoder().decode(RunRequest.self, from: request.payload)
                CockerLog.shared.debug("srv", "decoded RunRequest, image=\(runReq.config.image)")
                let containerID = try await engine.run(config: runReq.config)
                CockerLog.shared.debug("srv", "engine.run returned id=\(containerID)")
                try sendResponse(requestId: request.id, payload: RunResponse(containerID: containerID), to: fd)

            case .start:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.start(id: req.id)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .stop:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                // `-t` was parsed by the CLI and never sent, so the grace
                // period was always the 10 s default.
                try await engine.stop(id: req.id, timeout: req.timeout ?? 10)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .kill:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.kill(id: req.id, signal: req.signal ?? "SIGKILL")
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .restart:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await engine.restart(id: req.id, timeout: req.timeout ?? 10)
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
                try await engine.remove(id: req.id, force: req.force ?? false,
                                        removeVolumes: req.removeVolumes ?? false)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .ps:
                let req = try JSONDecoder().decode(PSRequest.self, from: request.payload)
                let containers = await engine.list(all: req.all, filter: req.filter)
                try sendResponse(requestId: request.id, payload: PSResponse(containers: containers), to: fd)

            case .inspect:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let container = try await engine.inspect(id: req.id)
                try sendResponse(requestId: request.id, payload: container, to: fd)

            case .resize:
                let req = try JSONDecoder().decode(ResizeRequest.self, from: request.payload)
                guard let c = await engine.state.container(id: req.id) else {
                    throw CockerError.containerNotFound(req.id)
                }
                await engine.vmRuntime.resizeTerminal(containerID: c.id,
                                                      rows: req.rows, cols: req.cols)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .wait:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let code = try await engine.wait(id: req.id)
                try sendResponse(requestId: request.id,
                                 payload: WaitResponse(exitCode: code), to: fd)

            case .logs:
                let req = try JSONDecoder().decode(LogsRequest.self, from: request.payload)
                let stream = try await engine.logs(id: req.id, request: req)
                try await streamResponse(requestId: request.id, stream: stream, to: fd)

            case .execInput:
                // Arrives on its own connection : the loop handling the exec
                // itself is busy streaming output and can't read another
                // frame until it finishes.
                let req = try JSONDecoder().decode(ExecInputRequest.self, from: request.payload)
                await engine.execInput(req)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

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
                // `force` was decoded and dropped here, so `volume rm -f`
                // behaved exactly like `volume rm`.
                try await engine.volumes.remove(req.id, force: req.force ?? false)
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
                    try await self.composeProjectGate.withLock(project: Self.composeProject(req)) {
                        try await self.compose.up(request: req, progressHandler: send)
                    }
                }

            case .composeDown:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                try await composeProjectGate.withLock(project: Self.composeProject(req)) {
                    try await self.compose.down(request: req)
                }
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .cp:
                let req = try JSONDecoder().decode(CpRequest.self, from: request.payload)
                try await engine.copy(request: req)
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .rename:
                let req = try JSONDecoder().decode(RenameRequest.self, from: request.payload)
                guard let container = await engine.state.container(id: req.id) else {
                    throw CockerError.containerNotFound(req.id)
                }
                try await engine.state.updateContainer(id: container.id) { c in c.name = req.newName }
                try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)

            case .attach:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                try await handleAttach(req, requestId: request.id, to: fd)

            case .diff:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let result = try await engine.diff(containerID: req.id)
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .save:
                let req = try JSONDecoder().decode(SaveRequest.self, from: request.payload)
                let result = try await handleSave(req)
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .load:
                let req = try JSONDecoder().decode(LoadRequest.self, from: request.payload)
                let msg = try await handleLoad(req)
                try sendResponse(requestId: request.id, payload: msg, to: fd)

            case .imageHistory:
                let req = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
                let entries = try await engine.imageHistory(req.id)
                try sendResponse(requestId: request.id, payload: ImageHistoryResponse(entries: entries), to: fd)

            case .imagePrune:
                // Backward-compatible: an older CLI sends EmptyPayload, which
                // fails to decode as ImagePruneRequest → default to all:false.
                let pruneReq = (try? JSONDecoder().decode(ImagePruneRequest.self, from: request.payload)) ?? ImagePruneRequest(all: false)
                let result = try await engine.imagePrune(all: pruneReq.all)
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
                let result = try await engine.systemDf()
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .composeLs:
                let result = await engine.composeProjects()
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .composeLogs:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                try await handleComposeLogs(req, requestId: request.id, to: fd)

            case .composePs:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                let pName = ProjectName.normalize(req.projectName ?? URL(fileURLWithPath: req.composePath).deletingLastPathComponent().lastPathComponent)
                let filter = ["label": "com.cocker.project=\(pName)"]
                let containers = await engine.list(all: true, filter: filter)
                try sendResponse(requestId: request.id, payload: PSResponse(containers: containers), to: fd)

            case .composeBuild:
                let req = try JSONDecoder().decode(ComposeRequest.self, from: request.payload)
                try await sendStreamingOperation(requestId: request.id, to: fd) { send in
                    try await self.composeProjectGate.withLock(project: Self.composeProject(req)) {
                        try await self.compose.build(request: req, progressHandler: send)
                    }
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
                try await composeProjectGate.withLock(project: Self.composeProject(req)) {
                    try await self.handleComposeRestart(req)
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
                let stream = engine.eventStream()
                try await streamResponse(requestId: request.id, stream: stream, to: fd)

            case .top:
                try sendResponse(requestId: request.id, payload: "PID   USER   COMMAND\n1     root   /sbin/init\n", to: fd)

            case .commit:
                let req = try JSONDecoder().decode(CommitRequest.self, from: request.payload)
                let result = try await engine.commitContainer(req)
                try sendResponse(requestId: request.id, payload: result, to: fd)

            case .export:
                let req = try JSONDecoder().decode(ExportRequest.self, from: request.payload)
                if let outputPath = req.outputPath {
                    // v2 same-host handoff : write the tar where the client
                    // asked, return only metadata. No 100 MB frame cap, no
                    // base64, no full buffer in RAM.
                    let tarURL = try await engine.exportContainerToTar(req.containerID)
                    let url = URL(fileURLWithPath: outputPath)
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: tarURL, to: url)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
                    try sendResponse(requestId: request.id,
                                     payload: SaveResponse(tarData: Data(),
                                                           filePath: outputPath,
                                                           byteCount: size),
                                     to: fd)
                } else {
                    let tarData = try await engine.exportContainer(req.containerID)
                    try sendResponse(requestId: request.id, payload: SaveResponse(tarData: tarData), to: fd)
                }

            case .containerImport:
                let req = try JSONDecoder().decode(ContainerImportRequest.self, from: request.payload)
                let tarData: Data
                if let inputPath = req.inputPath {
                    // v2 : read the tar straight from disk.
                    tarData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
                } else {
                    tarData = req.tarData
                }
                let img = try await engine.images.importTar(tarData, tag: req.tag)
                try sendResponse(requestId: request.id, payload: img, to: fd)

            case .update:
                let req = try JSONDecoder().decode(UpdateRequest.self, from: request.payload)
                try await engine.updateResources(req)
                // Return the container rather than an empty payload: the CLI
                // needs its status to say whether the new limits are live or
                // waiting for a restart, and a response that carries what
                // changed is more use to any client than one that carries
                // nothing. Older CLIs discarded this payload anyway.
                if let updated = await engine.state.container(id: req.containerID) {
                    try sendResponse(requestId: request.id, payload: updated, to: fd)
                } else {
                    try sendResponse(requestId: request.id, payload: EmptyPayload(), to: fd)
                }

            case .setup:
                try await performSetup(requestId: request.id, to: fd)

            default:
                sendErrorResponse(requestId: request.id, error: "Unknown request type: \(request.type.rawValue)", to: fd)
            }
        } catch let error as CockerError {
            // Send the kind alongside the message so the CLI can exit 127 for
            // "no such container" rather than a blanket 1.
            sendErrorResponse(requestId: request.id, error: error.description,
                              code: error.exitCode, to: fd)
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

    private func sendErrorResponse(requestId: String, error: String, code: Int32? = nil,
                                   to fd: Int32) {
        let response = IPCResponse(requestId: requestId, error: error, errorCode: code)
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
        // Serialize concurrent writes to the same fd.
        //
        // compose logs -f spawns one Task per followed container and
        // multiplexes their output through `send(...)`. Without this
        // lock, two Tasks can interleave their IPCFramer.write calls
        // (length header from one, payload bytes from another) and the
        // client surfaces the result as
        //   "DecodingError.dataCorrupted: Unable to convert data to a
        //   string using the detected encoding."
        // because what reaches JSONDecoder is half-frames glued together.
        let writer = FrameWriteSerializer()
        // **B20 fix** : wrap the operation in a child Task so we can
        // cancel it when the writer detects EPIPE / EBADF. A monitor
        // task polls writer.isAlive ; once it flips we cancel the
        // operation, which cooperatively cancels the per-container
        // log tasks inside compose-logs. Without this the children
        // would happily keep streaming bytes into a closed pipe and
        // leak Tasks until the followed containers exited.
        let operationTask = Task {
            try await operation { event in
                guard writer.isAlive else { return }
                let response = try? IPCResponse(requestId: requestId, payload: event, isStreaming: true, isLast: false)
                if let data = try? JSONEncoder().encode(response) {
                    writer.write(data, to: fd)
                }
            }
        }
        let monitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !writer.isAlive {
                    operationTask.cancel()
                    return
                }
            }
        }
        defer { monitorTask.cancel() }
        do {
            try await operationTask.value
        } catch {
            // Propagate non-cancellation errors. A cancellation from the
            // monitor is normal end-of-stream and shouldn't bubble.
            if !(error is CancellationError) { throw error }
        }
        // Skip the final marker when the connection is already gone — the
        // write would just fail. When healthy, emit the canonical
        // end-of-stream sentinel.
        guard writer.isAlive else { return }
        let done = try IPCResponse(requestId: requestId, payload: StreamEvent(stream: .status, data: ""), isStreaming: true, isLast: true)
        let doneData = try JSONEncoder().encode(done)
        try? IPCFramer.write(doneData, to: fd)
    }

    /// Wraps IPCFramer.write in an NSLock so concurrent callers can't
    /// interleave the framer's two-step length-then-payload pattern.
    /// Tracks an `alive` flag : on any IPCFramer.write throw (most often
    /// EPIPE / EBADF after the client closed), every subsequent write is
    /// dropped AND `isAlive` returns false so the streaming wrapper can
    /// cancel its children. The class is `@unchecked Sendable` because
    /// NSLock is sound under concurrent access ; we just need to
    /// convince Swift 6's checker.
    private final class FrameWriteSerializer: @unchecked Sendable {
        private let lock = NSLock()
        private var alive = true
        func write(_ data: Data, to fd: Int32) {
            lock.lock(); defer { lock.unlock() }
            guard alive else { return }
            do {
                try IPCFramer.write(data, to: fd)
            } catch {
                alive = false
            }
        }
        var isAlive: Bool {
            lock.lock(); defer { lock.unlock() }
            return alive
        }
    }

    // MARK: - Save / Load (transport shims)

    /// Transport-side shim : business logic lives in
    /// `ContainerEngine.saveImageToTar`. v2 clients pass `outputPath` and
    /// the tar is MOVED there directly — nothing rides through the JSON
    /// frame. Legacy clients (no outputPath) still get in-band bytes,
    /// subject to the historical 100 MB frame cap.
    private func handleSave(_ req: SaveRequest) async throws -> SaveResponse {
        let tarURL = try await engine.saveImageToTar(reference: req.image)
        if let outputPath = req.outputPath {
            let dst = URL(fileURLWithPath: outputPath)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tarURL, to: dst)
            let attrs = try? FileManager.default.attributesOfItem(atPath: dst.path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            return SaveResponse(tarData: Data(), filePath: outputPath, byteCount: size)
        }
        defer { try? FileManager.default.removeItem(at: tarURL) }
        let tarData = (try? Data(contentsOf: tarURL)) ?? Data()
        return SaveResponse(tarData: tarData)
    }

    /// Transport-side shim over `ContainerEngine.loadImageFromTar`.
    /// v2 clients pass `inputPath` (a file already on disk) ; legacy
    /// clients ship the bytes in-band and we stage them to a temp file.
    private func handleLoad(_ req: LoadRequest) async throws -> String {
        if let inputPath = req.inputPath {
            return try await engine.loadImageFromTar(at: URL(fileURLWithPath: inputPath))
        }
        let tmpTar = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-load-\(UUID().uuidString).tar")
        try req.tarData.write(to: tmpTar)
        defer { try? FileManager.default.removeItem(at: tmpTar) }
        return try await engine.loadImageFromTar(at: tmpTar)
    }

    // MARK: - Attach / history / compose helpers (A2)

    /// `attach` is a log follower, not a one-shot backlog reader. Keeping the
    /// request construction in one testable place pins the two parts of that
    /// contract: replay the last 20 events, then remain subscribed to live
    /// console output until the VM exits or the client disconnects.
    nonisolated static func attachLogsRequest(for id: String) -> LogsRequest {
        LogsRequest(id: id, follow: true, tail: 20)
    }

    private func handleAttach(_ req: ContainerIDRequest, requestId: String, to fd: Int32) async throws {
        let logsRequest = Self.attachLogsRequest(for: req.id)
        try await sendStreamingOperation(requestId: requestId, to: fd) { [self] send in
            // ContainerEngine.logs subscribes to VMRuntime's live stream
            // before returning its backlog snapshot, so output cannot fall
            // into a history/live race window during attachment.
            let events = try await self.engine.logs(id: req.id, request: logsRequest)
            for await event in events {
                if Task.isCancelled { return }
                send(event)
            }
        }
    }

    private func handleComposeLogs(_ req: ComposeRequest, requestId: String, to fd: Int32) async throws {
        let pName = ProjectName.normalize(req.projectName ?? URL(fileURLWithPath: req.composePath).deletingLastPathComponent().lastPathComponent)
        let filter = ["label": "com.cocker.project=\(pName)"]
        var containers = await engine.list(all: true, filter: filter)
        if !req.services.isEmpty {
            let pin = Set(req.services)
            containers = containers.filter { c in
                if let svc = c.labels["com.cocker.service"], pin.contains(svc) { return true }
                return pin.contains(c.name) || pin.contains(where: { c.name.hasSuffix("_\($0)_1") })
            }
        }
        try await sendStreamingOperation(requestId: requestId, to: fd) { send in
            // Always emit the tail backlog first so the user sees context
            // even when nothing new is being printed. VMRuntime.logs
            // guarantees each event is newline-terminated.
            for container in containers {
                let backlog = self.engine.vmRuntime.logs(containerID: container.id, tail: req.tail)
                for event in backlog {
                    send(StreamEvent(stream: event.stream,
                                     data: Self.prefixEachLine(event.data, with: container.name)))
                }
            }
            if !req.follow { return }
            // Follow : open one child task per container, multiplex output
            // through `send` until every child stream ends (or the parent
            // task gets cancelled — see B20 fix in sendStreamingOperation).
            await withTaskGroup(of: Void.self) { group in
                for container in containers {
                    let name = container.name
                    let id = container.id
                    group.addTask {
                        let logsReq = LogsRequest(id: id, follow: true, tail: 0)
                        // Console output arrives in arbitrary chunks, so a
                        // line can span several events. Prefixing per event
                        // would stamp the name mid-line and leave the rest
                        // of the line bare; buffer to line boundaries so
                        // every line gets exactly one prefix.
                        let assembler = LineBuffer()
                        do {
                            let stream = try await self.engine.logs(id: id, request: logsReq)
                            for try await event in stream {
                                if Task.isCancelled { return }
                                for line in assembler.feed(event.data) {
                                    send(StreamEvent(stream: event.stream,
                                                     data: Self.prefixEachLine(line, with: name)))
                                }
                            }
                            // A final line with no trailing newline must
                            // still reach the client.
                            if let rest = assembler.flush() {
                                send(StreamEvent(stream: .stdout,
                                                 data: Self.prefixEachLine(rest, with: name)))
                            }
                        } catch {
                            send(StreamEvent(stream: .stderr, data: "[\(name)] log stream error: \(error)\n"))
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }

    /// Stamp `[name] ` on every line of `text`, keeping line endings (CRLF
    /// included) exactly as the container emitted them. A multi-line chunk
    /// would otherwise get a single prefix on its first line only.
    ///
    /// `nonisolated` because it is pure text work called from the detached
    /// per-container log tasks.
    nonisolated static func prefixEachLine(_ text: String, with name: String) -> String {
        guard !text.isEmpty else { return text }
        var out = String.UnicodeScalarView()
        var atLineStart = true
        for scalar in text.unicodeScalars {
            if atLineStart {
                out.append(contentsOf: "[\(name)] ".unicodeScalars)
                atLineStart = false
            }
            out.append(scalar)
            if scalar == "\n" { atLineStart = true }
        }
        return String(out)
    }

    private func handleComposeRestart(_ req: ComposeRequest) async throws {
        let pName = ProjectName.normalize(req.projectName ?? URL(fileURLWithPath: req.composePath).deletingLastPathComponent().lastPathComponent)
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
    }

    private nonisolated static func composeProject(_ req: ComposeRequest) -> String {
        ProjectName.normalize(req.projectName ?? URL(fileURLWithPath: req.composePath)
            .deletingLastPathComponent().lastPathComponent)
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
        send("     Verify the download with the published SHA-256 checksums:")
        send("       shasum -a 256 vmlinuz")
        send("     and the Alpine signing key — see https://www.alpinelinux.org/keys/")
        send("  2. Place vmlinuz at: \(kernelDir.path)/vmlinuz")
        send("  3. Place initrd.img at: \(kernelDir.path)/initrd.img")
        send("")
        send("Alternatively, install Apple's `container` runtime:")
        send("  → https://github.com/apple/container/releases (.pkg)")
        send("  cockerd will auto-detect the Apple-provided kernel on next setup.")
        send("")

        // Check if apple/container kernel is available. The .pkg installer
        // and Homebrew both drop the kernel under share/ or libexec/.
        let home = NSHomeDirectory()
        let appleKernelPaths = [
            "/opt/homebrew/share/container/kernel",
            "/usr/local/share/container/kernel",
            "/usr/local/libexec/container/kernel",
            "/opt/homebrew/libexec/container/kernel",
            "\(home)/.container/kernel",
            "\(home)/Library/Application Support/com.apple.container/kernel",
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
