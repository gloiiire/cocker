import Foundation
import CockerCore

// Docker Engine API v1.47 — HTTP REST server over Unix socket
// Socket: ~/.cocker/docker.sock (or /var/run/cocker.sock)
//
// Compatible with: docker-compose, docker CLI (DOCKER_HOST=unix://~/.cocker/docker.sock),
//                  Portainer, Lazydocker, and any Docker SDK

@MainActor
final class DockerAPIServer {
    private let socketPath: String
    private let engine: ContainerEngine
    private var serverFD: Int32 = -1
    private var isRunning = false

    /// Compatibility shim — the canonical formatter now lives in CockerCore
    /// so `cocker inspect` and the Docker API agree byte-for-byte on the
    /// same timestamp. Kept here so existing tests against
    /// `DockerAPIServer.rfc3339Nano` still resolve.
    nonisolated static func rfc3339Nano(_ date: Date) -> String {
        CockerCore.rfc3339Nano(date)
    }

    // In-flight exec sessions: execID -> container ID + command
    private var execSessions: [String: ExecSession] = [:]

    /// How many finished exec sessions stay inspectable. Well past what any
    /// client reads back, and bounded so the daemon's footprint stays flat.
    private static let finishedExecRetention = 64

    struct ExecSession {
        let containerID: String
        let command: [String]
        let env: [String: String]
        let tty: Bool
        var user: String?
        var workdir: String?
        /// nil until the command finishes. `/exec/{id}/json` reports
        /// `Running: true` while it is nil, exactly like Docker.
        var exitCode: Int32?
    }

    init(socketPath: String, engine: ContainerEngine) {
        self.socketPath = socketPath
        self.engine = engine
    }

    func start() async throws {
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CockerError.internalError("docker.sock: socket() failed") }

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
            throw CockerError.internalError("docker.sock: bind() failed")
        }

        guard listen(fd, 256) == 0 else {
            close(fd)
            throw CockerError.internalError("docker.sock: listen() failed")
        }

        // Same secrecy contract as the native IPC socket : 0600 means
        // only the cockerd owner can drive the daemon. Anyone with this
        // socket can run privileged containers, bind-mount the host, and
        // exec into them as root — treat it like an SSH key.
        chmod(socketPath, 0o600)
        self.serverFD = fd
        self.isRunning = true
        CockerLog.shared.info("docker-api", "listening on \(socketPath)")
        CockerLog.shared.info("docker-api", "export DOCKER_HOST=unix://\(socketPath)")

        await acceptLoop()
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptLoop() async {
        while isRunning {
            // accept(2) is blocking. Run it on GCD, not Task.detached :
            // detached tasks still consume Swift's cooperative executor
            // and idle sockets could starve every async daemon task.
            let clientFD = await Self.acceptConnection(on: serverFD)
            guard clientFD >= 0 else { continue }

            Task { await self.handleConnection(fd: clientFD) }
        }
    }

    private func handleConnection(fd: Int32) async {
        defer { close(fd) }
        // Docker clients may pipeline multiple requests on one connection
        while true {
            // HTTP parsing performs blocking read(2). Bridge it through GCD
            // so a keep-alive client waiting between requests doesn't park
            // a cooperative-executor thread.
            let parsed: HTTPRequest?
            do {
                parsed = try await Self.readHTTPRequest(from: fd)
            } catch {
                break
            }
            guard let request = parsed, !request.path.isEmpty else { break }
            let keepAlive = request.headers["connection"]?.lowercased() != "close"
            await routeRequest(request, fd: fd)
            if !keepAlive { break }
        }
    }

    private nonisolated static func acceptConnection(on fd: Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: accept(fd, nil, nil))
            }
        }
    }

    private nonisolated static func readHTTPRequest(from fd: Int32) async throws -> HTTPRequest? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try parseHTTPRequest(from: fd))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// TLS-TCP bridge entry point. Network.framework's NWConnection
    /// doesn't expose a raw socket FD, so `DockerAPITLSListener`
    /// builds two pipes : one for the request body (readFD) and one
    /// for the response (writeFD). This method drives the same
    /// `routeRequest` path as the Unix socket loop, just with the
    /// read and write halves split. One request per call ; TLS
    /// pipelining is rare in Docker clients.
    /// In-memory request → response path used by `DockerAPITLSListener`
    /// to keep TLS traffic out of the fd-pipe bridge (which proved
    /// fragile because Foundation `Pipe` deinits close fds, the kernel
    /// reuses fd numbers, and bytes leaked across pipes). This drains
    /// the response into a `socketpair(AF_UNIX, SOCK_STREAM)` so the
    /// existing `(req, fd)` handlers can write headers + body normally
    /// — we just read the other end of the socketpair afterward.
    func routeAndSerialize(_ req: HTTPRequest) async -> Data {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard rc == 0 else {
            // Fall back to a minimal 500 if we can't even allocate a
            // socketpair. Unlikely outside of fd-exhaustion.
            let r = HTTPResponse.error("internal: socketpair failed", status: 500)
            return r.serialize()
        }
        let writerFD = fds[0]
        let readerFD = fds[1]
        // Drain concurrently. Waiting until routeRequest returns can deadlock
        // once a streaming response fills the socketpair buffer, particularly
        // because the router is MainActor-isolated.
        async let collected = Self.drainResponse(fd: readerFD)
        await routeRequest(req, fd: writerFD)
        close(writerFD)
        return await collected
    }

    private nonisolated static func drainResponse(fd: Int32) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { close(fd) }
                var collected = Data()
                var buf = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let n = Darwin.read(fd, &buf, buf.count)
                    if n > 0 {
                        collected.append(contentsOf: buf.prefix(Int(n)))
                    } else if n < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                continuation.resume(returning: collected)
            }
        }
    }

    // MARK: - Router

    private func routeRequest(_ req: HTTPRequest, fd: Int32) async {
        let path = req.path
        let method = req.method

        // Split path into segments: /containers/abc123/start -> ["containers", "abc123", "start"]
        let segments = path.split(separator: "/").map(String.init)

        let response: HTTPResponse?

        switch (method, segments.first ?? "") {

        // ── Prometheus metrics ──────────────────────────────────
        // Exposed at /metrics for compat with most scrapers. The Docker
        // Engine HTTP API namespace doesn't normally use this path so
        // there's no collision.
        case ("GET", "metrics"):
            response = await handleMetrics()

        // ── Ping & version ──────────────────────────────────────
        case ("GET", "_ping"), ("HEAD", "_ping"):
            response = HTTPResponse(status: 200, headers: [
                "Content-Type": "text/plain",
                "Docker-Experimental": "false",
                "Ostype": "linux",
                "Server": "Docker/\(CockerVersion.version) (cocker)"
            ], body: Data("OK".utf8))

        case ("GET", "version"):
            var sysinfo = utsname(); uname(&sysinfo)
            let kernel = withUnsafeBytes(of: sysinfo.release) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            response = .json(DockerVersion(KernelVersion: kernel))

        // ── System info ─────────────────────────────────────────
        case ("GET", "info"):
            response = await handleInfo()

        case ("GET", "events"):
            await handleEvents(req: req, fd: fd)
            response = nil

        // ── Containers ──────────────────────────────────────────
        case ("GET", "containers") where segments.count == 2 && segments[1] == "json":
            response = await handleContainerList(req: req)

        case ("POST", "containers") where segments.count == 2 && segments[1] == "create":
            response = await handleContainerCreate(req: req)

        case ("GET", "containers") where segments.count == 3 && segments[2] == "json":
            response = await handleContainerInspect(id: segments[1])

        case ("GET", "containers") where segments.count == 3 && segments[2] == "logs":
            await handleContainerLogs(req: req, id: segments[1], fd: fd)
            response = nil

        case ("POST", "containers") where segments.count == 3 && segments[2] == "start":
            response = await handleContainerStart(id: segments[1])

        case ("POST", "containers") where segments.count == 3 && segments[2] == "stop":
            response = await handleContainerStop(id: segments[1], req: req)

        case ("POST", "containers") where segments.count == 3 && segments[2] == "kill":
            response = await handleContainerKill(id: segments[1], req: req)

        case ("POST", "containers") where segments.count == 3 && segments[2] == "restart":
            response = await handleContainerRestart(id: segments[1])

        case ("POST", "containers") where segments.count == 3 && segments[2] == "pause":
            response = await handleContainerPause(id: segments[1])

        case ("POST", "containers") where segments.count == 3 && segments[2] == "unpause":
            response = await handleContainerUnpause(id: segments[1])

        case ("DELETE", "containers") where segments.count == 2:
            response = await handleContainerRemove(id: segments[1], req: req)

        case ("POST", "containers") where segments.count == 3 && segments[2] == "attach":
            await handleContainerAttach(id: segments[1], req: req, fd: fd)
            response = nil

        case ("POST", "containers") where segments.count == 3 && segments[2] == "resize":
            response = await handleResize(id: segments[1], req: req, isExec: false)

        case ("POST", "exec") where segments.count == 3 && segments[2] == "resize":
            response = await handleResize(id: segments[1], req: req, isExec: true)

        // ── Archive (docker cp, Dev Containers, Testcontainers) ──
        case ("GET", "containers") where segments.count == 3 && segments[2] == "archive":
            response = await handleArchiveGet(id: segments[1], req: req)

        case ("HEAD", "containers") where segments.count == 3 && segments[2] == "archive":
            response = await handleArchiveHead(id: segments[1], req: req)

        case ("PUT", "containers") where segments.count == 3 && segments[2] == "archive":
            response = await handleArchivePut(id: segments[1], req: req)

        case ("GET", "containers") where segments.count == 3 && segments[2] == "top":
            response = await handleContainerTop(id: segments[1])

        case ("POST", "containers") where segments.count == 3 && segments[2] == "rename":
            response = await handleContainerRename(id: segments[1], req: req)

        case ("GET", "containers") where segments.count == 3 && segments[2] == "stats":
            response = await handleContainerStats(id: segments[1])

        case ("POST", "containers") where segments.count == 3 && segments[2] == "wait":
            response = await handleContainerWait(id: segments[1])

        // ── Exec ────────────────────────────────────────────────
        case ("POST", "containers") where segments.count == 3 && segments[2] == "exec":
            response = await handleExecCreate(id: segments[1], req: req)

        case ("POST", "exec") where segments.count == 3 && segments[2] == "start":
            await handleExecStart(id: segments[1], req: req, fd: fd)
            response = nil

        case ("GET", "exec") where segments.count == 3 && segments[2] == "json":
            response = handleExecInspect(id: segments[1])

        // ── Images ──────────────────────────────────────────────
        case ("GET", "images") where segments.count == 2 && segments[1] == "json":
            response = await handleImageList(req: req)

        case ("POST", "images") where segments.count == 2 && segments[1] == "create":
            await handleImagePull(req: req, fd: fd)
            response = nil

        // `>= 3` and a rejoined name : a registry- or namespace-qualified
        // reference (`ghcr.io/org/app`, `library/redis`) contributes several
        // path segments, so the old `== 3` guard sent every one of them to
        // the 501 fallback. Compose inspects an image right after pulling it.
        case ("GET", "images") where segments.count >= 3 && segments.last == "json":
            response = await handleImageInspect(name: Self.imageName(from: segments))

        case ("DELETE", "images") where segments.count >= 2:
            response = await handleImageRemove(
                name: Self.imageName(from: segments, hasVerbSuffix: false), req: req)

        case ("POST", "images") where segments.count >= 3 && segments.last == "tag":
            response = await handleImageTag(name: Self.imageName(from: segments), req: req)

        case ("POST", "build"):
            await handleImageBuild(req: req, fd: fd)
            response = nil

        case ("GET", "images") where segments.count == 2 && segments[1] == "search":
            response = .json([DockerEmpty]())

        // ── Networks ────────────────────────────────────────────
        // `segments.count == 1` matters : without it this case also matched
        // `/networks/{id}`, shadowing the inspect case below into dead code.
        // `compose up` does a NetworkInspect on every run and got a JSON
        // *array* where it expected an object.
        case ("GET", "networks") where segments.count == 1:
            response = await handleNetworkList(req: req)

        case ("POST", "networks") where segments.count == 2 && segments[1] == "create":
            response = await handleNetworkCreate(req: req)

        case ("GET", "networks") where segments.count == 2:
            response = await handleNetworkInspect(id: segments[1])

        case ("DELETE", "networks") where segments.count == 2:
            response = await handleNetworkRemove(id: segments[1])

        case ("POST", "networks") where segments.count == 3 && segments[2] == "connect":
            response = await handleNetworkConnect(id: segments[1], req: req)

        case ("POST", "networks") where segments.count == 3 && segments[2] == "disconnect":
            response = await handleNetworkDisconnect(id: segments[1], req: req)

        case ("POST", "networks") where segments.count == 2 && segments[1] == "prune":
            response = HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                    body: Data(#"{"NetworksDeleted":[]}"#.utf8))

        // ── Volumes ─────────────────────────────────────────────
        // Same shadowing bug as `/networks` above.
        case ("GET", "volumes") where segments.count == 1:
            response = await handleVolumeList(req: req)

        case ("POST", "volumes") where segments.count == 2 && segments[1] == "create":
            response = await handleVolumeCreate(req: req)

        case ("GET", "volumes") where segments.count == 2:
            response = await handleVolumeInspect(name: segments[1])

        case ("DELETE", "volumes") where segments.count == 2:
            response = await handleVolumeRemove(name: segments[1], req: req)

        case ("POST", "volumes") where segments.count == 2 && segments[1] == "prune":
            response = HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                    body: Data(#"{"VolumesDeleted":[],"SpaceReclaimed":0}"#.utf8))

        // ── System ──────────────────────────────────────────────
        case ("POST", "containers") where segments.count == 2 && segments[1] == "prune":
            response = await handleContainerPrune()

        case ("POST", "images") where segments.count == 2 && segments[1] == "prune":
            response = await handleImagePrune(req: req)

        // ── Image history ────────────────────────────────────────
        // Returns one history entry per layer for `docker history <img>` /
        // `docker image history`. Cocker doesn't track per-instruction
        // history yet ; we synthesise one entry per layer digest so the
        // common consumer (a UI listing layer sizes) gets a reasonable
        // shape instead of a 501.
        case ("GET", "images") where segments.count >= 3 && segments.last == "history":
            response = await handleImageHistory(name: Self.imageName(from: segments))

        // ── Container filesystem diff (no-op) ────────────────────
        // `docker container diff <id>` lists files added/changed/deleted
        // since the image's rootfs. Cocker runs each container as a real
        // VM with a clonefile rootfs and doesn't keep a baseline diff ;
        // we return an empty list rather than a 501 so tooling like
        // Portainer doesn't error out at inspect time.
        case ("GET", "containers") where segments.count == 3 && segments[2] == "changes":
            response = await handleContainerChanges(id: segments[1])

        // ── Ping / version handshake ─────────────────────────────
        // `docker version` issues GET /_ping (and tolerates the HEAD
        // variant) before its real handshake. Bare 200 OK with the
        // text body "OK" matches dockerd's response byte-for-byte.
        case ("GET", "_ping"), ("HEAD", "_ping"):
            response = HTTPResponse(status: 200,
                headers: ["Content-Type": "text/plain",
                          "Api-Version": "1.41",
                          "Docker-Experimental": "false",
                          "Cocker-Version": CockerVersion.version],
                body: Data("OK".utf8))

        default:
            print("[docker-api] Unhandled: \(method) \(path)")
            response = .error("Not implemented: \(method) \(path)", status: 501)
        }

        if let response {
            _ = response.write(to: fd)
        }
    }

    // MARK: - Prometheus metrics

    private func handleMetrics() async -> HTTPResponse {
        let info = await engine.info()
        let metrics: [PromMetric] = [
            PromMetric(
                name: "cocker_containers_total",
                help: "Number of containers known to cockerd (running + stopped)",
                type: .gauge,
                samples: [PromSample(value: Double(info.containers))]
            ),
            PromMetric(
                name: "cocker_containers_running",
                help: "Number of containers currently running",
                type: .gauge,
                samples: [PromSample(value: Double(info.containersRunning))]
            ),
            PromMetric(
                name: "cocker_images_total",
                help: "Number of images stored locally",
                type: .gauge,
                samples: [PromSample(value: Double(info.images))]
            ),
            PromMetric(
                name: "cocker_volumes_total",
                help: "Number of named volumes",
                type: .gauge,
                samples: [PromSample(value: Double(info.volumes))]
            ),
            PromMetric(
                name: "cocker_networks_total",
                help: "Number of custom networks defined",
                type: .gauge,
                samples: [PromSample(value: Double(info.networks))]
            ),
            PromMetric(
                name: "cocker_build_info",
                help: "Static build information",
                type: .gauge,
                samples: [PromSample(value: 1, labels: [
                    ("version", CockerVersion.version),
                    ("api_version", CockerVersion.apiVersion),
                ])]
            ),
        ]
        return HTTPResponse(
            status: 200,
            headers: ["Content-Type": PrometheusExposition.contentType],
            body: Data(PrometheusExposition.render(metrics).utf8)
        )
    }

    // MARK: - System handlers

    private func handleInfo() async -> HTTPResponse {
        let info = await engine.info()
        let dockerInfo = DockerInfo(
            ID: "COCKER:\(ProcessInfo.processInfo.hostName)",
            Containers: info.containers,
            ContainersRunning: info.containersRunning,
            ContainersPaused: 0,
            ContainersStopped: info.containers - info.containersRunning,
            Images: info.images,
            DockerRootDir: info.cockerRootDir,
            Name: ProcessInfo.processInfo.hostName,
            NCPU: info.cpus,
            MemTotal: Int(info.totalMemory),
            Warnings: ["Cocker is not Docker — some features may behave differently"],
            SecurityOptions: []
        )
        return .json(dockerInfo)
    }

    private func handleEvents(req: HTTPRequest, fd: Int32) async {
        let writer = HTTPStreamWriter(fd: fd)
        writer.writeHeaders(contentType: "application/json")
        // Docker passes filter dicts URL-encoded as JSON via `?filters=`.
        // We parse the three most-used keys (event/type/container) and
        // drop everything else — matches `docker events --filter` usage
        // in the wild without dragging in the full filter language.
        let filterSpec = Self.parseEventsFilter(req.query["filters"])
        let stream = engine.eventStream()
        for await event in stream {
            // Engine event wire format is "<type>\t<action>\t<id>" — split
            // it back into the proper Docker fields so `docker events` /
            // any filter consumer sees the canonical shape (Action,
            // Actor.ID, Type) rather than a single status blob.
            let parts = event.data.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            let type = parts.count > 0 ? String(parts[0]) : "container"
            let action = parts.count > 1 ? String(parts[1]) : event.data
            let id = parts.count > 2 ? String(parts[2]) : ""
            // Docker's filter `--filter event=health_status` matches against
            // Action's prefix before the colon (`health_status: healthy`
            // matches `event=health_status`). Keep the full string in Action
            // for downstream consumers ; only the filter compares the prefix.
            let actionKey = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
            if !filterSpec.events.isEmpty && !filterSpec.events.contains(actionKey) { continue }
            if !filterSpec.types.isEmpty && !filterSpec.types.contains(type) { continue }
            if !filterSpec.containerIDs.isEmpty
                && !filterSpec.containerIDs.contains(where: { id.hasPrefix($0) }) { continue }
            let dockerEvent = DockerEvent(
                status: action,
                id: id,
                from: "",
                eventType: type,
                Action: action,
                Actor: .init(ID: id, Attributes: [:]),
                scope: "local",
                time: Int64(Date().timeIntervalSince1970),
                timeNano: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            )
            if let data = try? JSONEncoder().encode(dockerEvent) {
                writer.writeChunk(data + Data("\n".utf8))
            }
        }
        writer.finish()
    }

    struct EventsFilterSpec {
        var events: Set<String>
        var types: Set<String>
        var containerIDs: Set<String>
    }

    /// Parse Docker's `?filters=<url-encoded-json>` URL parameter into a
    /// minimal `EventsFilterSpec`. Docker's wire format is a JSON object
    /// whose values are arrays of strings :
    ///   `{"event":["start","health_status"],"container":["abc123"]}`.
    /// Missing / malformed payload → empty filter (matches all).
    nonisolated static func parseEventsFilter(_ raw: String?) -> EventsFilterSpec {
        guard let raw, !raw.isEmpty,
              let data = raw.removingPercentEncoding?.data(using: .utf8)
                       ?? raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else {
            return EventsFilterSpec(events: [], types: [], containerIDs: [])
        }
        return EventsFilterSpec(
            events: Set(obj["event"] ?? []),
            types: Set(obj["type"] ?? []),
            containerIDs: Set(obj["container"] ?? [])
        )
    }

    // MARK: - Container handlers

    private func handleContainerList(req: HTTPRequest) async -> HTTPResponse {
        var all = req.query["all"] == "true" || req.query["all"] == "1"
        let filters: DockerFilters
        do {
            filters = try DockerFilters.parse(req.query["filters"])
            try filters.requireSupported(DockerFilters.containerKeys)
        } catch {
            return .error("\(error)", status: 400)
        }
        // Asking for a non-running status implies looking past running
        // containers, exactly as Docker does — otherwise
        // `--filter status=exited` returns nothing without `-a`.
        if filters.values("status").contains(where: { $0 != "running" }) || !filters.values("exited").isEmpty {
            all = true
        }
        let containers = await engine.list(all: all)
        let summaries = containers.filter { filters.matches(container: $0) }
                                  .map { DockerContainerSummary(from: $0) }
        return .json(summaries)
    }

    private func handleContainerCreate(req: HTTPRequest) async -> HTTPResponse {
        guard let createReq = decodeJSON(DockerContainerCreateRequest.self, from: req.body) else {
            return .error("Invalid request body", status: 400)
        }

        let name = req.query["name"]
        var config = RunConfig(image: createReq.Image)
        config.name = name
        config.command = createReq.Cmd?.array ?? []
        // Decoded and dropped before — `docker run --entrypoint` and compose
        // `entrypoint:` over the API both had no effect.
        config.entrypoint = createReq.Entrypoint?.array
        config.hostname = createReq.Hostname
        config.workdir = createReq.WorkingDir
        config.tty = createReq.Tty ?? false
        config.interactive = createReq.OpenStdin ?? false

        // Environment
        if let env = createReq.Env {
            for e in env {
                let parts = e.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { config.env[String(parts[0])] = String(parts[1]) }
            }
        }

        config.labels = createReq.Labels ?? [:]

        // Host config
        if let hc = createReq.HostConfig {
            config.networkMode = NetworkMode(rawValue: hc.NetworkMode ?? "bridge") ?? .nat
            config.rm = hc.AutoRemove ?? false
            config.restartPolicy = RestartPolicy(rawValue: hc.RestartPolicy?.Name ?? "no") ?? .no

            if let mem = hc.Memory, mem > 0 { config.memoryMB = UInt64(mem / 1024 / 1024) }
            if let nano = hc.NanoCpus, nano > 0 { config.cpuCount = max(1, Int(nano / 1_000_000_000)) }

            config.capAdd = hc.CapAdd ?? []
            config.capDrop = hc.CapDrop ?? []

            // Binds -> volumes
            config.volumes = (hc.Binds ?? []).compactMap { bind in
                let parts = bind.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count >= 2 {
                    let ro = parts.count == 3 && parts[2].contains("ro")
                    return VolumeMount(source: parts[0], destination: parts[1], readOnly: ro)
                }
                return nil
            }

            // Mount objects
            if let mounts = hc.Mounts {
                for m in mounts {
                    if let src = m.Source, let dst = m.Target {
                        config.volumes.append(VolumeMount(source: src, destination: dst, readOnly: m.ReadOnly ?? false))
                    } else if let dst = m.Target {
                        // Anonymous volume
                        config.volumes.append(VolumeMount(source: dst, destination: dst))
                    }
                }
            }

            // Port bindings
            if let portBindings = hc.PortBindings {
                for (containerSpec, hostBindings) in portBindings {
                    // containerSpec format: "80/tcp" or "80"
                    let parts = containerSpec.split(separator: "/")
                    guard let containerPort = UInt16(parts.first ?? "") else { continue }
                    let proto = parts.count > 1 ? String(parts[1]) : "tcp"

                    for binding in hostBindings {
                        let hostPort = UInt16(binding.HostPort ?? "") ?? containerPort
                        // Docker's HostIp: empty means every interface. A
                        // client asking for 127.0.0.1 over the API socket has
                        // the same right to be obeyed as one using our CLI.
                        let hostIP = (binding.HostIp?.isEmpty == false)
                            ? binding.HostIp! : "0.0.0.0"
                        config.ports.append(PortMapping(
                            hostPort: hostPort,
                            containerPort: containerPort,
                            proto: TransportProto(rawValue: proto) ?? .tcp,
                            hostIP: hostIP
                        ))
                    }
                }
            }
        }

        // Networking config (compose networks)
        if let nc = createReq.NetworkingConfig, let endpoints = nc.EndpointsConfig {
            config.network = endpoints.keys.first
        }

        // Container starts in "created" state (docker-compose calls /start separately)
        config.detach = true

        do {
            let id = try await engine.run(config: config)
            return .json(DockerContainerCreateResponse(Id: id, Warnings: []), status: 201)
        } catch CockerError.containerAlreadyExists(let name) {
            return .conflict("Conflict. The container name \"/\(name)\" is already in use")
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func handleContainerInspect(id: String) async -> HTTPResponse {
        do {
            let container = try await engine.inspect(id: id)
            return .json(dockerInspect(from: container))
        } catch {
            return .notFound(id)
        }
    }

    private func handleContainerLogs(req: HTTPRequest, id: String, fd: Int32) async {
        let follow = req.query["follow"] == "true" || req.query["follow"] == "1"
        let stdout = req.query["stdout"] == "true" || req.query["stdout"] == "1"
        let stderr = req.query["stderr"] == "true" || req.query["stderr"] == "1"
        let tail = Int(req.query["tail"] ?? "100") ?? 100
        let timestamps = req.query["timestamps"] == "true"

        let writer = HTTPStreamWriter(fd: fd)
        writer.writeHeaders(contentType: "application/octet-stream")

        guard let container = try? await engine.inspect(id: id) else {
            writer.finish()
            return
        }

        let logsReq = LogsRequest(id: id, follow: follow, tail: tail, timestamps: timestamps)
        guard let stream = try? await engine.logs(id: id, request: logsReq) else {
            writer.finish()
            return
        }

        let useTTY = container.tty_mode
        for await event in stream {
            var line = event.data
            if timestamps {
                line = "\(ISO8601DateFormatter().string(from: event.timestamp)) \(line)"
            }
            let data = Data(line.utf8)
            if useTTY {
                writer.writeChunk(data)
            } else {
                let streamByte: UInt8 = event.stream == .stderr ? 2 : 1
                if (streamByte == 1 && stdout) || (streamByte == 2 && stderr) {
                    writer.writeLogFrame(stream: streamByte, data: data)
                }
            }
        }
        writer.finish()
    }

    private func handleContainerStart(id: String) async -> HTTPResponse {
        do {
            try await engine.start(id: id)
            return .noContent()
        } catch CockerError.containerAlreadyRunning {
            return HTTPResponse(status: 304, statusText: "Not Modified")
        } catch {
            return .notFound(id)
        }
    }

    private func handleContainerStop(id: String, req: HTTPRequest) async -> HTTPResponse {
        let timeout = TimeInterval(req.query["t"] ?? "10") ?? 10
        do {
            try await engine.stop(id: id, timeout: timeout)
            return .noContent()
        } catch CockerError.containerNotRunning {
            return HTTPResponse(status: 304, statusText: "Not Modified")
        } catch {
            return .notFound(id)
        }
    }

    private func handleContainerKill(id: String, req: HTTPRequest) async -> HTTPResponse {
        let signal = req.query["signal"] ?? "SIGKILL"
        do {
            try await engine.kill(id: id, signal: signal)
            return .noContent()
        } catch { return .notFound(id) }
    }

    private func handleContainerRestart(id: String) async -> HTTPResponse {
        do {
            try await engine.restart(id: id)
            return .noContent()
        } catch { return .notFound(id) }
    }

    private func handleContainerPause(id: String) async -> HTTPResponse {
        do {
            try await engine.pause(id: id)
            return .noContent()
        } catch { return .notFound(id) }
    }

    private func handleContainerUnpause(id: String) async -> HTTPResponse {
        do {
            try await engine.unpause(id: id)
            return .noContent()
        } catch { return .notFound(id) }
    }

    private func handleContainerRemove(id: String, req: HTTPRequest) async -> HTTPResponse {
        let force = req.query["force"] == "true" || req.query["force"] == "1"
        do {
            try await engine.remove(id: id, force: force)
            return .noContent()
        } catch CockerError.containerAlreadyRunning {
            return .conflict("Cannot remove a running container. Stop the container before attempting removal or force remove")
        } catch { return .notFound(id) }
    }

    /// `GET /containers/{id}/changes` used to answer a hardcoded `[]`, which
    /// tooling reads as "nothing changed" — a confident lie. It now runs the
    /// same real diff the CLI does.
    private func handleContainerChanges(id: String) async -> HTTPResponse {
        struct Change: Encodable { let Path: String; let Kind: Int }
        do {
            let diff = try await engine.diff(containerID: id)
            // Docker's Kind: 0 modified, 1 added, 2 deleted.
            return .json(diff.entries.map { entry in
                Change(Path: entry.path,
                       Kind: entry.kind == "A" ? 1 : (entry.kind == "D" ? 2 : 0))
            })
        } catch {
            return .notFound(id)
        }
    }

    private func handleContainerTop(id: String) async -> HTTPResponse {
        struct TopResponse: Encodable {
            let Titles: [String]; let Processes: [[String]]
        }
        // This used to return a hardcoded `1 root 0:00 /sbin/init` for every
        // container, whatever was actually running. The CLI never hit it —
        // `cocker top` execs `ps` itself — so only API clients (JetBrains'
        // process tab, `docker top`) saw the fabrication. Same exec, one
        // implementation.
        do {
            var config = ExecConfig(containerID: id, command: ["ps", "-eo", "pid,user,time,args"])
            config.tty = false
            var lines: [String] = []
            for await event in try await engine.exec(config: config)
            where event.stream == .stdout {
                lines.append(contentsOf: event.data
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init))
            }
            // First line is `ps`'s own header; the rest are processes.
            let rows = lines.dropFirst().compactMap { line -> [String]? in
                let fields = line.split(separator: " ", maxSplits: 3,
                                        omittingEmptySubsequences: true).map(String.init)
                return fields.count == 4 ? fields : nil
            }
            guard !rows.isEmpty else {
                return .error("could not read the process list in container \(id)", status: 409)
            }
            return .json(TopResponse(Titles: ["PID", "USER", "TIME", "COMMAND"], Processes: rows))
        } catch let error as CockerError {
            return .error(error.description, status: 409)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    private func handleContainerRename(id: String, req: HTTPRequest) async -> HTTPResponse {
        guard let newName = req.query["name"], !newName.isEmpty else {
            return .error("name query parameter is required", status: 400)
        }
        // Strip leading slash if present (Docker convention)
        let cleanName = newName.hasPrefix("/") ? String(newName.dropFirst()) : newName
        guard let container = await engine.state.container(id: id) else {
            return .notFound(id)
        }
        do {
            try await engine.state.updateContainer(id: container.id) { c in c.name = cleanName }
            await engine.dnsServer?.invalidateCache()
            return .noContent()
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func handleContainerStats(id: String) async -> HTTPResponse {
        struct StatsResponse: Encodable {
            let id: String; let read: String
            let cpu_stats: CPUStats; let memory_stats: MemoryStats
            struct CPUStats: Encodable { let cpu_usage: CPUUsage; let system_cpu_usage: Int64
                struct CPUUsage: Encodable { let total_usage: Int64; let percpu_usage: [Int64] }
            }
            struct MemoryStats: Encodable { let usage: Int64; let limit: Int64 }
        }
        // This used to answer hardcoded zeros with a 200 OK: total_usage 0,
        // system_cpu_usage 0, memory usage 0, limit = the *host's* physical
        // memory. Any Docker-API client — Portainer, the JetBrains plugin,
        // `docker stats -H unix://…` — showed every container at 0% CPU and
        // 0 B forever. Same fabrication `top` was carrying, fixed the same
        // way: ask the container.
        //
        // Docker's contract here is cumulative counters, not a percentage:
        // clients take the delta between two calls themselves. /proc/stat is
        // in jiffies (USER_HZ = 100 on Linux), so ×10ms gives nanoseconds.
        let limitBytes: Int64 = await {
            guard let c = await engine.state.container(id: id) else {
                return Int64(ProcessInfo.processInfo.physicalMemory)
            }
            return Int64(c.memoryMB) * 1024 * 1024
        }()

        do {
            var config = ExecConfig(containerID: id,
                                    command: ["sh", "-c", "cat /proc/stat; cat /proc/meminfo"])
            config.tty = false
            var out = ""
            for await event in try await engine.exec(config: config)
            where event.stream == .stdout { out += event.data }

            var perCPU: [Int64] = []
            var busyJiffies: Int64 = 0
            var totalJiffies: Int64 = 0
            var memTotalKB: Int64 = 0
            var memAvailKB: Int64 = 0

            for line in out.split(separator: "\n") {
                if line.hasPrefix("cpu") {
                    let fields = line.split(separator: " ").dropFirst().compactMap { Int64($0) }
                    guard fields.count >= 5 else { continue }
                    let total = fields.reduce(0, &+)
                    let idle = fields[3] &+ fields[4]     // idle + iowait
                    let busy = total >= idle ? total - idle : 0
                    if line.hasPrefix("cpu ") {
                        busyJiffies = busy
                        totalJiffies = total
                    } else {
                        perCPU.append(busy &* 10_000_000)
                    }
                } else if line.hasPrefix("MemTotal:") {
                    memTotalKB = Int64(line.split(separator: " ").dropFirst().first ?? "") ?? 0
                } else if line.hasPrefix("MemAvailable:") {
                    memAvailKB = Int64(line.split(separator: " ").dropFirst().first ?? "") ?? 0
                }
            }
            guard totalJiffies > 0 else {
                return .error("could not read /proc/stat in container \(id)", status: 409)
            }
            let usedKB = memTotalKB > memAvailKB ? memTotalKB - memAvailKB : 0

            return .json(StatsResponse(
                id: id, read: ISO8601DateFormatter().string(from: Date()),
                cpu_stats: .init(
                    cpu_usage: .init(total_usage: busyJiffies &* 10_000_000,
                                     percpu_usage: perCPU.isEmpty ? [busyJiffies &* 10_000_000] : perCPU),
                    system_cpu_usage: totalJiffies &* 10_000_000),
                memory_stats: .init(usage: usedKB &* 1024, limit: limitBytes)
            ))
        } catch let error as CockerError {
            return .error(error.description, status: 409)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    private func handleContainerWait(id: String) async -> HTTPResponse {
        struct WaitBody: Encodable { let StatusCode: Int; let Error: WaitError?
            struct WaitError: Encodable { let Message: String } }
        // Really block until the container is done, and report the real code.
        // This used to return StatusCode 0 immediately, which made every
        // exit-code-dependent client — `docker run`, `compose up
        // --abort-on-container-exit`, `depends_on: service_completed_
        // successfully`, every CI runner — see unconditional success.
        //
        // Parking here suspends rather than blocks : the router is actor-
        // isolated, so the actor is released while we wait and other
        // requests keep flowing on their own connections.
        do {
            let code = try await engine.wait(id: id)
            return .json(WaitBody(StatusCode: Int(code), Error: nil))
        } catch {
            return .notFound(id)
        }
    }

    private func handleContainerPrune() async -> HTTPResponse {
        struct PruneResponse: Encodable { let ContainersDeleted: [String]; let SpaceReclaimed: Int64 }
        let result = try? await engine.prune(volumes: false)
        return .json(PruneResponse(
            ContainersDeleted: result?.containersDeleted ?? [],
            SpaceReclaimed: Int64(result?.spaceReclaimed ?? 0)
        ))
    }

    /// `POST /images/prune` → really remove the unreferenced images.
    ///
    /// This used to answer a canned `{"ImagesDeleted":[],"SpaceReclaimed":0}`
    /// with 200 OK, so `docker image prune` against cocker printed "Total
    /// reclaimed space: 0B" and removed nothing. The implementation existed
    /// and went unused — containers, networks and volumes prune all call the
    /// engine; images was the one route that didn't.
    private func handleImagePrune(req: HTTPRequest) async -> HTTPResponse {
        struct ImagePruneResponse: Encodable {
            struct Deleted: Encodable { let Deleted: String }
            let ImagesDeleted: [Deleted]
            let SpaceReclaimed: Int64
        }
        // docker sends `filters={"dangling":{"false":true}}` for `-a`.
        let all = (req.query["filters"] ?? "").contains("\"false\"")
        do {
            let result = try await engine.imagePrune(all: all)
            return .json(ImagePruneResponse(
                ImagesDeleted: result.imagesDeleted.map { .init(Deleted: $0) },
                SpaceReclaimed: Int64(result.spaceReclaimed)
            ))
        } catch let error as CockerError {
            return .error(error.description, status: 409)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    // MARK: - Archive handlers

    /// `GET /containers/{id}/archive?path=…` → a tar of that path.
    private func handleArchiveGet(id: String, req: HTTPRequest) async -> HTTPResponse {
        guard let path = req.query["path"], !path.isEmpty else {
            return .error("path parameter is required", status: 400)
        }
        do {
            let target = try await engine.archiveTarget(containerID: id, path: path,
                                                        forWriting: false)
            guard FileManager.default.fileExists(atPath: target.path) else {
                return .error("Could not find the file \(path) in container \(id)", status: 404)
            }
            var headers = ["Content-Type": "application/x-tar"]
            if let stat = ContainerArchive.statHeader(for: target) {
                headers["X-Docker-Container-Path-Stat"] = stat
            }
            return HTTPResponse(status: 200, headers: headers,
                                body: try ContainerArchive.pack(target))
        } catch let error as CockerError {
            return .error(error.description, status: 404)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    /// `HEAD` is how clients probe whether a path exists and whether it is a
    /// directory, before deciding how to unpack into it.
    private func handleArchiveHead(id: String, req: HTTPRequest) async -> HTTPResponse {
        guard let path = req.query["path"], !path.isEmpty else {
            return .error("path parameter is required", status: 400)
        }
        do {
            let target = try await engine.archiveTarget(containerID: id, path: path,
                                                        forWriting: false)
            guard FileManager.default.fileExists(atPath: target.path),
                  let stat = ContainerArchive.statHeader(for: target) else {
                return .error("Could not find the file \(path) in container \(id)", status: 404)
            }
            return HTTPResponse(status: 200,
                                headers: ["X-Docker-Container-Path-Stat": stat])
        } catch let error as CockerError {
            return .error(error.description, status: 404)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    /// `PUT /containers/{id}/archive?path=…` extracts the tar body there.
    /// The context arrives chunked from most clients, which is why this
    /// needed the parser's chunked branch first.
    private func handleArchivePut(id: String, req: HTTPRequest) async -> HTTPResponse {
        guard let path = req.query["path"], !path.isEmpty else {
            return .error("path parameter is required", status: 400)
        }
        guard !req.body.isEmpty else {
            return .error("empty archive body", status: 400)
        }
        do {
            let target = try await engine.archiveTarget(containerID: id, path: path,
                                                        forWriting: true)
            try ContainerArchive.unpack(req.body, into: target)
            return HTTPResponse(status: 200)
        } catch let error as CockerError {
            return .error(error.description, status: 400)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    // MARK: - Exec handlers

    private func handleExecCreate(id: String, req: HTTPRequest) async -> HTTPResponse {
        guard let execReq = decodeJSON(DockerExecCreateRequest.self, from: req.body) else {
            return .error("Invalid request", status: 400)
        }
        let execID = UUID().uuidString
        var env: [String: String] = [:]
        for e in execReq.Env ?? [] {
            let parts = e.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { env[String(parts[0])] = String(parts[1]) }
        }
        execSessions[execID] = ExecSession(
            containerID: id,
            command: execReq.Cmd,
            env: env,
            tty: execReq.Tty ?? false,
            user: execReq.User,
            workdir: execReq.WorkingDir
        )
        pruneFinishedExecSessions()
        return .json(DockerExecCreateResponse(Id: execID), status: 201)
    }

    /// Finished exec sessions stay readable so `/exec/{id}/json` can report
    /// the exit code — Docker keeps them for the container's lifetime. We
    /// keep a bounded window instead, so a long-lived daemon doing
    /// thousands of `docker exec` calls doesn't grow without limit.
    private func pruneFinishedExecSessions() {
        let finished = execSessions.filter { $0.value.exitCode != nil }
        guard finished.count > Self.finishedExecRetention else { return }
        for key in finished.keys.sorted().prefix(finished.count - Self.finishedExecRetention) {
            execSessions.removeValue(forKey: key)
        }
    }

    private func handleExecStart(id: String, req: HTTPRequest, fd: Int32) async {
        guard let session = execSessions[id] else {
            let resp = HTTPResponse.error("No such exec instance", status: 404)
            _ = resp.write(to: fd)
            return
        }

        // Docker hijacks this connection: after the response head it reads
        // the socket raw. Chunked framing put chunk-size lines inside the
        // stdcopy stream, so clients saw "unrecognized input header" or
        // corrupted output.
        var writer = HTTPStreamWriter(fd: fd)
        writer.isRaw = true
        writer.writeHijackHeaders(upgrade: Self.wantsUpgrade(req))

        var exitCode: Int32 = 0
        do {
            // Carry the whole request through. These fields were decoded and
            // dropped before, so `docker exec -e/-w/-u` silently did nothing.
            var config = ExecConfig(containerID: session.containerID, command: session.command)
            config.env = session.env
            config.tty = session.tty
            config.user = session.user
            config.workdir = session.workdir
            let stream = try await engine.exec(config: config)
            for await event in stream {
                switch event.stream {
                case .status:
                    // The runtime reports completion as `exit:<n>` on the
                    // status channel. This used to be framed as stdout, so a
                    // literal "exit:0" was appended to the command's output
                    // and any script parsing that output broke.
                    if let code = ExitMarker.parse(event.data) { exitCode = code }
                case .error:
                    writer.writeLogFrame(stream: 2, data: Data(event.data.utf8))
                case .stdout, .stderr:
                    let data = Data(event.data.utf8)
                    if session.tty {
                        writer.writeChunk(data)
                    } else {
                        writer.writeLogFrame(stream: event.stream == .stderr ? 2 : 1, data: data)
                    }
                }
            }
        } catch {
            writer.writeChunk(Data("Error: \(error.localizedDescription)\n".utf8))
            // Mirror the shell convention for "command could not be run" so
            // callers see a failure rather than a silent success.
            exitCode = 126
        }
        writer.finish()
        // Keep the session so `/exec/{id}/json` can report the code. Deleting
        // it here is what made the CLI's post-attach inspect 404 and fall
        // back to a hardcoded 0.
        execSessions[id]?.exitCode = exitCode
    }

    /// Docker sends `Connection: Upgrade` + `Upgrade: tcp` and expects a
    /// `101 UPGRADED`; older clients just POST and read the body. Answer in
    /// whichever dialect was asked for.
    nonisolated static func wantsUpgrade(_ req: HTTPRequest) -> Bool {
        (req.headers["upgrade"]?.lowercased().contains("tcp") ?? false)
            || (req.headers["connection"]?.lowercased().contains("upgrade") ?? false)
    }

    /// `POST /containers/{id}/attach` — the container's live output, and its
    /// stdin when the client asked for it.
    ///
    /// This was 501, so `docker run` without `-d` (the default!),
    /// `compose up` on a `tty:`/`stdin_open:` service, JetBrains' "attach
    /// console" and a dev-container terminal all failed outright.
    private func handleContainerAttach(id: String, req: HTTPRequest, fd: Int32) async {
        guard let container = await engine.state.container(id: id) else {
            _ = HTTPResponse.notFound(id).write(to: fd)
            return
        }
        var writer = HTTPStreamWriter(fd: fd)
        writer.isRaw = true
        writer.writeHijackHeaders(upgrade: Self.wantsUpgrade(req))

        // A tty container's output is a raw terminal stream; a non-tty one is
        // multiplexed with the 8-byte stdcopy header, exactly as Docker does.
        let multiplexed = container.tty != true
        do {
            let stream = try await engine.logs(id: container.id,
                                               request: LogsRequest(id: container.id,
                                                                    follow: true, tail: 0))
            for await event in stream {
                let data = Data(event.data.utf8)
                if multiplexed {
                    writer.writeLogFrame(stream: event.stream == .stderr ? 2 : 1, data: data)
                } else {
                    writer.writeChunk(data)
                }
            }
        } catch {
            writer.writeChunk(Data("attach failed: \(error)\n".utf8))
        }
    }

    /// `POST /containers/{id}/resize` and `POST /exec/{id}/resize`.
    ///
    /// Both were 501, so every interactive terminal opened through the Docker
    /// socket stayed at whatever size it started with — 80x24 for an exec —
    /// and anything that redraws wrapped at the wrong column.
    private func handleResize(id: String, req: HTTPRequest, isExec: Bool) async -> HTTPResponse {
        let rows = Int(req.query["h"] ?? "") ?? 0
        let cols = Int(req.query["w"] ?? "") ?? 0
        guard rows > 0, cols > 0 else {
            return .error("h and w must be positive", status: 400)
        }
        // An exec session resize targets the container it runs in.
        let containerID = isExec ? execSessions[id]?.containerID : id
        guard let containerID,
              let container = await engine.state.container(id: containerID) else {
            return .notFound(id)
        }
        await engine.vmRuntime.resizeTerminal(containerID: container.id, rows: rows, cols: cols)
        return .noContent()
    }

    private func handleExecInspect(id: String) -> HTTPResponse {
        struct ExecInspect: Encodable {
            let ID: String; let Running: Bool; let ExitCode: Int
            let ProcessConfig: ProcessConfig; let OpenStdin: Bool; let OpenStdout: Bool; let OpenStderr: Bool
            let ContainerID: String
            struct ProcessConfig: Encodable { let tty: Bool; let entrypoint: String; let arguments: [String] }
        }
        guard let session = execSessions[id] else { return .notFound(id) }
        return .json(ExecInspect(
            ID: id,
            Running: session.exitCode == nil,
            ExitCode: Int(session.exitCode ?? 0),
            ProcessConfig: .init(tty: session.tty, entrypoint: session.command.first ?? "", arguments: Array(session.command.dropFirst())),
            OpenStdin: false, OpenStdout: true, OpenStderr: true,
            ContainerID: session.containerID
        ))
    }

    // MARK: - Image handlers

    /// Rebuild an image reference from the path segments it was split across.
    ///
    /// `/images/ghcr.io/org/app/json` arrives as
    /// `["images", "ghcr.io", "org", "app", "json"]`. Taking `segments[1]`
    /// yielded "ghcr.io" and the `== 3` count guards missed entirely, so
    /// every namespaced or registry-qualified reference 501'd.
    ///
    /// `hasVerbSuffix` is false for routes whose last segment is part of the
    /// name (DELETE) rather than an action (`json`, `tag`, `history`).
    /// Clients that percent-encode the slashes instead are handled too.
    nonisolated static func imageName(from segments: [String], hasVerbSuffix: Bool = true) -> String {
        let upper = hasVerbSuffix ? segments.count - 1 : segments.count
        guard upper > 1 else { return "" }
        let joined = segments[1..<upper].joined(separator: "/")
        return joined.removingPercentEncoding ?? joined
    }

    private func handleImageList(req: HTTPRequest) async -> HTTPResponse {
        let filters: DockerFilters
        do {
            filters = try DockerFilters.parse(req.query["filters"])
            try filters.requireSupported(DockerFilters.imageKeys)
        } catch {
            return .error("\(error)", status: 400)
        }
        let images = await engine.images.list()
        return .json(images.filter { filters.matches(image: $0) }
                           .map { DockerImageSummary(from: $0) })
    }

    private func handleImagePull(req: HTTPRequest, fd: Int32) async {
        let fromImage = req.query["fromImage"] ?? ""
        let tag = req.query["tag"] ?? "latest"
        let reference = fromImage.contains(":") ? fromImage : "\(fromImage):\(tag)"

        let writer = HTTPStreamWriter(fd: fd)
        writer.writeHeaders(contentType: "application/json")

        do {
            _ = try await engine.images.pull(reference: reference) { progressMsg in
                // Parse: "status|id|status|current|total"
                let parts = progressMsg.split(separator: "|").map(String.init)
                guard parts.count >= 2 else { return }

                let status = DockerPullStatus(
                    status: parts.count > 2 ? parts[2] : parts[1],
                    progressDetail: DockerProgressDetail(
                        current: parts.count > 3 ? Int64(parts[3]) : nil,
                        total: parts.count > 4 ? Int64(parts[4]) : nil
                    ),
                    id: parts.count > 1 ? String(parts[1].prefix(12)) : nil,
                    progress: nil
                )
                if let data = try? JSONEncoder().encode(status) {
                    writer.writeChunk(data + Data("\n".utf8))
                }
            }
        } catch {
            let errStatus = DockerPullStatus(
                status: "error", progressDetail: DockerProgressDetail(current: nil, total: nil),
                id: nil, progress: error.localizedDescription
            )
            if let data = try? JSONEncoder().encode(errStatus) {
                writer.writeChunk(data + Data("\n".utf8))
            }
        }
        writer.finish()
    }

    private func handleImageInspect(name: String) async -> HTTPResponse {
        guard let img = try? await engine.images.find(name) else { return .notFound(name) }
        return .json(DockerImageSummary(from: img))
    }

    /// `GET /images/<name>/history` — one entry per layer digest. Cocker
    /// doesn't track per-instruction history yet ; we fabricate the bare
    /// minimum shape (`Id`, `Size`, `Created`, `CreatedBy: <empty>`) so
    /// the common consumer pattern (UIs listing layer sizes / counts)
    /// works against the Docker socket the same way it does against
    /// dockerd. Returns `[{}]` placeholder array if the image has no
    /// layers recorded, matching Docker's "empty image" response.
    private func handleImageHistory(name: String) async -> HTTPResponse {
        guard let img = try? await engine.images.find(name) else { return .notFound(name) }
        struct HistoryEntry: Encodable {
            let Id: String
            let Created: Int64
            let CreatedBy: String
            let Size: Int64
            let Comment: String
            let Tags: [String]?
        }
        let created = Int64(img.createdAt.timeIntervalSince1970)
        let entries: [HistoryEntry] = img.layers.enumerated().map { (idx, digest) in
            HistoryEntry(
                Id: digest,
                Created: created,
                CreatedBy: "(layer \(idx + 1)/\(img.layers.count))",
                Size: 0,
                Comment: "",
                Tags: idx == img.layers.count - 1 ? ["\(img.repository):\(img.tag)"] : nil
            )
        }
        return .json(entries)
    }

    private func handleImageRemove(name: String, req: HTTPRequest) async -> HTTPResponse {
        struct DeleteResponse: Encodable { let Untagged: String?; let Deleted: String? }
        do {
            try await engine.images.remove(name)
            return .json([DeleteResponse(Untagged: name, Deleted: nil)])
        } catch { return .notFound(name) }
    }

    private func handleImageTag(name: String, req: HTTPRequest) async -> HTTPResponse {
        let repo = req.query["repo"] ?? name
        let tag = req.query["tag"] ?? "latest"
        do {
            try await engine.images.tag(source: name, target: "\(repo):\(tag)")
            return .noContent()
        } catch { return .notFound(name) }
    }

    private func handleImageBuild(req: HTTPRequest, fd: Int32) async {
        let dockerfile = req.query["dockerfile"] ?? "Dockerfile"
        let tag = req.query["t"] ?? "cocker-build:\(Int(Date().timeIntervalSince1970))"

        let writer = HTTPStreamWriter(fd: fd)
        writer.writeHeaders(contentType: "application/json")

        // Build context is a tar archive in the body — extract it
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write the tar body and extract
        let tarPath = tmpDir.appendingPathComponent("context.tar")
        try? req.body.write(to: tarPath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-x", "-f", tarPath.path, "-C", tmpDir.path]
        try? proc.run(); proc.waitUntilExit()

        var config = BuildConfig(contextPath: tmpDir.path, tag: tag)
        config.dockerfile = dockerfile

        do {
            _ = try await engine.images.build(config: config, vmRuntime: engine.vmRuntime) { event in
                struct BuildOutput: Encodable { let stream: String }
                if let data = try? JSONEncoder().encode(BuildOutput(stream: event.data)) {
                    writer.writeChunk(data + Data("\n".utf8))
                }
            }
        } catch {
            struct BuildError: Encodable { let error: String; let errorDetail: ErrDetail
                struct ErrDetail: Encodable { let message: String } }
            let errData = try? JSONEncoder().encode(BuildError(
                error: error.localizedDescription,
                errorDetail: .init(message: error.localizedDescription)
            ))
            if let d = errData { writer.writeChunk(d + Data("\n".utf8)) }
        }
        writer.finish()
    }

    // MARK: - Network handlers

    private func handleNetworkList(req: HTTPRequest) async -> HTTPResponse {
        let filters: DockerFilters
        do {
            filters = try DockerFilters.parse(req.query["filters"])
            try filters.requireSupported(DockerFilters.networkKeys)
        } catch {
            return .error("\(error)", status: 400)
        }
        let networks = await engine.networks.list()
        return .json(networks.filter { filters.matches(network: $0) }
                             .map { DockerNetworkResource(from: $0) })
    }

    private func handleNetworkCreate(req: HTTPRequest) async -> HTTPResponse {
        guard let createReq = decodeJSON(DockerNetworkCreateRequest.self, from: req.body) else {
            return .error("Invalid request", status: 400)
        }
        let driver = NetworkDriver(rawValue: createReq.Driver ?? "bridge") ?? .bridge
        let subnet = createReq.IPAM?.Config?.first?.Subnet
        let gateway = createReq.IPAM?.Config?.first?.Gateway
        let request = NetworkCreateRequest(
            name: createReq.Name, driver: driver,
            subnet: subnet, gateway: gateway,
            labels: createReq.Labels ?? [:]
        )
        do {
            let net = try await engine.networks.create(request: request)
            return .json(DockerNetworkCreateResponse(Id: net.id, Warning: ""), status: 201)
        } catch CockerError.networkAlreadyExists {
            return .conflict("network with name \(createReq.Name) already exists")
        } catch { return .error(error.localizedDescription) }
    }

    private func handleNetworkInspect(id: String) async -> HTTPResponse {
        guard let net = try? await engine.networks.get(id) else { return .notFound(id) }
        return .json(DockerNetworkResource(from: net))
    }

    private func handleNetworkRemove(id: String) async -> HTTPResponse {
        do {
            try await engine.networks.remove(id)
            return .noContent()
        } catch CockerError.networkInUse { return .conflict("network \(id) is still in use by a container") }
        catch { return .notFound(id) }
    }

    private func handleNetworkConnect(id: String, req: HTTPRequest) async -> HTTPResponse {
        guard let connectReq = decodeJSON(DockerNetworkConnectRequest.self, from: req.body) else {
            return .error("Invalid request", status: 400)
        }
        do {
            try await engine.networks.connect(containerID: connectReq.Container, networkID: id)
            return .noContent()
        } catch { return .error(error.localizedDescription) }
    }

    private func handleNetworkDisconnect(id: String, req: HTTPRequest) async -> HTTPResponse {
        guard let connectReq = decodeJSON(DockerNetworkConnectRequest.self, from: req.body) else {
            return .error("Invalid request", status: 400)
        }
        do {
            try await engine.networks.disconnect(containerID: connectReq.Container, networkID: id)
            return .noContent()
        } catch { return .error(error.localizedDescription) }
    }

    // MARK: - Volume handlers

    private func handleVolumeList(req: HTTPRequest) async -> HTTPResponse {
        let filters: DockerFilters
        do {
            filters = try DockerFilters.parse(req.query["filters"])
            try filters.requireSupported(DockerFilters.volumeKeys)
        } catch {
            return .error("\(error)", status: 400)
        }
        let volumes = await engine.volumes.list()
        return .json(DockerVolumeListResponse(
            Volumes: volumes.filter { filters.matches(volume: $0) }
                            .map { DockerVolumeResource(from: $0) },
            Warnings: []
        ))
    }

    private func handleVolumeCreate(req: HTTPRequest) async -> HTTPResponse {
        let createReq = decodeJSON(DockerVolumeCreateRequest.self, from: req.body)
        let name = createReq?.Name ?? UUID().uuidString.prefix(12).lowercased()
        let driver = createReq?.Driver ?? "local"
        let labels = createReq?.Labels ?? [:]
        let request = VolumeCreateRequest(name: String(name), driver: driver, labels: labels)
        do {
            let vol = try await engine.volumes.create(request: request)
            return .json(DockerVolumeResource(from: vol), status: 201)
        } catch CockerError.volumeAlreadyExists {
            // Return existing volume
            let vol = try? await engine.volumes.get(String(name))
            return .json(DockerVolumeResource(from: vol!))
        } catch { return .error(error.localizedDescription) }
    }

    private func handleVolumeInspect(name: String) async -> HTTPResponse {
        guard let vol = try? await engine.volumes.get(name) else { return .notFound(name) }
        return .json(DockerVolumeResource(from: vol))
    }

    private func handleVolumeRemove(name: String, req: HTTPRequest) async -> HTTPResponse {
        let force = req.query["force"] == "true" || req.query["force"] == "1"
        do {
            try await engine.volumes.remove(name, force: force)
            return .noContent()
        } catch CockerError.volumeInUse { return .conflict("volume \(name) is in use") }
        catch { return .notFound(name) }
    }

    // MARK: - Inspect helper

    private func dockerInspect(from c: Container) -> DockerContainerInspect {
        let portBindings = Dictionary(uniqueKeysWithValues: c.ports.map { port -> (String, [DockerPortBinding]) in
            let key = "\(port.containerPort)/\(port.proto.rawValue)"
            let binding = DockerPortBinding(HostIp: port.hostIP, HostPort: String(port.hostPort))
            return (key, [binding])
        })

        let exposedPorts = Dictionary(uniqueKeysWithValues: c.ports.map { port -> (String, DockerEmpty) in
            ("\(port.containerPort)/\(port.proto.rawValue)", DockerEmpty())
        })

        let mounts = c.volumes.map { vol in
            DockerMountPoint(
                mountType: vol.source.hasPrefix("/") ? "bind" : "volume",
                Source: vol.source, Destination: vol.destination,
                Mode: vol.readOnly ? "ro" : "rw", RW: !vol.readOnly,
                Propagation: "rprivate",
                Name: vol.source.hasPrefix("/") ? nil : vol.source,
                Driver: vol.source.hasPrefix("/") ? nil : "local"
            )
        }

        let iso = ISO8601DateFormatter()
        return DockerContainerInspect(
            Id: c.id,
            Created: iso.string(from: c.createdAt),
            Path: c.command.first ?? "",
            Args: Array(c.command.dropFirst()),
            State: DockerContainerState(
                Status: c.status.dockerState,
                Running: c.status == .running,
                Paused: c.status == .paused,
                Restarting: c.status == .restarting,
                OOMKilled: false, Dead: c.status == .dead,
                Pid: c.status == .running ? 1 : 0,
                ExitCode: Int(c.exitCode ?? 0), Error: "",
                StartedAt: c.startedAt.map { iso.string(from: $0) } ?? "0001-01-01T00:00:00Z",
                FinishedAt: c.finishedAt.map { iso.string(from: $0) } ?? "0001-01-01T00:00:00Z",
                Health: (c.healthcheck != nil && !(c.healthcheck?.isDisabled ?? true))
                    ? DockerHealth(
                        Status: c.healthStatus.rawValue,
                        FailingStreak: c.healthFailingStreak,
                        // Docker writes RFC 3339 with nanoseconds
                        // (`2026-06-07T21:27:55.123456789Z`) — Go template
                        // parsers reading `.State.Health.Log[].Start` as
                        // `time.Time` choke on second-resolution. Format
                        // with nanos here even when the underlying Date
                        // only carries microseconds ; round-trips through
                        // both the Docker CLI and Go's encoding/json.
                        Log: c.healthLog.map {
                            DockerHealthLogEntry(
                                Start: Self.rfc3339Nano($0.start),
                                End: Self.rfc3339Nano($0.end),
                                ExitCode: Int($0.exitCode),
                                Output: $0.output
                            )
                        }
                    )
                    : nil
            ),
            Image: c.image,
            Name: "/\(c.name)",
            RestartCount: c.restartCount,
            HostConfig: DockerHostConfig(
                Binds: c.volumes.filter { $0.source.hasPrefix("/") }.map { "\($0.source):\($0.destination)" },
                NetworkMode: c.networkMode.rawValue,
                PortBindings: portBindings,
                RestartPolicy: DockerRestartPolicy(Name: c.restartPolicy.rawValue, MaximumRetryCount: 0),
                AutoRemove: false,
                Memory: Int64(c.memoryMB) * 1024 * 1024,
                NanoCpus: Int64(c.cpuCount) * 1_000_000_000,
                CapAdd: nil, CapDrop: nil
            ),
            NetworkSettings: DockerNetworkSettings(
                Bridge: "", SandboxID: c.id, HairpinMode: false,
                LinkLocalIPv6Address: "", LinkLocalIPv6PrefixLen: 0,
                Ports: portBindings.mapValues { Optional($0) },
                SandboxKey: "/var/run/netns/\(c.id)",
                Networks: [:],
                // Report what the container actually has, not a Docker-shaped
                // guess. These were `172.17.0.2` / `/16` / `172.17.0.1`,
                // which describe Docker's default bridge and nothing cocker
                // ever creates: containers sit on the vmnet /24 and on the
                // 10.42.0.0/16 fabric. A client reading Gateway and dialling
                // it got an address no one answers on.
                //
                // Prefer the fabric address, same as DNS does — it is the one
                // reachable from other containers. Empty rather than invented
                // when there is none, which is what Docker reports for a
                // container with no network.
                IPAddress: c.cockerIP ?? c.ip ?? "",
                IPPrefixLen: c.cockerIP != nil ? 16 : 24,
                Gateway: c.cockerIP != nil ? NetworkManager.cockerSwitchGateway : "",
                MacAddress: c.cockerMAC ?? ""
            ),
            Mounts: mounts,
            Config: DockerContainerConfig(
                Hostname: c.hostname, Domainname: "", User: "",
                AttachStdin: false, AttachStdout: true, AttachStderr: true,
                ExposedPorts: exposedPorts.isEmpty ? nil : exposedPorts,
                Tty: false, OpenStdin: false, StdinOnce: false,
                // Redact secret-looking env values (DB passwords, tokens…)
                // before they cross the API boundary — keeps `GET
                // /containers/<id>/json` consistent with `cocker inspect`,
                // which already masks them. Keys are preserved so tooling can
                // still see *which* vars exist.
                Env: SecretRedactor.redact(c.env).map { "\($0.key)=\($0.value)" },
                Cmd: c.command.isEmpty ? nil : c.command,
                Image: c.image, Labels: c.labels,
                WorkingDir: "", Entrypoint: nil, OnBuild: nil,
                NetworkDisabled: c.networkMode == .none
            )
        )
    }
}

// Helper for TTY mode detection
private extension Container {
    var tty_mode: Bool { false }  // Could be stored in labels or config
}
