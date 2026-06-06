import Foundation

// OCI Image Manifest Specification v1.1 + Docker v2 manifest format

public struct OCIManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let mediaType: String?
    public let config: OCIDescriptor
    public let layers: [OCIDescriptor]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, mediaType, config, layers
    }

    public init(schemaVersion: Int, mediaType: String?, config: OCIDescriptor, layers: [OCIDescriptor]) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.config = config
        self.layers = layers
    }
}

public struct OCIIndex: Codable, Sendable {
    public let schemaVersion: Int
    public let mediaType: String?
    public let manifests: [OCIManifestDescriptor]
}

public struct OCIManifestDescriptor: Codable, Sendable {
    public let mediaType: String
    public let digest: String
    public let size: Int
    public let platform: OCIPlatform?
    public let annotations: [String: String]?
}

public struct OCIDescriptor: Codable, Sendable {
    public let mediaType: String
    public let digest: String
    public let size: Int
    public let urls: [String]?

    public init(mediaType: String, digest: String, size: Int, urls: [String]?) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.urls = urls
    }

    public var isGzipLayer: Bool {
        mediaType.contains("gzip") || mediaType.contains("tar+gzip")
    }

    public var isZstdLayer: Bool {
        mediaType.contains("zstd")
    }
}

public struct OCIPlatform: Codable, Sendable {
    public let architecture: String
    public let os: String
    public let variant: String?
    public let osVersion: String?

    enum CodingKeys: String, CodingKey {
        case architecture, os, variant
        case osVersion = "os.version"
    }
}

public struct OCIImageConfig: Codable, Sendable {
    public let architecture: String?
    public let os: String?
    public let config: ContainerConfig?
    public let rootfs: RootFS?
    public let history: [LayerHistory]?

    public init(architecture: String?, os: String?, config: ContainerConfig?, rootfs: RootFS?, history: [LayerHistory]?) {
        self.architecture = architecture
        self.os = os
        self.config = config
        self.rootfs = rootfs
        self.history = history
    }

    public struct ContainerConfig: Codable, Sendable {
        public let user: String?
        public let exposedPorts: [String: Empty]?
        public let env: [String]?
        public let cmd: [String]?
        public let entrypoint: [String]?
        public let workingDir: String?
        public let labels: [String: String]?
        public let stopSignal: String?
        public let volumes: [String: Empty]?

        enum CodingKeys: String, CodingKey {
            case user = "User"
            case exposedPorts = "ExposedPorts"
            case env = "Env"
            case cmd = "Cmd"
            case entrypoint = "Entrypoint"
            case workingDir = "WorkingDir"
            case labels = "Labels"
            case stopSignal = "StopSignal"
            case volumes = "Volumes"
        }

        public init(user: String?, exposedPorts: [String: Empty]?, env: [String]?, cmd: [String]?,
                    entrypoint: [String]?, workingDir: String?, labels: [String: String]?,
                    stopSignal: String?, volumes: [String: Empty]?) {
            self.user = user
            self.exposedPorts = exposedPorts
            self.env = env
            self.cmd = cmd
            self.entrypoint = entrypoint
            self.workingDir = workingDir
            self.labels = labels
            self.stopSignal = stopSignal
            self.volumes = volumes
        }
    }

    public struct RootFS: Codable, Sendable {
        public let type: String
        public let diffIDs: [String]

        enum CodingKeys: String, CodingKey {
            case type
            case diffIDs = "diff_ids"
        }

        public init(type: String, diffIDs: [String]) {
            self.type = type
            self.diffIDs = diffIDs
        }
    }

    public struct LayerHistory: Codable, Sendable {
        public let created: String?
        public let createdBy: String?
        public let emptyLayer: Bool?
        public let comment: String?

        enum CodingKeys: String, CodingKey {
            case created, comment
            case createdBy = "created_by"
            case emptyLayer = "empty_layer"
        }

        public init(created: String?, createdBy: String?, emptyLayer: Bool?, comment: String?) {
            self.created = created
            self.createdBy = createdBy
            self.emptyLayer = emptyLayer
            self.comment = comment
        }
    }

    public struct Empty: Codable, Sendable {
        public init() {}
    }
}

// MARK: - Image reference parsing

public struct ImageReference: Sendable {
    public let registry: String
    public let repository: String
    public let tag: String
    public let digest: String?

    public var pullURL: String {
        "\(registry)/v2/\(repository)"
    }

    public var fullName: String {
        let base = "\(registry)/\(repository)"
        if let d = digest { return "\(base)@\(d)" }
        return "\(base):\(tag)"
    }

    public var shortName: String {
        if registry == "registry-1.docker.io" || registry == "docker.io" {
            if repository.hasPrefix("library/") {
                return "\(repository.dropFirst("library/".count)):\(tag)"
            }
            return "\(repository):\(tag)"
        }
        return "\(registry)/\(repository):\(tag)"
    }

    public static func parse(_ reference: String) throws -> ImageReference {
        // Handle digest references
        var ref = reference
        var digest: String? = nil

        if let atIdx = ref.lastIndex(of: "@") {
            digest = String(ref[ref.index(after: atIdx)...])
            ref = String(ref[..<atIdx])
        }

        // Split tag
        var tag = "latest"
        let parts = ref.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            ref = String(parts[0])
            tag = String(parts[1])
        }

        // Detect registry vs repository
        let segments = ref.split(separator: "/").map(String.init)

        var registry = "registry-1.docker.io"
        var repository = ""

        if segments.count == 1 {
            repository = "library/\(segments[0])"
        } else if segments.count == 2 {
            let first = segments[0]
            if first.contains(".") || first.contains(":") || first == "localhost" {
                registry = first
                repository = segments[1]
            } else {
                repository = ref
            }
        } else {
            let first = segments[0]
            if first.contains(".") || first.contains(":") || first == "localhost" {
                registry = first
                repository = segments.dropFirst().joined(separator: "/")
            } else {
                repository = segments.joined(separator: "/")
            }
        }

        return ImageReference(
            registry: registry,
            repository: repository,
            tag: tag,
            digest: digest
        )
    }
}

// MARK: - Media types

public enum MediaType {
    public static let manifestV2 = "application/vnd.docker.distribution.manifest.v2+json"
    public static let manifestListV2 = "application/vnd.docker.distribution.manifest.list.v2+json"
    public static let ociManifest = "application/vnd.oci.image.manifest.v1+json"
    public static let ociIndex = "application/vnd.oci.image.index.v1+json"
    public static let layerGzip = "application/vnd.docker.image.rootfs.diff.tar.gzip"
    public static let layerZstd = "application/vnd.oci.image.layer.v1.tar+zstd"
    public static let ociLayerGzip = "application/vnd.oci.image.layer.v1.tar+gzip"
    public static let imageConfig = "application/vnd.docker.container.image.v1+json"
    public static let ociConfig = "application/vnd.oci.image.config.v1+json"
}
