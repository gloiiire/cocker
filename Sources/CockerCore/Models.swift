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
    public var cpuCount: Int
    public var memoryMB: UInt64
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var hostname: String
    public var restartPolicy: RestartPolicy
    public var healthStatus: HealthStatus

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
        healthStatus: HealthStatus = .none
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
    }
}

public enum HealthStatus: String, Codable, Sendable {
    case none, starting, healthy, unhealthy
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

public struct PortMapping: Codable, Sendable, CustomStringConvertible {
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
        let parts = s.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            guard let host = UInt16(parts[0]), let container = UInt16(parts[1]) else {
                throw CockerError.invalidPortMapping(s)
            }
            return PortMapping(hostPort: host, containerPort: container)
        } else if let port = UInt16(s) {
            return PortMapping(hostPort: port, containerPort: port)
        }
        throw CockerError.invalidPortMapping(s)
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

    public var reference: String { "\(repository):\(tag)" }

    public init(
        id: String,
        repository: String,
        tag: String = "latest",
        size: UInt64 = 0,
        createdAt: Date = Date(),
        architecture: String = "arm64",
        os: String = "linux",
        layers: [String] = []
    ) {
        self.id = id
        self.repository = repository
        self.tag = tag
        self.size = size
        self.createdAt = createdAt
        self.architecture = architecture
        self.os = os
        self.layers = layers
    }
}

// MARK: - Network

public struct NetworkInfo: Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var driver: NetworkDriver
    public var subnet: String
    public var gateway: String
    public var containers: [String]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString.prefix(12).lowercased(),
        name: String,
        driver: NetworkDriver = .bridge,
        subnet: String = "172.20.0.0/16",
        gateway: String = "172.20.0.1",
        containers: [String] = []
    ) {
        self.id = String(id.prefix(12))
        self.name = name
        self.driver = driver
        self.subnet = subnet
        self.gateway = gateway
        self.containers = containers
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

    public init(
        id: String = UUID().uuidString.prefix(12).lowercased(),
        name: String,
        mountpoint: String = "",
        driver: String = "local",
        labels: [String: String] = [:]
    ) {
        self.id = String(id.prefix(12))
        self.name = name
        self.driver = driver
        self.labels = labels
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
    public var addHosts: [String]
    public var dnsServers: [String]
    public var dnsSearch: [String]
    public var volumesFrom: [String]
    public var tmpfsMounts: [String]
    public var readOnly: Bool

    public init(image: String, command: [String] = []) {
        self.image = image
        self.command = command
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
        self.addHosts = []
        self.dnsServers = []
        self.dnsSearch = []
        self.volumesFrom = []
        self.tmpfsMounts = []
        self.readOnly = false
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

    public init(containerID: String, command: [String]) {
        self.containerID = containerID
        self.command = command
        self.interactive = false
        self.tty = false
        self.user = nil
        self.workdir = nil
        self.env = [:]
    }
}
