import Foundation

// MARK: - Container

public struct Container: Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var image: String
    public var command: [String]
    public var status: ContainerStatus
    public var ports: [PortMapping]
    public var volumes: [VolumeMount]
    public var env: [String: String]
    public var labels: [String: String]
    public var networkMode: NetworkMode
    public var networkName: String?
    public var ip: String?
    /// IP on the cocker L2 switch network (10.42.0.0/16) used for inter-container traffic
    public var cockerIP: String?
    /// MAC assigned to the container's switch-side NIC (02:42:0A:2A:xx:xx)
    public var cockerMAC: String?
    /// MAC pinned on the eth0 (vmnet NAT) side. Set explicitly by cockerd
    /// so the host can look up the corresponding DHCP lease in
    /// `/var/db/dhcpd_leases` when the in-VM `/cocker-ip` write loses the
    /// DHCP race.
    public var natMAC: String?
    /// Address configured on eth0 when cocker assigns it itself instead of
    /// requesting a DHCP lease. This is what makes the assignment durable:
    /// the persisted container list *is* the allocator's registry, so a
    /// restarted daemon sees what is already taken instead of handing out
    /// duplicates. nil on the DHCP path.
    public var natIP: String?
    public var cpuCount: Int
    public var memoryMB: UInt64
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var hostname: String
    public var restartPolicy: RestartPolicy
    public var healthStatus: HealthStatus
    public var healthcheck: Healthcheck?
    /// Consecutive healthcheck failures since the last success. Persisted so
    /// the Docker API's `State.Health.FailingStreak` matches what Docker
    /// surfaces (resets to 0 on the next healthy probe).
    public var healthFailingStreak: Int
    /// Rolling history of the last `healthLogMax` probe results. Mirrors
    /// Docker's `State.Health.Log[]` shape. Bounded to the same 5 entries
    /// Docker uses so JSON payloads stay reasonable.
    public var healthLog: [HealthLogEntry]
    /// Number of times watchContainer restarted this container after a
    /// non-zero exit. Persisted so `cocker inspect` and the Docker API's
    /// RestartCount field match across daemon restarts.
    public var restartCount: Int
    public var privileged: Bool
    public var capAdd: [String]
    public var capDrop: [String]
    /// Dockerfile `STOPSIGNAL` (or runtime `--stop-signal`) propagated to
    /// the container init so a `cocker stop` sends the right signal to the
    /// container's main process. Empty/nil = init's default (SIGTERM).
    /// Examples : "SIGQUIT" for nginx, "SIGINT" for some PHP-FPM setups.
    public var stopSignal: String?
    /// `--shm-size` : size of /dev/shm tmpfs inside the container in MiB.
    /// nil = leave the in-container default (typically 64 MB on Linux).
    /// Postgres needs ~1024+, Chromium-based stuff often demands 2048+,
    /// without which the apps crash with cryptic "no space left on
    /// device" errors. Plumbed through the kernel cmdline so cocker-init
    /// can size the shm mount before the user process starts.
    public var shmSizeMB: UInt64?
    /// `run -it` : the main process gets the console as a controlling
    /// terminal. Optional so containers written by an older daemon decode.
    public var tty: Bool?
    public var ttyRows: Int?
    public var ttyCols: Int?

    public init(
        id: String = UUID().uuidString.prefix(12).lowercased(),
        name: String,
        image: String,
        command: [String],
        status: ContainerStatus = .created,
        ports: [PortMapping] = [],
        volumes: [VolumeMount] = [],
        env: [String: String] = [:],
        labels: [String: String] = [:],
        networkMode: NetworkMode = .nat,
        networkName: String? = nil,
        ip: String? = nil,
        cpuCount: Int = 2,
        memoryMB: UInt64 = 512,
        hostname: String? = nil,
        restartPolicy: RestartPolicy = .no,
        healthStatus: HealthStatus = .none,
        healthcheck: Healthcheck? = nil,
        healthFailingStreak: Int = 0,
        healthLog: [HealthLogEntry] = [],
        restartCount: Int = 0,
        privileged: Bool = false,
        capAdd: [String] = [],
        capDrop: [String] = [],
        stopSignal: String? = nil
    ) {
        self.id = String(id.prefix(12))
        self.name = name
        self.image = image
        self.command = command
        self.status = status
        self.ports = ports
        self.volumes = volumes
        self.env = env
        self.labels = labels
        self.networkMode = networkMode
        self.networkName = networkName
        self.ip = ip
        self.cpuCount = cpuCount
        self.restartPolicy = restartPolicy
        self.memoryMB = memoryMB
        self.createdAt = Date()
        self.hostname = hostname ?? String(id.prefix(12))
        self.healthStatus = healthStatus
        self.healthcheck = healthcheck
        self.healthFailingStreak = healthFailingStreak
        self.healthLog = healthLog
        self.restartCount = restartCount
        self.privileged = privileged
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.stopSignal = stopSignal
    }

    // MARK: - Codable with forward-migration defaults
    //
    // Container is persisted to ~/.cocker/state.json. New fields added in
    // later cocker releases must NOT cause the entire state file to be
    // rejected — that would silently wipe every container the user has
    // when they upgrade. We implement init(from:) explicitly so any new
    // field added later defaults gracefully instead of throwing.

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.image = try c.decode(String.self, forKey: .image)
        self.command = try c.decodeIfPresent([String].self, forKey: .command) ?? []
        self.status = try c.decodeIfPresent(ContainerStatus.self, forKey: .status) ?? .stopped
        self.ports = try c.decodeIfPresent([PortMapping].self, forKey: .ports) ?? []
        self.volumes = try c.decodeIfPresent([VolumeMount].self, forKey: .volumes) ?? []
        self.env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        self.labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        self.networkMode = try c.decodeIfPresent(NetworkMode.self, forKey: .networkMode) ?? .nat
        self.networkName = try c.decodeIfPresent(String.self, forKey: .networkName)
        self.ip = try c.decodeIfPresent(String.self, forKey: .ip)
        self.cockerIP = try c.decodeIfPresent(String.self, forKey: .cockerIP)
        self.cockerMAC = try c.decodeIfPresent(String.self, forKey: .cockerMAC)
        self.natMAC = try c.decodeIfPresent(String.self, forKey: .natMAC)
        // Every stored property has to be listed here or it silently reads
        // back as nil — this hand-written decoder has already swallowed
        // `tty` and `shmSizeMB` that way. For natIP the loss would be worse
        // than a missing flag: the allocator reads persisted addresses to
        // know what is taken, so dropping them means handing out duplicates
        // after every daemon restart.
        self.natIP = try c.decodeIfPresent(String.self, forKey: .natIP)
        self.cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 2
        self.memoryMB = try c.decodeIfPresent(UInt64.self, forKey: .memoryMB) ?? 512
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        self.hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
            ?? String(self.id.prefix(12))
        self.restartPolicy = try c.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy) ?? .no
        self.healthStatus = try c.decodeIfPresent(HealthStatus.self, forKey: .healthStatus) ?? .none
        self.healthcheck = try c.decodeIfPresent(Healthcheck.self, forKey: .healthcheck)
        // Fields added after the initial release : default to safe zeros
        // when missing instead of failing the whole decode.
        self.healthFailingStreak = try c.decodeIfPresent(Int.self, forKey: .healthFailingStreak) ?? 0
        self.healthLog = try c.decodeIfPresent([HealthLogEntry].self, forKey: .healthLog) ?? []
        self.restartCount = try c.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0
        self.privileged = try c.decodeIfPresent(Bool.self, forKey: .privileged) ?? false
        self.capAdd = try c.decodeIfPresent([String].self, forKey: .capAdd) ?? []
        self.capDrop = try c.decodeIfPresent([String].self, forKey: .capDrop) ?? []
        self.stopSignal = try c.decodeIfPresent(String.self, forKey: .stopSignal)
        // Container has an explicit decoder, so a new property is invisible
        // until it is listed here. `shmSizeMB` and the tty trio were added as
        // stored properties and silently dropped on every round-trip —
        // `cocker attach` couldn't tell a `-t` container from a plain one
        // because `tty` came back nil no matter what was stored.
        self.shmSizeMB = try c.decodeIfPresent(UInt64.self, forKey: .shmSizeMB)
        self.tty = try c.decodeIfPresent(Bool.self, forKey: .tty)
        self.ttyRows = try c.decodeIfPresent(Int.self, forKey: .ttyRows)
        self.ttyCols = try c.decodeIfPresent(Int.self, forKey: .ttyCols)
    }
}

public enum HealthStatus: String, Codable, Sendable {
    case none, starting, healthy, unhealthy
}

/// RFC 3339 with nanosecond precision, matching Go's `time.RFC3339Nano`
/// formatter (trailing zeros trimmed). Docker emits this format for
/// `State.Health.Log[].Start/End` and `Created` ; Go template parsers
/// reading the result as `time.Time` need at least one nano digit when
/// sub-second precision is present, otherwise they fall back to RFC3339
/// and silently round.
///
/// Lives in CockerCore so both CockerDaemon (Docker API) and CockerCLI
/// (`cocker inspect`) emit identical timestamps for the same Date.
public func rfc3339Nano(_ date: Date) -> String {
    let calendar = Calendar(identifier: .gregorian)
    var c = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
    let nano = Int(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1_000_000_000)
    c.nanosecond = nano
    let mainPart = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                          c.year ?? 0, c.month ?? 0, c.day ?? 0,
                          c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    if nano == 0 { return "\(mainPart)Z" }
    var frac = String(format: "%09d", nano)
    while frac.hasSuffix("0") { frac.removeLast() }
    return "\(mainPart).\(frac)Z"
}

/// Single healthcheck probe outcome. Mirrors Docker's
/// `Health.Log[]` entry shape so the Docker API translation is a 1:1
/// field copy.
public struct HealthLogEntry: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var exitCode: Int32
    public var output: String

    public init(start: Date, end: Date, exitCode: Int32, output: String) {
        self.start = start
        self.end = end
        self.exitCode = exitCode
        self.output = output
    }
}

/// HEALTHCHECK spec, mirrors Docker's `Healthcheck` shape in the OCI image
/// config. Cocker runs the command inside the container via the existing
/// `cocker exec` vsock listener at each `interval` and flips
/// `Container.healthStatus` based on the exit code.
public struct Healthcheck: Codable, Sendable, Equatable {
    /// argv to execute. The first element is by convention either
    /// "NONE" (disabled), "CMD" (raw exec), or "CMD-SHELL" (run via
    /// `/bin/sh -c`). See parseDockerfile for how raw Dockerfile lines map
    /// here.
    public var test: [String]
    /// Time between checks, seconds. Docker default: 30.
    public var interval: TimeInterval
    /// Per-check timeout, seconds. Docker default: 30.
    public var timeout: TimeInterval
    /// Grace window after container start before checks count. Default: 0.
    public var startPeriod: TimeInterval
    /// Consecutive failures before the container is marked unhealthy.
    public var retries: Int

    public init(test: [String],
                interval: TimeInterval = 30,
                timeout: TimeInterval = 30,
                startPeriod: TimeInterval = 0,
                retries: Int = 3) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.startPeriod = startPeriod
        self.retries = retries
    }

    /// True when this spec represents a disabled healthcheck — the user
    /// passed `--no-healthcheck`, the image declared `HEALTHCHECK NONE`, or
    /// the test argv is empty. Case-insensitive on "NONE" because some
    /// hand-written OCI image configs and compose files use lowercase
    /// `"none"` even though Docker's canonical form is uppercase.
    public var isDisabled: Bool {
        guard let first = test.first else { return true }
        return first.uppercased() == "NONE"
    }
}

public enum ContainerStatus: String, Codable, Sendable {
    case created
    case running
    case paused
    case restarting
    case stopped
    case dead

    public var description: String { rawValue }
}

public struct PortMapping: Codable, Sendable, Equatable, CustomStringConvertible {
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let proto: TransportProto

    public init(hostPort: UInt16, containerPort: UInt16, proto: TransportProto = .tcp) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }

    public var description: String { "0.0.0.0:\(hostPort)->\(containerPort)/\(proto.rawValue)" }

    public static func parse(_ s: String) throws -> PortMapping {
        guard let first = try parseSpec(s).first else {
            throw CockerError.invalidPortMapping(s)
        }
        return first
    }

    /// Parse one `ports:` entry into every mapping it describes.
    ///
    /// Only `HOST:CONTAINER` and a bare `PORT` used to parse. Everything else
    /// — `8080:80/udp`, `127.0.0.1:8080:80`, `8000-8010:8000-8010` — threw,
    /// and compose `compactMap`'d the throw away, so the port was simply
    /// never published and nothing said so.
    ///
    /// A host IP is accepted and ignored: cocker's forwarder binds all
    /// interfaces, and dropping the whole mapping over an unsupported bind
    /// address is worse than binding it more widely than asked.
    public static func parseSpec(_ s: String) throws -> [PortMapping] {
        var body = s
        var proto: TransportProto = .tcp
        if let slash = body.lastIndex(of: "/") {
            let suffix = String(body[body.index(after: slash)...]).lowercased()
            guard let parsed = TransportProto(rawValue: suffix) else {
                throw CockerError.invalidPortMapping(s)
            }
            proto = parsed
            body = String(body[..<slash])
        }

        var fields = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // `IP:HOST:CONTAINER` — drop the bind address (see above).
        if fields.count == 3 { fields.removeFirst() }
        guard fields.count == 1 || fields.count == 2 else {
            throw CockerError.invalidPortMapping(s)
        }

        let hostRange = try portRange(fields[0], in: s)
        let containerRange = try portRange(fields.count == 2 ? fields[1] : fields[0], in: s)
        guard hostRange.count == containerRange.count else {
            throw CockerError.invalidPortMapping(s)
        }
        return zip(hostRange, containerRange).map {
            PortMapping(hostPort: $0, containerPort: $1, proto: proto)
        }
    }

    /// `8080` → [8080] ; `8000-8010` → [8000…8010].
    private static func portRange(_ field: String, in spec: String) throws -> [UInt16] {
        if let dash = field.firstIndex(of: "-") {
            guard let lo = UInt16(field[..<dash]),
                  let hi = UInt16(field[field.index(after: dash)...]),
                  lo <= hi else {
                throw CockerError.invalidPortMapping(spec)
            }
            return Array(lo...hi)
        }
        guard let port = UInt16(field) else { throw CockerError.invalidPortMapping(spec) }
        return [port]
    }
}

public enum TransportProto: String, Codable, Sendable {
    case tcp, udp
}

public struct VolumeMount: Codable, Sendable, CustomStringConvertible {
    public let source: String
    public let destination: String
    public let readOnly: Bool

    public init(source: String, destination: String, readOnly: Bool = false) {
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
    }

    public var description: String { "\(source):\(destination)\(readOnly ? ":ro" : "")" }

    public static func parse(_ s: String) throws -> VolumeMount {
        let parts = s.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { throw CockerError.invalidVolumeSpec(s) }
        let ro = parts.count == 3 && parts[2] == "ro"
        return VolumeMount(source: parts[0], destination: parts[1], readOnly: ro)
    }
}

public enum NetworkMode: String, Codable, Sendable {
    case nat        // VZNATNetworkDeviceAttachment
    case bridged    // VZBridgedNetworkDeviceAttachment
    case host       // Shared host network
    case none       // No network
}

// MARK: - Image

public struct ImageInfo: Codable, Sendable, Identifiable {
    public let id: String           // sha256 digest
    public var repository: String
    public var tag: String
    public var size: UInt64
    public var createdAt: Date
    public var architecture: String
    public var os: String
    public var layers: [String]     // layer digests

    // OCI image config defaults (CMD, ENTRYPOINT, ENV, WORKDIR, LABEL, EXPOSE)
    // — utilisés par ContainerEngine.run() quand l'user ne fournit pas de cmd.
    // Sans ça, `cocker run my-image` ignore le CMD du Dockerfile.
    public var cmd: [String]?
    public var entrypoint: [String]?
    public var env: [String]?       // ["KEY=VALUE", ...]
    public var workdir: String?
    public var user: String?        // OCI config.User — Dockerfile USER
    public var labels: [String: String]
    public var exposedPorts: [String]
    public var healthcheck: Healthcheck?
    /// Dockerfile `STOPSIGNAL` value (e.g. "SIGQUIT", "SIGTERM"). Forwarded
    /// to `Container.stopSignal` at run-time and from there to cocker-init
    /// via the v5 spec format.
    public var stopSignal: String?

    public var reference: String { "\(repository):\(tag)" }

    public init(
        id: String,
        repository: String,
        tag: String = "latest",
        size: UInt64 = 0,
        createdAt: Date = Date(),
        architecture: String = "arm64",
        os: String = "linux",
        layers: [String] = [],
        cmd: [String]? = nil,
        entrypoint: [String]? = nil,
        env: [String]? = nil,
        workdir: String? = nil,
        user: String? = nil,
        labels: [String: String] = [:],
        exposedPorts: [String] = [],
        healthcheck: Healthcheck? = nil,
        stopSignal: String? = nil
    ) {
        self.id = id
        self.repository = repository
        self.tag = tag
        self.size = size
        self.createdAt = createdAt
        self.architecture = architecture
        self.os = os
        self.layers = layers
        self.cmd = cmd
        self.entrypoint = entrypoint
        self.env = env
        self.workdir = workdir
        self.user = user
        self.labels = labels
        self.exposedPorts = exposedPorts
        self.healthcheck = healthcheck
        self.stopSignal = stopSignal
    }
}

// MARK: - Network

public struct NetworkInfo: Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var driver: NetworkDriver
    public var subnet: String
    public var gateway: String
    public var subnet6: String
    public var gateway6: String
    public var containers: [String]
    public var createdAt: Date
    /// `network create --label`. Optional so networks written by an older
    /// daemon still decode; read it through `labelMap`.
    public var labels: [String: String]?

    public var labelMap: [String: String] { labels ?? [:] }

    public init(
        id: String = UUID().uuidString.prefix(12).lowercased(),
        name: String,
        driver: NetworkDriver = .bridge,
        subnet: String = "172.20.0.0/16",
        gateway: String = "172.20.0.1",
        containers: [String] = [],
        labels: [String: String] = [:]
    ) {
        self.id = String(id.prefix(12))
        self.name = name
        self.driver = driver
        self.subnet = subnet
        self.gateway = gateway
        self.subnet6 = "fd00:c0c4::/48"
        self.gateway6 = "fd00:c0c4::1"
        self.containers = containers
        self.labels = labels
        self.createdAt = Date()
    }
}

public enum NetworkDriver: String, Codable, Sendable {
    case bridge, host, none, overlay
}

// MARK: - Volume

public struct VolumeInfo: Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var mountpoint: String
    public var driver: String
    public var labels: [String: String]
    public var createdAt: Date
    /// True when cocker invented this volume rather than the user naming it
    /// — an auto-created mount source, or a compose service's anonymous
    /// volume. Only these are eligible for `docker rm -v`; a named volume
    /// outlives its containers by definition.
    ///
    /// Optional so volumes written by an older daemon still decode; read it
    /// through `isAnonymous`.
    public var anonymous: Bool?

    public var isAnonymous: Bool { anonymous ?? false }

    public init(
        id: String = UUID().uuidString.prefix(12).lowercased(),
        name: String,
        mountpoint: String = "",
        driver: String = "local",
        labels: [String: String] = [:],
        anonymous: Bool = false
    ) {
        self.id = String(id.prefix(12))
        self.name = name
        self.driver = driver
        self.labels = labels
        self.anonymous = anonymous
        self.createdAt = Date()
        self.mountpoint = mountpoint.isEmpty
            ? "\(NSHomeDirectory())/.cocker/volumes/\(name)/_data"
            : mountpoint
    }
}

// MARK: - Run Config (cocker run options)

public struct RunConfig: Codable, Sendable {
    public var image: String
    public var command: [String]
    /// Overrides the image's ENTRYPOINT (compose `entrypoint:`, Docker API
    /// `Entrypoint`). nil means "keep the image's". There was no field at
    /// all before, so both paths decoded the value and discarded it and an
    /// ENTRYPOINT override was simply impossible.
    public var entrypoint: [String]?
    /// Terminal geometry for `run -it`, so the container's main process
    /// starts at the caller's real size.
    public var rows: Int?
    public var cols: Int?
    public var name: String?
    public var detach: Bool
    public var interactive: Bool
    public var tty: Bool
    public var ports: [PortMapping]
    public var volumes: [VolumeMount]
    public var env: [String: String]
    public var labels: [String: String]
    public var network: String?
    public var networkMode: NetworkMode
    public var cpuCount: Int
    public var memoryMB: UInt64
    public var rm: Bool
    public var hostname: String?
    public var workdir: String?
    public var user: String?
    public var restartPolicy: RestartPolicy
    public var capAdd: [String]
    public var capDrop: [String]
    public var privileged: Bool
    public var addHosts: [String]
    public var dnsServers: [String]
    public var dnsSearch: [String]
    public var volumesFrom: [String]
    public var tmpfsMounts: [String]
    public var readOnly: Bool
    /// CLI healthcheck overrides — mirror Docker's `--health-*` and
    /// `--no-healthcheck` flags. Any non-nil value here wins over the
    /// HEALTHCHECK declared in the image. `disable=true` mirrors
    /// `--no-healthcheck` and produces a `["NONE"]` test, suppressing
    /// the image's healthcheck entirely.
    public var healthCmd: String?
    public var healthInterval: TimeInterval?
    public var healthTimeout: TimeInterval?
    public var healthStartPeriod: TimeInterval?
    public var healthRetries: Int?
    public var healthDisable: Bool
    /// Signal cocker-init sends to PID 1 on `docker stop` / `cocker stop`
    /// before falling back to SIGKILL after the grace period. Default
    /// SIGTERM matches Docker. Accepts `SIGTERM`, `SIGINT`, `SIGUSR1`,
    /// `15`, etc. — passed through to the runtime as-is.
    public var stopSignal: String?
    /// Size of `/dev/shm` tmpfs inside the container in MiB. nil =
    /// inherit kernel default (typically 64MB on Linux). Matches
    /// Docker `--shm-size` ; postgres / redis / chromium tend to need
    /// 1024+.
    public var shmSizeMB: UInt64?

    public init(image: String, command: [String] = []) {
        self.image = image
        self.command = command
        self.entrypoint = nil
        self.rows = nil
        self.cols = nil
        self.name = nil
        self.detach = false
        self.interactive = false
        self.tty = false
        self.ports = []
        self.volumes = []
        self.env = [:]
        self.labels = [:]
        self.network = nil
        self.networkMode = .nat
        self.cpuCount = 2
        self.memoryMB = 512
        self.rm = false
        self.hostname = nil
        self.workdir = nil
        self.user = nil
        self.restartPolicy = .no
        self.capAdd = []
        self.capDrop = []
        self.privileged = false
        self.addHosts = []
        self.dnsServers = []
        self.dnsSearch = []
        self.volumesFrom = []
        self.tmpfsMounts = []
        self.readOnly = false
        self.healthCmd = nil
        self.healthInterval = nil
        self.healthTimeout = nil
        self.healthStartPeriod = nil
        self.healthRetries = nil
        self.healthDisable = false
        self.stopSignal = nil
        self.shmSizeMB = nil
    }
}

public enum RestartPolicy: String, Codable, Sendable {
    case no = "no"
    case always = "always"
    case onFailure = "on-failure"
    case unlessStopped = "unless-stopped"
}

// MARK: - Build Config

public struct BuildConfig: Codable, Sendable {
    public var contextPath: String
    public var dockerfile: String
    public var tag: String
    public var buildArgs: [String: String]
    public var noCache: Bool
    public var target: String?
    public var platform: String?

    public init(contextPath: String, tag: String) {
        self.contextPath = contextPath
        self.dockerfile = "Dockerfile"
        self.tag = tag
        self.buildArgs = [:]
        self.noCache = false
        self.target = nil
        self.platform = nil
    }
}

// MARK: - Exec Config

public struct ExecConfig: Codable, Sendable {
    public var containerID: String
    public var command: [String]
    public var interactive: Bool
    public var tty: Bool
    public var user: String?
    public var workdir: String?
    public var env: [String: String]
    /// One-shot stdin blob forwarded to the in-VM child process. The CLI
    /// drains its own stdin into this field when `--interactive` is set
    /// and stdin is non-TTY (a pipe, file redirection, or heredoc). The
    /// daemon writes these bytes onto the same vsock connection it used
    /// for the JSON request — the in-VM listener `dup2`'s that fd onto
    /// the child's STDIN_FILENO in the non-TTY branch so anything past
    /// the request terminator newline is consumed as stdin.
    ///
    /// Capped at 64 MiB to avoid OOM on accidental `cocker exec -i c sh`
    /// against `/dev/zero` ; anything bigger should use `cocker cp`.
    /// Empty / nil means "no stdin forwarded" (the legacy behaviour).
    public var stdin: Data?

    /// Identifies this exec on the daemon so a *second* connection can stream
    /// stdin into it while the first one streams output back.
    ///
    /// The daemon's per-connection loop can't read another frame while it is
    /// streaming a response, so live stdin can't share the request's
    /// connection without deadlocking. The CLI mints the id, opens a side
    /// channel, and the daemon routes those bytes onto the same vsock fd the
    /// guest is already relaying to the PTY master.
    public var sessionID: String?
    /// Terminal geometry for `-t`, so the PTY starts at the caller's real
    /// size instead of openpty's 80x24 default.
    public var rows: Int?
    public var cols: Int?

    public init(containerID: String, command: [String]) {
        self.containerID = containerID
        self.command = command
        self.interactive = false
        self.tty = false
        self.sessionID = nil
        self.rows = nil
        self.cols = nil
        self.user = nil
        self.workdir = nil
        self.env = [:]
        self.stdin = nil
    }
}
