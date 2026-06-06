import Foundation
import CockerCore

// Docker Engine API v1.47 response types
// These must match Docker's exact JSON format for docker-compose compatibility

// MARK: - Version

struct DockerVersion: Encodable {
    let Platform = DockerPlatform()
    let Components = [DockerComponent]()
    let Version = CockerVersion.version
    let ApiVersion = "1.47"
    let MinAPIVersion = "1.24"
    let GitCommit = "cocker-\(CockerVersion.version)"
    let GoVersion = "swift-6.2"
    let Os = "linux"
    let Arch = "arm64"
    let KernelVersion: String
    let BuildTime = CockerVersion.buildTime

    struct DockerPlatform: Encodable { let Name = "Cocker Engine" }
    struct DockerComponent: Encodable {
        let Name = "Engine"; let Version = CockerVersion.version; let Details = [String: String]()
    }
}

// MARK: - Info

struct DockerInfo: Encodable {
    let ID: String
    let Containers: Int
    let ContainersRunning: Int
    let ContainersPaused: Int
    let ContainersStopped: Int
    let Images: Int
    let Driver = "virtiofs"
    let MemoryLimit = true
    let SwapLimit = false
    let KernelMemory = false
    let CpuCfsPeriod = true
    let CpuCfsQuota = true
    let CPUShares = true
    let CPUSet = true
    let IPv4Forwarding = true
    let BridgeNfIptables = true
    let BridgeNfIp6tables = true
    let Debug = false
    let OomKillDisable = false
    let NGoroutines = 4
    let LoggingDriver = "json-file"
    let CgroupDriver = "none"
    let DockerRootDir: String
    let HttpProxy = ""
    let HttpsProxy = ""
    let NoProxy = ""
    let Name: String
    let ServerVersion = CockerVersion.version
    let OperatingSystem = "macOS"
    let OSType = "linux"
    let Architecture = "aarch64"
    let NCPU: Int
    let MemTotal: Int
    let IndexServerAddress = "https://index.docker.io/v1/"
    let Warnings: [String]
    let SecurityOptions: [String]
}

// MARK: - Container list (GET /containers/json)

struct DockerContainerSummary: Encodable {
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let Command: String
    let Created: Int64
    let Ports: [DockerPort]
    let Labels: [String: String]
    let State: String
    let Status: String
    let HostConfig: HostConfigSummary
    let NetworkSettings: NetworkSettingsSummary
    let Mounts: [DockerMount]

    struct HostConfigSummary: Encodable { let NetworkMode: String }

    struct NetworkSettingsSummary: Encodable {
        let Networks: [String: DockerEndpointSettings]
    }

    struct DockerMount: Encodable {
        let mountType: String
        let Source: String
        let Destination: String
        let Mode: String
        let RW: Bool
        let Propagation: String
        enum CodingKeys: String, CodingKey {
            case mountType = "Type"; case Source; case Destination; case Mode; case RW; case Propagation
        }
    }
}

struct DockerPort: Encodable {
    let IP: String?
    let PrivatePort: UInt16
    let PublicPort: UInt16?
    let portType: String
    enum CodingKeys: String, CodingKey {
        case IP; case PrivatePort; case PublicPort; case portType = "Type"
    }
}

struct DockerEndpointSettings: Encodable {
    let IPAMConfig: String?
    let Links: String?
    let Aliases: [String]?
    let NetworkID: String
    let EndpointID: String
    let Gateway: String
    let IPAddress: String
    let IPPrefixLen: Int
    let IPv6Gateway: String
    let GlobalIPv6Address: String
    let GlobalIPv6PrefixLen: Int
    let MacAddress: String
}

// MARK: - Container inspect (GET /containers/{id}/json)

struct DockerContainerInspect: Encodable {
    let Id: String
    let Created: String
    let Path: String
    let Args: [String]
    let State: DockerContainerState
    let Image: String
    let Name: String
    let RestartCount: Int
    let HostConfig: DockerHostConfig
    let NetworkSettings: DockerNetworkSettings
    let Mounts: [DockerMountPoint]
    let Config: DockerContainerConfig
}

struct DockerContainerState: Encodable {
    let Status: String
    let Running: Bool
    let Paused: Bool
    let Restarting: Bool
    let OOMKilled: Bool
    let Dead: Bool
    let Pid: Int
    let ExitCode: Int
    let Error: String
    let StartedAt: String
    let FinishedAt: String
}

struct DockerHostConfig: Encodable {
    let Binds: [String]?
    let NetworkMode: String
    let PortBindings: [String: [DockerPortBinding]]
    let RestartPolicy: DockerRestartPolicy
    let AutoRemove: Bool
    let Memory: Int64
    let NanoCpus: Int64
    let CapAdd: [String]?
    let CapDrop: [String]?
}

struct DockerPortBinding: Encodable {
    let HostIp: String
    let HostPort: String
}

struct DockerRestartPolicy: Encodable {
    let Name: String
    let MaximumRetryCount: Int
}

struct DockerNetworkSettings: Encodable {
    let Bridge: String
    let SandboxID: String
    let HairpinMode: Bool
    let LinkLocalIPv6Address: String
    let LinkLocalIPv6PrefixLen: Int
    let Ports: [String: [DockerPortBinding]?]
    let SandboxKey: String
    let Networks: [String: DockerEndpointSettings]
    let IPAddress: String
    let IPPrefixLen: Int
    let Gateway: String
    let MacAddress: String
}

struct DockerMountPoint: Encodable {
    let mountType: String
    let Source: String
    let Destination: String
    let Mode: String
    let RW: Bool
    let Propagation: String
    let Name: String?
    let Driver: String?
    enum CodingKeys: String, CodingKey {
        case mountType = "Type"; case Source; case Destination; case Mode; case RW; case Propagation; case Name; case Driver
    }
}

struct DockerContainerConfig: Encodable {
    let Hostname: String
    let Domainname: String
    let User: String
    let AttachStdin: Bool
    let AttachStdout: Bool
    let AttachStderr: Bool
    let ExposedPorts: [String: DockerEmpty]?
    let Tty: Bool
    let OpenStdin: Bool
    let StdinOnce: Bool
    let Env: [String]
    let Cmd: [String]?
    let Image: String
    let Labels: [String: String]
    let WorkingDir: String
    let Entrypoint: [String]?
    let OnBuild: [String]?
    let NetworkDisabled: Bool
}

struct DockerEmpty: Encodable {}

// MARK: - Container create request

struct DockerContainerCreateRequest: Decodable {
    let Hostname: String?
    let Domainname: String?
    let User: String?
    let AttachStdin: Bool?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let ExposedPorts: [String: DockerEmptyDec]?
    let Tty: Bool?
    let OpenStdin: Bool?
    let Env: [String]?
    let Cmd: SingleOrArray?
    let Entrypoint: SingleOrArray?
    let Image: String
    let Labels: [String: String]?
    let WorkingDir: String?
    let NetworkDisabled: Bool?
    let StopSignal: String?
    let HostConfig: DockerHostConfigRequest?
    let NetworkingConfig: DockerNetworkingConfig?

    struct DockerEmptyDec: Decodable {}

    struct DockerHostConfigRequest: Decodable {
        let Binds: [String]?
        let PortBindings: [String: [DockerPortBindingReq]]?
        let NetworkMode: String?
        let RestartPolicy: DockerRestartPolicyReq?
        let AutoRemove: Bool?
        let Memory: Int64?
        let NanoCpus: Int64?
        let CapAdd: [String]?
        let CapDrop: [String]?
        let Dns: [String]?
        let ExtraHosts: [String]?
        let Privileged: Bool?
        let ReadonlyRootfs: Bool?
        let Mounts: [DockerMountReq]?

        struct DockerPortBindingReq: Decodable {
            let HostIp: String?
            let HostPort: String?
        }

        struct DockerRestartPolicyReq: Decodable {
            let Name: String?
            let MaximumRetryCount: Int?
        }

        struct DockerMountReq: Decodable {
            let MountType: String?
            let Source: String?
            let Target: String?
            let ReadOnly: Bool?
            enum CodingKeys: String, CodingKey {
                case MountType = "Type"; case Source; case Target; case ReadOnly
            }
        }
    }

    struct DockerNetworkingConfig: Decodable {
        let EndpointsConfig: [String: DockerEndpointConfigReq]?

        struct DockerEndpointConfigReq: Decodable {
            let IPAMConfig: DockerIPAMConfig?
            let Links: [String]?
            let Aliases: [String]?

            struct DockerIPAMConfig: Decodable {
                let IPv4Address: String?
                let IPv6Address: String?
            }
        }
    }

    // Handles both "cmd" and ["cmd", "arg"] in Dockerfile/compose
    enum SingleOrArray: Decodable {
        case string(String)
        case array([String])

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) { self = .string(s) }
            else { self = .array(try [String](from: decoder)) }
        }

        var array: [String] {
            switch self { case .string(let s): return ["/bin/sh", "-c", s]; case .array(let a): return a }
        }
    }
}

struct DockerContainerCreateResponse: Encodable {
    let Id: String
    let Warnings: [String]
}

// MARK: - Image list (GET /images/json)

struct DockerImageSummary: Encodable {
    let Id: String
    let ParentId: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: Int64
    let Size: Int64
    let SharedSize: Int64
    let VirtualSize: Int64
    let Labels: [String: String]
    let Containers: Int
}

// MARK: - Image pull progress

struct DockerProgressDetail: Encodable {
    let current: Int64?
    let total: Int64?
}

struct DockerPullStatus: Encodable {
    let status: String
    let progressDetail: DockerProgressDetail
    let id: String?
    let progress: String?
}

// MARK: - Network (GET /networks)

struct DockerNetworkResource: Encodable {
    let Name: String
    let Id: String
    let Created: String
    let Scope: String
    let Driver: String
    let EnableIPv6: Bool
    let IPAM: DockerIPAM
    let Internal: Bool
    let Attachable: Bool
    let Ingress: Bool
    let Containers: [String: DockerNetworkContainer]
    let Options: [String: String]
    let Labels: [String: String]

    struct DockerIPAM: Encodable {
        let Driver: String
        let Config: [DockerIPAMConfig]
        let Options: [String: String]

        struct DockerIPAMConfig: Encodable {
            let Subnet: String
            let Gateway: String
        }
    }

    struct DockerNetworkContainer: Encodable {
        let Name: String
        let EndpointID: String
        let MacAddress: String
        let IPv4Address: String
        let IPv6Address: String
    }
}

struct DockerNetworkCreateRequest: Decodable {
    let Name: String
    let CheckDuplicate: Bool?
    let Driver: String?
    let Internal: Bool?
    let Attachable: Bool?
    let Ingress: Bool?
    let IPAM: DockerIPAMReq?
    let EnableIPv6: Bool?
    let Options: [String: String]?
    let Labels: [String: String]?

    struct DockerIPAMReq: Decodable {
        let Driver: String?
        let Config: [DockerIPAMConfigReq]?
        struct DockerIPAMConfigReq: Decodable {
            let Subnet: String?
            let Gateway: String?
            let IPRange: String?
        }
    }
}

struct DockerNetworkCreateResponse: Encodable {
    let Id: String
    let Warning: String
}

struct DockerNetworkConnectRequest: Decodable {
    let Container: String
}

// MARK: - Volume (GET /volumes)

struct DockerVolumeListResponse: Encodable {
    let Volumes: [DockerVolumeResource]
    let Warnings: [String]
}

struct DockerVolumeResource: Encodable {
    let CreatedAt: String
    let Driver: String
    let Labels: [String: String]
    let Mountpoint: String
    let Name: String
    let Options: [String: String]
    let Scope: String
}

struct DockerVolumeCreateRequest: Decodable {
    let Name: String?
    let Driver: String?
    let DriverOpts: [String: String]?
    let Labels: [String: String]?
}

// MARK: - Exec

struct DockerExecCreateRequest: Decodable {
    let AttachStdin: Bool?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let DetachKeys: String?
    let Tty: Bool?
    let Env: [String]?
    let Cmd: [String]
    let Privileged: Bool?
    let User: String?
    let WorkingDir: String?
}

struct DockerExecCreateResponse: Encodable { let Id: String }

struct DockerExecStartRequest: Decodable {
    let Detach: Bool?
    let Tty: Bool?
}

// MARK: - Error

struct DockerErrorResponse: Encodable {
    let message: String
}

// MARK: - Events

struct DockerEvent: Encodable {
    let status: String
    let id: String
    let from: String
    let eventType: String
    let Action: String
    let Actor: DockerActor
    let scope: String
    let time: Int64
    let timeNano: Int64

    enum CodingKeys: String, CodingKey {
        case status; case id; case from; case eventType = "Type"; case Action; case Actor; case scope; case time; case timeNano
    }

    struct DockerActor: Encodable {
        let ID: String
        let Attributes: [String: String]
    }
}

// MARK: - Conversion helpers: CockerCore -> Docker API types

extension DockerContainerSummary {
    init(from container: Container) {
        Id = container.id
        Names = ["/\(container.name)"]
        Image = container.image
        ImageID = "sha256:\(container.image.hashValue)"
        Command = container.command.joined(separator: " ")
        Created = Int64(container.createdAt.timeIntervalSince1970)
        Ports = container.ports.map { port in
            DockerPort(
                IP: "0.0.0.0",
                PrivatePort: port.containerPort,
                PublicPort: port.hostPort,
                portType: port.proto.rawValue
            )
        }
        Labels = container.labels
        State = container.status.dockerState
        Status = container.status.dockerStatus(startedAt: container.startedAt, exitCode: container.exitCode)
        HostConfig = HostConfigSummary(NetworkMode: container.networkMode.rawValue)
        NetworkSettings = NetworkSettingsSummary(Networks: [:])
        Mounts = container.volumes.map { vol in
            DockerMount(
                mountType: vol.source.hasPrefix("/") ? "bind" : "volume",
                Source: vol.source,
                Destination: vol.destination,
                Mode: vol.readOnly ? "ro" : "rw",
                RW: !vol.readOnly,
                Propagation: "rprivate"
            )
        }
    }
}

extension DockerImageSummary {
    init(from image: ImageInfo) {
        Id = image.id
        ParentId = ""
        RepoTags = ["\(image.repository):\(image.tag)"]
        RepoDigests = ["\(image.repository)@\(image.id)"]
        Created = Int64(image.createdAt.timeIntervalSince1970)
        Size = Int64(image.size)
        SharedSize = 0
        VirtualSize = Int64(image.size)
        Labels = [:]
        Containers = 0
    }
}

extension DockerNetworkResource {
    init(from network: NetworkInfo) {
        Name = network.name
        Id = network.id
        Created = ISO8601DateFormatter().string(from: network.createdAt)
        Scope = "local"
        Driver = network.driver.rawValue
        EnableIPv6 = false
        IPAM = DockerIPAM(
            Driver: "default",
            Config: [DockerIPAM.DockerIPAMConfig(Subnet: network.subnet, Gateway: network.gateway)],
            Options: [:]
        )
        Internal = false
        Attachable = false
        Ingress = false
        Containers = [:]
        Options = [:]
        Labels = [:]
    }
}

extension DockerVolumeResource {
    init(from volume: VolumeInfo) {
        CreatedAt = ISO8601DateFormatter().string(from: volume.createdAt)
        Driver = volume.driver
        Labels = volume.labels
        Mountpoint = volume.mountpoint
        Name = volume.name
        Options = [:]
        Scope = "local"
    }
}

extension ContainerStatus {
    var dockerState: String {
        switch self {
        case .running: return "running"
        case .stopped: return "exited"
        case .created: return "created"
        case .paused: return "paused"
        case .restarting: return "restarting"
        case .dead: return "dead"
        }
    }

    func dockerStatus(startedAt: Date?, exitCode: Int32?) -> String {
        switch self {
        case .running:
            let up = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            return "Up \(formatUptime(up))"
        case .stopped:
            return "Exited (\(exitCode ?? 0)) \(relativeExitTime(startedAt))"
        case .created: return "Created"
        case .paused: return "Up (Paused)"
        case .restarting: return "Restarting"
        case .dead: return "Dead"
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        if seconds < 3600 { return "\(seconds / 60) minutes" }
        if seconds < 86400 { return "\(seconds / 3600) hours" }
        return "\(seconds / 86400) days"
    }

    private func relativeExitTime(_ date: Date?) -> String {
        guard let d = date else { return "ago" }
        let diff = Int(Date().timeIntervalSince(d))
        if diff < 60 { return "\(diff) seconds ago" }
        if diff < 3600 { return "\(diff / 60) minutes ago" }
        return "\(diff / 3600) hours ago"
    }
}
