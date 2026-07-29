import Foundation

// MARK: - IPC Message types (CLI ↔ daemon over Unix socket)

public enum IPCRequestType: String, Codable, Sendable {
    // Container lifecycle
    case run, start, stop, kill, restart, rm, pause, unpause
    // Container info
    case ps, inspect, logs, top
    // Exec
    case exec
    // Copy
    case cp
    // Rename
    case rename
    // Attach
    case attach
    // Diff
    case diff
    // Image management
    case pull, push, build, images, rmi, imageInspect, tag
    case imageHistory, imagePrune
    case save, load
    // Commit / export / import
    case commit, export, containerImport
    // Update
    case update
    // Network
    case networkCreate, networkRm, networkLs, networkInspect, networkConnect, networkDisconnect
    // Volume
    case volumeCreate, volumeRm, volumeLs, volumeInspect
    // Container prune
    case containerPrune
    // System df
    case systemDf
    // Compose
    case composeUp, composeDown, composeLs, composeLogs
    case composePs, composeExec, composeRun, composeBuild, composePull, composeRestart
    // System
    case version, info, ping, setup, events, prune
}

public struct IPCRequest: Codable, Sendable {
    public let id: String
    public let type: IPCRequestType
    public let payload: Data
    /// **A10 — protocol versioning**. Bumped when the IPC contract gains
    /// a breaking change (a payload field becomes mandatory, an enum
    /// variant changes meaning, etc.). Older CLIs that predate this field
    /// won't send it ; the daemon treats `nil` as "legacy v0" and only
    /// rejects when the client's announced version exceeds what the
    /// daemon implements — newer-daemon-older-client is always safe.
    public let protocolVersion: Int?

    public init<T: Encodable & Sendable>(type: IPCRequestType, payload: T) throws {
        self.id = UUID().uuidString
        self.type = type
        self.payload = try JSONEncoder().encode(payload)
        self.protocolVersion = CockerVersion.ipcProtocolVersion
    }

    enum CodingKeys: String, CodingKey {
        case id, type, payload, protocolVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.type = try c.decode(IPCRequestType.self, forKey: .type)
        self.payload = try c.decode(Data.self, forKey: .payload)
        // Optional : older CLIs (pre-0.6) don't send the field.
        self.protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion)
    }
}

public struct IPCResponse: Codable, Sendable {
    public let requestId: String
    public let success: Bool
    public let payload: Data
    public let error: String?
    public let isStreaming: Bool
    public let isLast: Bool

    public init<T: Encodable & Sendable>(
        requestId: String,
        payload: T,
        isStreaming: Bool = false,
        isLast: Bool = true
    ) throws {
        self.requestId = requestId
        self.success = true
        self.payload = try JSONEncoder().encode(payload)
        self.error = nil
        self.isStreaming = isStreaming
        self.isLast = isLast
    }

    public init(requestId: String, error: String) {
        self.requestId = requestId
        self.success = false
        self.payload = Data()
        self.error = error
        self.isStreaming = false
        self.isLast = true
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - Stream event (for logs, events, build output)

public struct StreamEvent: Codable, Sendable {
    public enum Stream: String, Codable, Sendable {
        case stdout, stderr, status, error
    }
    public let stream: Stream
    public let data: String
    public let timestamp: Date

    public init(stream: Stream, data: String) {
        self.stream = stream
        self.data = data
        self.timestamp = Date()
    }

    /// Overload that preserves a known timestamp — used when replaying
    /// events from the persisted json-file log instead of generating
    /// them now. The streaming layer treats both inits identically.
    public init(stream: Stream, data: String, timestamp: Date) {
        self.stream = stream
        self.data = data
        self.timestamp = timestamp
    }
}

// MARK: - Typed request/response payloads

public struct EmptyPayload: Codable, Sendable {
    public init() {}
}

/// `image prune` payload. `all == false` keeps the historical behavior
/// (only images referenced by NO container are removed). `all == true`
/// also removes images referenced by stopped/dead containers, keeping
/// only those a currently-running container depends on. Decoded with a
/// fallback to `all: false` so an older CLI sending `EmptyPayload` still
/// gets the safe, backward-compatible prune.
public struct ImagePruneRequest: Codable, Sendable {
    public let all: Bool
    public init(all: Bool = false) { self.all = all }
}

public struct PingResponse: Codable, Sendable {
    public let version: String
    public let apiVersion: String
    public let buildTime: String

    public init() {
        self.version = CockerVersion.version
        self.apiVersion = CockerVersion.apiVersion
        self.buildTime = CockerVersion.buildTime
    }
}

public struct RunRequest: Codable, Sendable {
    public let config: RunConfig
    public init(config: RunConfig) { self.config = config }
}

public struct RunResponse: Codable, Sendable {
    public let containerID: String
    /// Non-fatal advisories from the daemon — surfaced to the CLI so a
    /// `cocker run` user gets actionable feedback for half-broken
    /// outcomes (e.g. lease pool saturation that produced a container
    /// stuck on `127.0.0.1` port-forwarding). Empty in the happy path
    /// so older CLI builds that ignore the field keep working.
    public let warnings: [String]
    public init(containerID: String, warnings: [String] = []) {
        self.containerID = containerID
        self.warnings = warnings
    }
}

public struct ContainerIDRequest: Codable, Sendable {
    public let id: String
    public let signal: String?
    public let force: Bool?
    public init(id: String, signal: String? = nil, force: Bool? = nil) {
        self.id = id; self.signal = signal; self.force = force
    }
}

public struct PSRequest: Codable, Sendable {
    public let all: Bool
    public let filter: [String: String]
    public init(all: Bool = false, filter: [String: String] = [:]) {
        self.all = all; self.filter = filter
    }
}

public struct PSResponse: Codable, Sendable {
    public let containers: [Container]
    public init(containers: [Container]) { self.containers = containers }
}

public struct LogsRequest: Codable, Sendable {
    public let id: String
    public let follow: Bool
    public let tail: Int
    public let timestamps: Bool
    public let since: Date?
    public init(id: String, follow: Bool = false, tail: Int = 100, timestamps: Bool = false, since: Date? = nil) {
        self.id = id; self.follow = follow; self.tail = tail
        self.timestamps = timestamps; self.since = since
    }
}

public struct PullRequest: Codable, Sendable {
    public let reference: String
    public let platform: String?
    public init(reference: String, platform: String? = nil) {
        self.reference = reference; self.platform = platform
    }
}

public struct BuildRequest: Codable, Sendable {
    public let config: BuildConfig
    public init(config: BuildConfig) { self.config = config }
}

public struct ImagesResponse: Codable, Sendable {
    public let images: [ImageInfo]
    public init(images: [ImageInfo]) { self.images = images }
}

public struct NetworkCreateRequest: Codable, Sendable {
    public let name: String
    public let driver: NetworkDriver
    public let subnet: String?
    public let gateway: String?
    public let labels: [String: String]
    public init(name: String, driver: NetworkDriver = .bridge, subnet: String? = nil,
                gateway: String? = nil, labels: [String: String] = [:]) {
        self.name = name; self.driver = driver; self.subnet = subnet
        self.gateway = gateway; self.labels = labels
    }
}

public struct NetworksResponse: Codable, Sendable {
    public let networks: [NetworkInfo]
    public init(networks: [NetworkInfo]) { self.networks = networks }
}

public struct VolumeCreateRequest: Codable, Sendable {
    public let name: String
    public let driver: String
    public let labels: [String: String]
    public init(name: String, driver: String = "local", labels: [String: String] = [:]) {
        self.name = name; self.driver = driver; self.labels = labels
    }
}

public struct VolumesResponse: Codable, Sendable {
    public let volumes: [VolumeInfo]
    public init(volumes: [VolumeInfo]) { self.volumes = volumes }
}

public struct ExecRequest: Codable, Sendable {
    public let config: ExecConfig
    public init(config: ExecConfig) { self.config = config }
}

public struct InfoResponse: Codable, Sendable {
    public let containers: Int
    public let containersRunning: Int
    public let images: Int
    public let volumes: Int
    public let networks: Int
    public let kernelVersion: String
    public let architecture: String
    public let cpus: Int
    public let totalMemory: UInt64
    public let cockerRootDir: String
    public let socketPath: String

    public init(containers: Int, containersRunning: Int, images: Int, volumes: Int, networks: Int,
                kernelVersion: String, architecture: String, cpus: Int, totalMemory: UInt64,
                cockerRootDir: String, socketPath: String) {
        self.containers = containers; self.containersRunning = containersRunning
        self.images = images; self.volumes = volumes; self.networks = networks
        self.kernelVersion = kernelVersion; self.architecture = architecture
        self.cpus = cpus; self.totalMemory = totalMemory
        self.cockerRootDir = cockerRootDir; self.socketPath = socketPath
    }
}

public struct ComposeRequest: Codable, Sendable {
    public let composePath: String
    public let projectName: String?
    public let services: [String]
    public let detach: Bool
    public let activeProfiles: [String]?
    /// `compose down --volumes` : also drop named volumes the project
    /// created. Bind mounts are never touched (Docker semantics —
    /// volumes the user mounted from host paths are theirs to manage).
    public let removeVolumes: Bool
    /// `compose logs -f` : stream log lines as they arrive. Old CLIs
    /// don't send this field ; daemon falls back to a one-shot tail.
    public let follow: Bool
    /// How many tail lines to send before going live (or as a one-shot
    /// when `follow == false`). Mirrors `docker compose logs --tail`.
    public let tail: Int
    /// `compose up --build` : re-build every service with a `build:`
    /// block even when an image with the target tag already exists.
    /// Without this, the daemon's "skip if exists" short-circuit pins
    /// the project to the first (possibly broken) build forever.
    /// PRO-51. Old CLIs don't send the field → daemon falls back to
    /// the historical "build only when missing" behaviour.
    public let forceBuild: Bool
    /// `compose build --no-cache`: execute every RUN instruction instead of
    /// consulting the on-disk layer cache.
    public let noCache: Bool
    public init(composePath: String, projectName: String? = nil, services: [String] = [],
                detach: Bool = false, activeProfiles: [String]? = nil,
                removeVolumes: Bool = false, follow: Bool = false, tail: Int = 50,
                forceBuild: Bool = false, noCache: Bool = false) {
        self.composePath = composePath; self.projectName = projectName
        self.services = services; self.detach = detach
        self.activeProfiles = activeProfiles
        self.removeVolumes = removeVolumes
        self.follow = follow
        self.tail = tail
        self.forceBuild = forceBuild
        self.noCache = noCache
    }

    enum CodingKeys: String, CodingKey {
        case composePath, projectName, services, detach, activeProfiles, removeVolumes, follow, tail, forceBuild, noCache
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.composePath    = try c.decode(String.self, forKey: .composePath)
        self.projectName    = try c.decodeIfPresent(String.self, forKey: .projectName)
        self.services       = try c.decodeIfPresent([String].self, forKey: .services) ?? []
        self.detach         = try c.decodeIfPresent(Bool.self, forKey: .detach) ?? false
        self.activeProfiles = try c.decodeIfPresent([String].self, forKey: .activeProfiles)
        // Default false : older CLIs that don't send the field keep the
        // pre-7.2 behaviour ("`down` never touches volumes").
        self.removeVolumes  = try c.decodeIfPresent(Bool.self, forKey: .removeVolumes) ?? false
        // Same backwards-compat dance for follow/tail.
        self.follow         = try c.decodeIfPresent(Bool.self, forKey: .follow) ?? false
        self.tail           = try c.decodeIfPresent(Int.self,  forKey: .tail) ?? 50
        // PRO-51 : default false so a pre-v0.7.10 CLI keeps the historical
        // "skip rebuild when image already exists" behaviour.
        self.forceBuild     = try c.decodeIfPresent(Bool.self, forKey: .forceBuild) ?? false
        self.noCache        = try c.decodeIfPresent(Bool.self, forKey: .noCache) ?? false
    }
}

public struct PruneRequest: Codable, Sendable {
    public let volumes: Bool
    public init(volumes: Bool = false) { self.volumes = volumes }
}

public struct PruneResponse: Codable, Sendable {
    public let containersDeleted: [String]
    public let imagesDeleted: [String]
    public let volumesDeleted: [String]
    public let spaceReclaimed: UInt64

    public init(containersDeleted: [String], imagesDeleted: [String], volumesDeleted: [String], spaceReclaimed: UInt64) {
        self.containersDeleted = containersDeleted; self.imagesDeleted = imagesDeleted
        self.volumesDeleted = volumesDeleted; self.spaceReclaimed = spaceReclaimed
    }
}

public struct CpRequest: Codable, Sendable {
    public let containerID: String
    public let containerPath: String
    public let hostPath: String
    public let toContainer: Bool  // true: host→container, false: container→host
    public init(containerID: String, containerPath: String, hostPath: String, toContainer: Bool) {
        self.containerID = containerID
        self.containerPath = containerPath
        self.hostPath = hostPath
        self.toContainer = toContainer
    }
}

public struct RenameRequest: Codable, Sendable {
    public let id: String
    public let newName: String
    public init(id: String, newName: String) { self.id = id; self.newName = newName }
}

public struct DiffEntry: Codable, Sendable {
    public let kind: String  // "A" added, "C" changed, "D" deleted
    public let path: String
    public init(kind: String, path: String) { self.kind = kind; self.path = path }
}

public struct DiffResponse: Codable, Sendable {
    public let entries: [DiffEntry]
    public init(entries: [DiffEntry]) { self.entries = entries }
}

public struct ImageHistoryEntry: Codable, Sendable {
    public let id: String
    public let createdAt: Date
    public let createdBy: String
    public let size: UInt64
    public let comment: String
    public init(id: String, createdAt: Date, createdBy: String, size: UInt64, comment: String) {
        self.id = id; self.createdAt = createdAt; self.createdBy = createdBy
        self.size = size; self.comment = comment
    }
}

public struct ImageHistoryResponse: Codable, Sendable {
    public let entries: [ImageHistoryEntry]
    public init(entries: [ImageHistoryEntry]) { self.entries = entries }
}

public struct SaveRequest: Codable, Sendable {
    public let image: String
    /// **IPC v2** : when set, the daemon writes the tar archive directly to
    /// this absolute path instead of embedding the bytes in the JSON
    /// response. CLI and daemon share a host (Unix socket) and run as the
    /// same user, so a filesystem handoff is safe — and it lifts the
    /// 100 MB frame cap + base64 +33 % + full-buffer-in-RAM cost that made
    /// `cocker save` fail on any real image. nil = legacy in-band bytes.
    public let outputPath: String?
    public init(image: String, outputPath: String? = nil) {
        self.image = image
        self.outputPath = outputPath
    }
    enum CodingKeys: String, CodingKey { case image, outputPath }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.image = try c.decode(String.self, forKey: .image)
        self.outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath)
    }
}

public struct SaveResponse: Codable, Sendable {
    /// Legacy in-band payload. Empty when the daemon honoured
    /// `outputPath` (v2 path handoff) — check `filePath` instead.
    public let tarData: Data
    /// v2 : where the daemon wrote the archive (== the requested
    /// outputPath). nil for legacy in-band responses.
    public let filePath: String?
    /// v2 : size of the archive on disk, for CLI display.
    public let byteCount: UInt64?
    public init(tarData: Data, filePath: String? = nil, byteCount: UInt64? = nil) {
        self.tarData = tarData
        self.filePath = filePath
        self.byteCount = byteCount
    }
    enum CodingKeys: String, CodingKey { case tarData, filePath, byteCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tarData = try c.decodeIfPresent(Data.self, forKey: .tarData) ?? Data()
        self.filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        self.byteCount = try c.decodeIfPresent(UInt64.self, forKey: .byteCount)
    }
}

public struct LoadRequest: Codable, Sendable {
    /// Legacy in-band payload. Empty when `inputPath` is set.
    public let tarData: Data
    /// **IPC v2** : absolute path of a tar the daemon should read directly
    /// (same-host filesystem handoff, see SaveRequest.outputPath).
    public let inputPath: String?
    public init(tarData: Data, inputPath: String? = nil) {
        self.tarData = tarData
        self.inputPath = inputPath
    }
    enum CodingKeys: String, CodingKey { case tarData, inputPath }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tarData = try c.decodeIfPresent(Data.self, forKey: .tarData) ?? Data()
        self.inputPath = try c.decodeIfPresent(String.self, forKey: .inputPath)
    }
}

public struct SystemDfResponse: Codable, Sendable {
    public struct DfEntry: Codable, Sendable {
        public let type: String
        public let total: Int
        public let active: Int
        public let size: UInt64
        public let reclaimable: UInt64
        public init(type: String, total: Int, active: Int, size: UInt64, reclaimable: UInt64) {
            self.type = type; self.total = total; self.active = active
            self.size = size; self.reclaimable = reclaimable
        }
    }
    public let entries: [DfEntry]
    public init(entries: [DfEntry]) { self.entries = entries }
}

public struct ComposeLsResponse: Codable, Sendable {
    public struct ProjectInfo: Codable, Sendable {
        public let name: String
        public let status: String
        public let configFiles: String
        public let servicesCount: Int
        public init(name: String, status: String, configFiles: String, servicesCount: Int) {
            self.name = name; self.status = status; self.configFiles = configFiles; self.servicesCount = servicesCount
        }
    }
    public let projects: [ProjectInfo]
    public init(projects: [ProjectInfo]) { self.projects = projects }
}

public struct CommitRequest: Codable, Sendable {
    public let containerID: String
    public let tag: String
    public let author: String?
    public let message: String?
    public init(containerID: String, tag: String, author: String? = nil, message: String? = nil) {
        self.containerID = containerID; self.tag = tag; self.author = author; self.message = message
    }
}

public struct ExportRequest: Codable, Sendable {
    public let containerID: String
    /// **IPC v2** : same-host filesystem handoff (see SaveRequest).
    /// nil = legacy in-band bytes (still used for stdout streaming).
    public let outputPath: String?
    public init(containerID: String, outputPath: String? = nil) {
        self.containerID = containerID
        self.outputPath = outputPath
    }
    enum CodingKeys: String, CodingKey { case containerID, outputPath }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.containerID = try c.decode(String.self, forKey: .containerID)
        self.outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath)
    }
}

public struct ContainerImportRequest: Codable, Sendable {
    /// Legacy in-band payload. Empty when `inputPath` is set. Kept for
    /// stdin imports (`cocker import -`) where no file exists.
    public let tarData: Data
    public let tag: String
    /// **IPC v2** : same-host filesystem handoff (see SaveRequest).
    public let inputPath: String?
    public init(tarData: Data, tag: String, inputPath: String? = nil) {
        self.tarData = tarData
        self.tag = tag
        self.inputPath = inputPath
    }
    enum CodingKeys: String, CodingKey { case tarData, tag, inputPath }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tarData = try c.decodeIfPresent(Data.self, forKey: .tarData) ?? Data()
        self.tag = try c.decode(String.self, forKey: .tag)
        self.inputPath = try c.decodeIfPresent(String.self, forKey: .inputPath)
    }
}

public struct UpdateRequest: Codable, Sendable {
    public let containerID: String
    public let cpus: Int?
    public let memoryMB: UInt64?
    public init(containerID: String, cpus: Int? = nil, memoryMB: UInt64? = nil) {
        self.containerID = containerID; self.cpus = cpus; self.memoryMB = memoryMB
    }
}

// MARK: - Version

public enum CockerVersion {
    // Bumped manually with each tag. TODO : drive from a Version.generated.swift
    // produced by the release workflow so this can't drift again.
    public static let version = "0.7.13.17"
    public static let apiVersion = "1.0"
    public static let buildTime = "2026-06-13"
    public static let minAPIVersion = "1.0"

    /// **A10 — IPC protocol version**. v1 = post-audit shape (the
    /// `protocolVersion` field exists on `IPCRequest`, kill / inspect
    /// surfaces honour the post-audit invariants). v0 = pre-0.6.0 daemons
    /// that don't send the field. v2 = save/load/export/import gained
    /// same-host filesystem handoff (outputPath/inputPath) so tarballs
    /// no longer ride base64-encoded inside JSON frames. The daemon
    /// rejects any client claiming a version higher than what it
    /// implements ; older clients keep working (in-band bytes remain
    /// accepted).
    public static let ipcProtocolVersion: Int = 2
}

/// **C3 — InspectResponse**. The legacy `case .inspect` path returns a
/// raw `Container` which carries every internal field (natMAC, restartCount,
/// healthLog history). Operators inspecting their containers from automated
/// tooling get exposed to all of it. This DTO is the post-audit shape :
/// it deliberately omits low-level networking details unless the caller
/// asks for them, and it routes env through `SecretRedactor` so secrets
/// don't leave the daemon in cleartext unless explicitly requested.
///
/// The legacy `.inspect → Container` flow remains for CLI compat ; new
/// callers should prefer `.inspectV2 → InspectResponse` once that endpoint
/// lands. The shape is published now so external automation can adopt it.
public struct InspectResponse: Codable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let status: ContainerStatus
    public let command: [String]
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let exitCode: Int32?
    public let ports: [PortMapping]
    public let volumes: [VolumeMount]
    public let env: [String: String]
    public let labels: [String: String]
    public let networkMode: NetworkMode
    public let networkName: String?
    public let ip: String?
    public let ipv6: String?
    public let hostname: String
    public let restartPolicy: RestartPolicy
    public let restartCount: Int
    public let healthStatus: HealthStatus
    public let healthFailingStreak: Int

    public init(from container: Container, redactSecrets: Bool = true) {
        self.id = container.id
        self.name = container.name
        self.image = container.image
        self.status = container.status
        self.command = container.command
        self.createdAt = container.createdAt
        self.startedAt = container.startedAt
        self.finishedAt = container.finishedAt
        self.exitCode = container.exitCode
        self.ports = container.ports
        self.volumes = container.volumes
        self.env = redactSecrets
            ? SecretRedactor.redact(container.env)
            : container.env
        self.labels = container.labels
        self.networkMode = container.networkMode
        self.networkName = container.networkName
        self.ip = container.ip
        self.ipv6 = container.ipv6
        self.hostname = container.hostname
        self.restartPolicy = container.restartPolicy
        self.restartCount = container.restartCount
        self.healthStatus = container.healthStatus
        self.healthFailingStreak = container.healthFailingStreak
    }
}
