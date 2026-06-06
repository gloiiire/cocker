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

    // In-flight exec sessions: execID -> container ID + command
    private var execSessions: [String: ExecSession] = [:]

    struct ExecSession {
        let containerID: String
        let command: [String]
        let env: [String: String]
        let tty: Bool
    }

    init(socketPath: String, engine: ContainerEngine) {
        self.socketPath = socketPath
        self.engine = engine
    }

    func start() async throws {
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CockerError.internalError("docker.sock: socket() failed") }

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
            throw CockerError.internalError("docker.sock: bind() failed")
        }

        guard listen(fd, 256) == 0 else {
            close(fd)
            throw CockerError.internalError("docker.sock: listen() failed")
        }

        chmod(socketPath, 0o666)
        self.serverFD = fd
        self.isRunning = true
        print("[cockerd] Docker API listening on \(socketPath)")
        print("[cockerd] Use: DOCKER_HOST=unix://\(socketPath) docker ps")

        await acceptLoop()
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptLoop() async {
        while isRunning {
            let clientFD = await Task.detached(priority: .userInitiated) { [fd = serverFD] in
                accept(fd, nil, nil)
            }.value
            guard clientFD >= 0 else { continue }

            Task { await self.handleConnection(fd: clientFD) }
        }
    }

    private func handleConnection(fd: Int32) async {
        defer { close(fd) }
        // Docker clients may pipeline multiple requests on one connection
        while true {
            guard let request = try? parseHTTPRequest(from: fd), !request.path.isEmpty else { break }
            let keepAlive = request.headers["connection"]?.lowercased() != "close"
            await routeRequest(request, fd: fd)
            if !keepAlive { break }
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

        case ("GET", "images") where segments.count == 3 && segments[2] == "json":
            response = await handleImageInspect(name: segments[1])

        case ("DELETE", "images") where segments.count == 2:
            response = await handleImageRemove(name: segments[1], req: req)

        case ("POST", "images") where segments.count == 3 && segments[2] == "tag":
            response = await handleImageTag(name: segments[1], req: req)

        case ("POST", "build"):
            await handleImageBuild(req: req, fd: fd)
            response = nil

        case ("GET", "images") where segments.count == 2 && segments[1] == "search":
            response = .json([DockerEmpty]())

        // ── Networks ────────────────────────────────────────────
        case ("GET", "networks"):
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
        case ("GET", "volumes"):
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
            response = HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                    body: Data(#"{"ImagesDeleted":[],"SpaceReclaimed":0}"#.utf8))

        default:
            print("[docker-api] Unhandled: \(method) \(path)")
            response = .error("Not implemented: \(method) \(path)", status: 501)
        }

        if let response {
            let data = response.serialize()
            data.withUnsafeBytes { buf in
                guard let ptr = buf.baseAddress else { return }
                _ = Darwin.write(fd, ptr, buf.count)
            }
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
        var sysinfo = utsname(); uname(&sysinfo)
        let kernel = withUnsafeBytes(of: sysinfo.release) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
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
        let stream = await engine.eventStream()
        for await event in stream {
            let dockerEvent = DockerEvent(
                status: event.data,
                id: "",
                from: "",
                eventType: "container",
                Action: event.data,
                Actor: .init(ID: "", Attributes: [:]),
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

    // MARK: - Container handlers

    private func handleContainerList(req: HTTPRequest) async -> HTTPResponse {
        let all = req.query["all"] == "true" || req.query["all"] == "1"
        let containers = await engine.list(all: all)
        let summaries = containers.map { DockerContainerSummary(from: $0) }
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

                    for binding in (hostBindings ?? []) {
                        let hostPort = UInt16(binding.HostPort ?? "") ?? containerPort
                        config.ports.append(PortMapping(
                            hostPort: hostPort,
                            containerPort: containerPort,
                            proto: TransportProto(rawValue: proto) ?? .tcp
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

    private func handleContainerTop(id: String) async -> HTTPResponse {
        struct TopResponse: Encodable {
            let Titles: [String]; let Processes: [[String]]
        }
        return .json(TopResponse(
            Titles: ["PID", "USER", "TIME", "COMMAND"],
            Processes: [["1", "root", "0:00", "/sbin/init"]]
        ))
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
        return .json(StatsResponse(
            id: id, read: ISO8601DateFormatter().string(from: Date()),
            cpu_stats: .init(cpu_usage: .init(total_usage: 0, percpu_usage: [0]), system_cpu_usage: 0),
            memory_stats: .init(usage: 0, limit: Int64(ProcessInfo.processInfo.physicalMemory))
        ))
    }

    private func handleContainerWait(id: String) async -> HTTPResponse {
        struct WaitResponse: Encodable { let StatusCode: Int; let Error: WaitError?
            struct WaitError: Encodable { let Message: String } }
        return .json(WaitResponse(StatusCode: 0, Error: nil))
    }

    private func handleContainerPrune() async -> HTTPResponse {
        struct PruneResponse: Encodable { let ContainersDeleted: [String]; let SpaceReclaimed: Int64 }
        let result = try? await engine.prune(volumes: false)
        return .json(PruneResponse(
            ContainersDeleted: result?.containersDeleted ?? [],
            SpaceReclaimed: Int64(result?.spaceReclaimed ?? 0)
        ))
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
            tty: execReq.Tty ?? false
        )
        return .json(DockerExecCreateResponse(Id: execID), status: 201)
    }

    private func handleExecStart(id: String, req: HTTPRequest, fd: Int32) async {
        guard let session = execSessions[id] else {
            let resp = HTTPResponse.error("No such exec instance", status: 404)
            let data = resp.serialize()
            data.withUnsafeBytes { buf in _ = Darwin.write(fd, buf.baseAddress!, buf.count) }
            return
        }

        let writer = HTTPStreamWriter(fd: fd)
        writer.writeHeaders(contentType: "application/octet-stream")

        do {
            let config = ExecConfig(containerID: session.containerID, command: session.command)
            let stream = try await engine.exec(config: config)
            for await event in stream {
                let data = Data(event.data.utf8)
                if session.tty {
                    writer.writeChunk(data)
                } else {
                    writer.writeLogFrame(stream: event.stream == .stderr ? 2 : 1, data: data)
                }
            }
        } catch {
            writer.writeChunk(Data("Error: \(error.localizedDescription)\n".utf8))
        }
        writer.finish()
        execSessions.removeValue(forKey: id)
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
            ID: id, Running: false, ExitCode: 0,
            ProcessConfig: .init(tty: session.tty, entrypoint: session.command.first ?? "", arguments: Array(session.command.dropFirst())),
            OpenStdin: false, OpenStdout: true, OpenStderr: true,
            ContainerID: session.containerID
        ))
    }

    // MARK: - Image handlers

    private func handleImageList(req: HTTPRequest) async -> HTTPResponse {
        let images = await engine.images.list()
        return .json(images.map { DockerImageSummary(from: $0) })
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
        let networks = await engine.networks.list()
        return .json(networks.map { DockerNetworkResource(from: $0) })
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
        let volumes = await engine.volumes.list()
        return .json(DockerVolumeListResponse(
            Volumes: volumes.map { DockerVolumeResource(from: $0) },
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
            let binding = DockerPortBinding(HostIp: "0.0.0.0", HostPort: String(port.hostPort))
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
                FinishedAt: c.finishedAt.map { iso.string(from: $0) } ?? "0001-01-01T00:00:00Z"
            ),
            Image: c.image,
            Name: "/\(c.name)",
            RestartCount: 0,
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
                IPAddress: c.ip ?? "172.17.0.2",
                IPPrefixLen: 16, Gateway: "172.17.0.1", MacAddress: ""
            ),
            Mounts: mounts,
            Config: DockerContainerConfig(
                Hostname: c.hostname, Domainname: "", User: "",
                AttachStdin: false, AttachStdout: true, AttachStderr: true,
                ExposedPorts: exposedPorts.isEmpty ? nil : exposedPorts,
                Tty: false, OpenStdin: false, StdinOnce: false,
                Env: c.env.map { "\($0.key)=\($0.value)" },
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
