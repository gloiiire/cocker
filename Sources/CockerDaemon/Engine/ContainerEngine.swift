import Foundation
import CockerCore

// Main container engine — orchestrates images, VMs, networks, volumes

@MainActor
final class ContainerEngine {
    let images: ImageManager
    let networks: NetworkManager
    let volumes: VolumeManager
    let state: StateStore
    let vmRuntime: VMRuntime
    let portForwarder: PortForwarder
    let l2Switch: any L2Switching
    private let rootDir: URL
    var dnsServer: DNSServer?  // injecté par main après init

    // Event stream
    private var eventContinuations: [UUID: AsyncStream<StreamEvent>.Continuation] = [:]

    init(
        rootDir: URL,
        portForwarder: PortForwarder,
        l2Switch: any L2Switching = L2Switch()
    ) async throws {
        self.rootDir = rootDir
        self.state = try StateStore(rootDir: rootDir)
        self.images = try ImageManager(rootDir: rootDir)
        self.networks = try await NetworkManager(store: state)
        self.volumes = VolumeManager(store: state, rootDir: rootDir)
        self.l2Switch = l2Switch
        self.vmRuntime = try VMRuntime(rootDir: rootDir, l2Switch: self.l2Switch)
        self.portForwarder = portForwarder
    }

    // MARK: - Container lifecycle

    func run(config: RunConfig) async throws -> String {
        fputs("[eng] run() image=\(config.image)\n", stderr); fflush(stderr)
        // Pull image if not present
        if !(await images.exists(config.image)) {
            fputs("[eng] image not present, pulling\n", stderr); fflush(stderr)
            _ = try await images.pull(reference: config.image) { _ in }
        }
        fputs("[eng] image exists\n", stderr); fflush(stderr)

        // Generate container ID and name (12 chars lowercase, matches state lookup)
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        fputs("[eng] id=\(id)\n", stderr); fflush(stderr)
        let generatedName = await state.generateName()
        let name = config.name ?? generatedName
        fputs("[eng] name=\(name)\n", stderr); fflush(stderr)

        guard !(await state.nameExists(name)) else {
            throw CockerError.containerAlreadyExists(name)
        }
        fputs("[eng] name unique check OK\n", stderr); fflush(stderr)

        // Resolve ports
        let ports = config.ports

        // Resolve volumes from other containers
        var resolvedVolumes = config.volumes
        for sourceID in config.volumesFrom {
            if let sourceContainer = await state.container(id: sourceID) {
                resolvedVolumes.append(contentsOf: sourceContainer.volumes)
            }
        }

        // Resolve image defaults (CMD, ENV, WORKDIR…) si l'user n'a pas overridé.
        // Sinon `cocker run my-built-image` ignore le CMD du Dockerfile.
        let imageInfo = try? await images.find(config.image)
        var resolvedCommand = config.command
        if resolvedCommand.isEmpty {
            if let entrypoint = imageInfo?.entrypoint, !entrypoint.isEmpty {
                resolvedCommand = entrypoint + (imageInfo?.cmd ?? [])
            } else if let cmd = imageInfo?.cmd, !cmd.isEmpty {
                resolvedCommand = cmd
            }
        }

        var resolvedEnv = config.env
        for entry in imageInfo?.env ?? [] {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, resolvedEnv[parts[0]] == nil {
                resolvedEnv[parts[0]] = parts[1]
            }
        }

        let resolvedWorkdir = config.workdir ?? imageInfo?.workdir

        // Merge labels image + user
        var resolvedLabels = imageInfo?.labels ?? [:]
        for (k, v) in config.labels { resolvedLabels[k] = v }

        // Create container record
        var container = Container(
            id: id,
            name: name,
            image: config.image,
            command: resolvedCommand,
            ports: ports,
            volumes: resolvedVolumes,
            env: resolvedEnv,
            labels: resolvedLabels,
            networkMode: config.networkMode,
            networkName: config.network,
            cpuCount: config.cpuCount,
            memoryMB: config.memoryMB,
            hostname: config.hostname ?? String(id.prefix(12)),
            restartPolicy: config.restartPolicy
        )
        if let workdir = resolvedWorkdir { container.env["WORKDIR"] = workdir }

        fputs("[eng] container struct created\n", stderr); fflush(stderr)
        // Allocate IP
        container.ip = await networks.allocateIP(for: id)
        fputs("[eng] ipv4=\(container.ip ?? "?")\n", stderr); fflush(stderr)
        container.ipv6 = await networks.allocateIPv6(for: id)
        fputs("[eng] ipv6=\(container.ipv6 ?? "?")\n", stderr); fflush(stderr)
        // Allocate IP+MAC on the cocker L2 switch (inter-container fabric)
        let (cIP, cMAC) = await networks.allocateCockerIPAndMAC(for: id)
        container.cockerIP = cIP
        container.cockerMAC = cMAC
        fputs("[eng] cocker switch ip=\(cIP) mac=\(cMAC)\n", stderr); fflush(stderr)
        try await state.store(container: container)
        fputs("[eng] state stored\n", stderr); fflush(stderr)
        emitEvent("container", action: "create", id: id)
        fputs("[eng] event emitted\n", stderr); fflush(stderr)

        // Start VM
        // Overlay rootfs : clone le rootfs de l'image vers un dossier propre
        // au container via APFS clonefile. Garantit l'isolation fs entre
        // containers de la même image (sinon ils écrivent dans le même rootfs
        // partagé — bug du PoC initial visible sur compose db+web).
        fputs("[eng] cloning rootfs (APFS copy-on-write)\n", stderr); fflush(stderr)
        // S'assure que l'image a un rootfs extrait (pull-on-demand)
        _ = try await images.rootfsPath(for: config.image)
        let rootfsPath = try await images.cloneRootfs(for: config.image, containerID: id)
        fputs("[eng] container rootfs=\(rootfsPath.path)\n", stderr); fflush(stderr)
        fputs("[eng] calling vmRuntime.start\n", stderr); fflush(stderr)
        try await vmRuntime.start(container: container, rootfsPath: rootfsPath)
        fputs("[eng] vmRuntime.start returned\n", stderr); fflush(stderr)

        // Update status
        try await state.updateContainer(id: id) { c in
            c.status = .running
            c.startedAt = Date()
        }

        // Connect to network
        if let networkName = config.network {
            try? await networks.connect(containerID: id, networkID: networkName)
        }

        // Démarre le port forwarding TCP (host port → container IP:port)
        // via le PortForwarder Swift. NAT vmnet est outbound-only sans ça.
        //
        // cocker-init écrit l'IP DHCP réelle du container dans /cocker-ip
        // du rootfs (visible via virtiofs côté host). On poll ce fichier
        // pour récupérer l'IP — placeholder "127.0.0.1" si non dispo.
        if !ports.isEmpty {
            fputs("[eng] scheduling IP discovery task for ports: \(ports.map { $0.description }.joined(separator: ","))\n", stderr); fflush(stderr)
            Task { [rootfsPath, ports, id] in
                fputs("[eng] IP discovery task started for \(id)\n", stderr); fflush(stderr)
                let ipFile = rootfsPath.appendingPathComponent("cocker-ip")
                fputs("[eng] polling \(ipFile.path)\n", stderr); fflush(stderr)
                var realIP: String? = nil
                for attempt in 0..<150 {  // 15s timeout (100ms × 150)
                    if FileManager.default.fileExists(atPath: ipFile.path),
                       let data = try? Data(contentsOf: ipFile),
                       let ip = String(data: data, encoding: .utf8)?
                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                       !ip.isEmpty {
                        realIP = ip
                        fputs("[eng] IP read on attempt \(attempt): \(ip)\n", stderr); fflush(stderr)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let finalIP = realIP ?? "127.0.0.1"
                fputs("[eng] container IP discovered: \(finalIP) (ports: \(ports.map { $0.description }.joined(separator: ", ")))\n", stderr); fflush(stderr)
                // Update state with real IP
                try? await self.state.updateContainer(id: id) { c in c.ip = finalIP }
                fputs("[eng] state updated, calling portForwarder.start\n", stderr); fflush(stderr)
                await self.portForwarder.start(containerID: id, containerIP: finalIP, mappings: ports)
                fputs("[eng] portForwarder.start returned\n", stderr); fflush(stderr)
            }
        }

        // Watch VM for exit (in background)
        Task { [weak self] in
            await self?.watchContainer(id: id, rm: config.rm)
        }

        // Invalide le cache DNS → le nouveau container est immédiatement résolvable
        await dnsServer?.invalidateCache()

        emitEvent("container", action: "start", id: id)
        return id
    }

    func start(id: String) async throws {
        guard let container = await state.container(id: id) else { throw CockerError.containerNotFound(id) }
        guard container.status == .stopped || container.status == .created else {
            throw CockerError.containerAlreadyRunning(id)
        }

        // Réutilise le rootfs cloné du container (créé au run initial).
        // S'il n'existe plus (cleanup, premier start après crash daemon),
        // on le re-clone depuis l'image source.
        let containerRootfs = await images.store.containerRootfsDirectory(containerID: id)
        let rootfsPath: URL
        if FileManager.default.fileExists(atPath: containerRootfs.path) {
            rootfsPath = containerRootfs
        } else {
            _ = try await images.rootfsPath(for: container.image)
            rootfsPath = try await images.cloneRootfs(for: container.image, containerID: id)
        }
        try await vmRuntime.start(container: container, rootfsPath: rootfsPath)
        try await state.updateContainer(id: id) { c in
            c.status = .running
            c.startedAt = Date()
            c.finishedAt = nil
        }
        emitEvent("container", action: "start", id: id)
    }

    func stop(id: String, timeout: TimeInterval = 10) async throws {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }
        guard container.status == .running else {
            throw CockerError.containerNotRunning(id)
        }

        try await vmRuntime.stop(containerID: container.id, timeout: timeout)
        await portForwarder.stop(containerID: container.id)
        try await state.updateContainer(id: id) { c in
            c.status = .stopped
            c.finishedAt = Date()
            c.exitCode = 0
        }
        await dnsServer?.invalidateCache()
        emitEvent("container", action: "stop", id: container.id)
    }

    func kill(id: String, signal: String = "SIGKILL") async throws {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }
        try await vmRuntime.stop(containerID: container.id, timeout: 0)
        await portForwarder.stop(containerID: container.id)
        try await state.updateContainer(id: id) { c in
            c.status = .dead
            c.finishedAt = Date()
            c.exitCode = -1
        }
        emitEvent("container", action: "kill", id: container.id)
    }

    func restart(id: String, timeout: TimeInterval = 10) async throws {
        try await stop(id: id, timeout: timeout)
        try await start(id: id)
        emitEvent("container", action: "restart", id: id)
    }

    func pause(id: String) async throws {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }
        try await vmRuntime.pause(containerID: container.id)
        try await state.updateContainer(id: id) { c in c.status = .paused }
        emitEvent("container", action: "pause", id: container.id)
    }

    func unpause(id: String) async throws {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }
        try await vmRuntime.resume(containerID: container.id)
        try await state.updateContainer(id: id) { c in c.status = .running }
        emitEvent("container", action: "unpause", id: container.id)
    }

    func remove(id: String, force: Bool = false) async throws {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }

        if container.status == .running {
            if force {
                try await kill(id: container.id, signal: "SIGKILL")
            } else {
                throw CockerError.containerAlreadyRunning(container.id)
            }
        }

        await networks.releaseIP(for: container.id)
        await portForwarder.stop(containerID: container.id)
        // Supprime aussi le rootfs cloné du container (libère l'espace
        // disque pris par les modifications post-clonefile).
        try? await images.removeContainerRootfs(containerID: container.id)
        try await state.removeContainer(id: container.id)
        emitEvent("container", action: "destroy", id: container.id)
    }

    // MARK: - Query

    func list(all: Bool = false, filter: [String: String] = [:]) async -> [Container] {
        var containers = await state.allContainers(includeAll: all)

        for (key, value) in filter {
            switch key {
            case "status": containers = containers.filter { $0.status.rawValue == value }
            case "name": containers = containers.filter { $0.name.contains(value) }
            case "image": containers = containers.filter { $0.image.contains(value) }
            case "label":
                let kv = value.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    containers = containers.filter { $0.labels[String(kv[0])] == String(kv[1]) }
                }
            default: break
            }
        }

        return containers
    }

    func inspect(id: String) async throws -> Container {
        guard let c = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }
        return c
    }

    // MARK: - Logs

    func logs(id: String, request: LogsRequest) async throws -> AsyncStream<StreamEvent> {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }

        let historical = await vmRuntime.logs(containerID: container.id, tail: request.tail)
        let follow = request.follow
        let containerID = container.id

        return AsyncStream { continuation in
            Task { @MainActor in
                for event in historical {
                    continuation.yield(event)
                }

                if !follow {
                    continuation.finish()
                    return
                }

                // Tail follow: check every 100ms for new logs (real impl: pipe from VM console)
                var lastCount = historical.count
                while true {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let current = await self.vmRuntime.logs(containerID: containerID, tail: 0)
                    if current.count > lastCount {
                        for event in current.dropFirst(lastCount) {
                            continuation.yield(event)
                        }
                        lastCount = current.count
                    }
                    if !(await self.vmRuntime.isRunning(containerID: containerID)) {
                        break
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Exec

    func exec(config: ExecConfig) async throws -> AsyncStream<StreamEvent> {
        guard let container = await state.container(id: config.containerID) else {
            throw CockerError.containerNotFound(config.containerID)
        }
        guard container.status == .running else {
            throw CockerError.containerNotRunning(config.containerID)
        }
        return try await vmRuntime.exec(containerID: container.id, command: config.command, env: config.env)
    }

    // MARK: - System info

    func info() async -> InfoResponse {
        let allContainers = await state.allContainers(includeAll: true)
        let runningCount = allContainers.filter { $0.status == .running }.count
        let allImages = await images.list()
        let allNetworks = await networks.list()
        let allVolumes = await volumes.list()

        let memTotal = ProcessInfo.processInfo.physicalMemory
        let cpuCount = ProcessInfo.processInfo.processorCount

        var kernel = "unknown"
        var sysinfo = utsname()
        if uname(&sysinfo) == 0 {
            kernel = withUnsafeBytes(of: sysinfo.release) { ptr in
                String(cString: ptr.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
        }

        return InfoResponse(
            containers: allContainers.count,
            containersRunning: runningCount,
            images: allImages.count,
            volumes: allVolumes.count,
            networks: allNetworks.count,
            kernelVersion: kernel,
            architecture: "arm64",
            cpus: cpuCount,
            totalMemory: memTotal,
            cockerRootDir: rootDir.path,
            socketPath: IPCClient.defaultSocketPath
        )
    }

    // MARK: - Prune

    func prune(volumes: Bool = false) async throws -> PruneResponse {
        let deletedContainers = try await state.pruneStopped()

        var deletedImages: [String] = []
        var deletedVolumes: [String] = []
        var spaceReclaimed: UInt64 = 0

        if volumes {
            let (names, bytes) = try await self.volumes.pruneUnused()
            deletedVolumes = names
            spaceReclaimed += bytes
        }

        return PruneResponse(
            containersDeleted: deletedContainers,
            imagesDeleted: deletedImages,
            volumesDeleted: deletedVolumes,
            spaceReclaimed: spaceReclaimed
        )
    }

    // MARK: - Event system

    func eventStream() -> AsyncStream<StreamEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { @MainActor in
                self.eventContinuations[id] = continuation
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in
                        self.eventContinuations.removeValue(forKey: id)
                    }
                }
            }
        }
    }

    private func emitEvent(_ type: String, action: String, id: String) {
        let event = StreamEvent(stream: .status, data: "\(type) \(action) \(id)")
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Container watcher

    private func watchContainer(id: String, rm: Bool) async {
        // Poll VM state
        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !(await vmRuntime.isRunning(containerID: id)) {
                guard let container = await state.container(id: id) else { break }

                // Record exit
                try? await state.updateContainer(id: id) { c in
                    c.finishedAt = Date()
                    if c.exitCode == nil { c.exitCode = 0 }
                }

                // Check restart policy
                let exitCode = container.exitCode ?? 0
                var shouldRestart = false
                switch container.restartPolicy {
                case .always:
                    shouldRestart = true
                case .unlessStopped:
                    // Restart unless manually stopped (status == .stopped means user stopped it)
                    shouldRestart = container.status != .stopped
                case .onFailure:
                    shouldRestart = exitCode != 0
                case .no:
                    shouldRestart = false
                }

                if shouldRestart {
                    try? await state.updateContainer(id: id) { c in
                        c.status = .restarting
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s backoff
                    if let c = await state.container(id: id) {
                        let rootfsPath = try? await images.rootfsPath(for: c.image)
                        if let rootfsPath {
                            try? await vmRuntime.start(container: c, rootfsPath: rootfsPath)
                            try? await state.updateContainer(id: id) { c in
                                c.status = .running
                                c.startedAt = Date()
                                c.exitCode = nil
                            }
                        }
                    }
                    continue  // Keep watching
                }

                // Container truly stopped
                try? await state.updateContainer(id: id) { c in
                    c.status = .stopped
                }
                if rm {
                    try? await state.removeContainer(id: id)
                }
                break
            }
        }
    }
}

