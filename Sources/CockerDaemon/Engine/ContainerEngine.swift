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
    private let rootDir: URL
    var dnsServer: DNSServer?  // injecté par main après init

    // Event stream
    private var eventContinuations: [UUID: AsyncStream<StreamEvent>.Continuation] = [:]

    init(rootDir: URL) async throws {
        self.rootDir = rootDir
        self.state = try StateStore(rootDir: rootDir)
        self.images = try ImageManager(rootDir: rootDir)
        self.networks = try await NetworkManager(store: state)
        self.volumes = VolumeManager(store: state, rootDir: rootDir)
        self.vmRuntime = try VMRuntime(rootDir: rootDir)
    }

    // MARK: - Container lifecycle

    func run(config: RunConfig) async throws -> String {
        // Pull image if not present
        if !(await images.exists(config.image)) {
            _ = try await images.pull(reference: config.image) { _ in }
        }

        // Generate container ID and name
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(64))
        let generatedName = await state.generateName()
        let name = config.name ?? generatedName

        guard !(await state.nameExists(name)) else {
            throw CockerError.containerAlreadyExists(name)
        }

        // Resolve ports
        let ports = config.ports

        // Resolve volumes from other containers
        var resolvedVolumes = config.volumes
        for sourceID in config.volumesFrom {
            if let sourceContainer = await state.container(id: sourceID) {
                resolvedVolumes.append(contentsOf: sourceContainer.volumes)
            }
        }

        // Create container record
        var container = Container(
            id: id,
            name: name,
            image: config.image,
            command: config.command,
            ports: ports,
            volumes: resolvedVolumes,
            env: config.env,
            labels: config.labels,
            networkMode: config.networkMode,
            networkName: config.network,
            cpuCount: config.cpuCount,
            memoryMB: config.memoryMB,
            hostname: config.hostname ?? String(id.prefix(12)),
            restartPolicy: config.restartPolicy
        )

        // Allocate IP
        container.ip = await networks.allocateIP(for: id)
        container.ipv6 = await networks.allocateIPv6(for: id)
        try await state.store(container: container)
        emitEvent("container", action: "create", id: id)

        // Start VM
        let rootfsPath = try await images.rootfsPath(for: config.image)
        try await vmRuntime.start(container: container, rootfsPath: rootfsPath)

        // Update status
        try await state.updateContainer(id: id) { c in
            c.status = .running
            c.startedAt = Date()
        }

        // Connect to network
        if let networkName = config.network {
            try? await networks.connect(containerID: id, networkID: networkName)
        }

        // Configure port forwarding
        if !ports.isEmpty {
            await networks.configurePortForwarding(containerID: id, ports: ports)
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

        let rootfsPath = try await images.rootfsPath(for: container.image)
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

