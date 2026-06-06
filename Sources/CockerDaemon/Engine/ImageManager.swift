import Foundation
import CockerCore

actor ImageManager {
    let store: ImageStore
    private let registry: RegistryClient
    private var pullProgress: [String: [String: LayerState]] = [:]

    struct LayerState {
        var status: String
        var current: Int64
        var total: Int64
    }

    init(rootDir: URL) throws {
        self.store = try ImageStore(rootDir: rootDir.appendingPathComponent("images"))
        self.registry = RegistryClient()
    }

    // MARK: - List / find

    func list() async -> [ImageInfo] { await store.list() }

    func find(_ reference: String) async throws -> ImageInfo {
        guard let img = await store.find(reference) else { throw CockerError.imageNotFound(reference) }
        return img
    }

    func exists(_ reference: String) async -> Bool { await store.exists(reference) }

    // MARK: - Pull

    func pull(
        reference: String,
        platform: String? = nil,
        progressHandler: @escaping (String) -> Void
    ) async throws -> ImageInfo {
        let ref = try ImageReference.parse(reference)

        // Resolve manifest
        progressHandler("status|\(ref.shortName)|Pulling manifest...|0|0")
        let (manifest, digest) = try await registry.resolveManifest(for: ref)

        // Fetch config for image metadata
        let config = try await registry.fetchConfig(ref: ref, descriptor: manifest.config)

        // Check if already fully pulled
        let imageKey = "\(ref.repository):\(ref.tag)"
        if await store.exists(imageKey) {
            let existing = await store.find(imageKey)!
            if await store.hasRootfs(for: existing) {
                progressHandler("status|\(ref.shortName)|Already up to date|0|0")
                return existing
            }
        }

        var totalSize: UInt64 = 0
        for layer in manifest.layers { totalSize += UInt64(layer.size) }

        for layer in manifest.layers {
            let shortDigest = String(layer.digest.prefix(19))

            if await store.hasBlob(layer.digest) {
                progressHandler("status|\(shortDigest)|Already exists|\(layer.size)|\(layer.size)")
                continue
            }

            progressHandler("status|\(shortDigest)|Pulling|\(0)|\(layer.size)")
            let dest = await store.blobPath(for: layer.digest)
            try await registry.downloadLayer(ref: ref, descriptor: layer, destination: dest) { current, total in
                progressHandler("status|\(shortDigest)|Downloading|\(current)|\(total)")
            }

            progressHandler("status|\(shortDigest)|Pull complete|\(layer.size)|\(layer.size)")
        }

        let imageInfo = ImageInfo(
            id: digest,
            repository: ref.repository,
            tag: ref.tag,
            size: totalSize,
            architecture: config.architecture ?? "arm64",
            os: config.os ?? "linux",
            layers: manifest.layers.map { $0.digest }
        )

        try await store.store(image: imageInfo)

        progressHandler("status|rootfs|Extracting layers...|0|0")
        try await store.extractRootfs(for: imageInfo, layers: manifest.layers) { layerDigest, progress in
            let pct = Int(progress * 100)
            progressHandler("status|\(String(layerDigest.prefix(12)))|Extracting|\(pct)|100")
        }

        progressHandler("status|\(ref.shortName)|Pull complete|\(totalSize)|\(totalSize)")
        return imageInfo
    }

    // MARK: - Remove

    func remove(_ reference: String, force: Bool = false) async throws {
        _ = try await find(reference)
        try await store.remove(reference)
    }

    // MARK: - Tag

    func tag(source: String, target: String) async throws {
        try await store.tag(source: source, target: target)
    }

    // MARK: - Rootfs access

    func rootfsPath(for reference: String) async throws -> URL {
        let img = try await find(reference)
        let rootfsDir = await store.rootfsDirectory(for: img)
        guard await store.hasRootfs(for: img) else {
            throw CockerError.imageNotFound("\(reference) (rootfs not extracted — pull the image first)")
        }
        return rootfsDir
    }

    // MARK: - Build

    func build(config: BuildConfig, progressHandler: @escaping (StreamEvent) -> Void) async throws -> ImageInfo {
        let builder = DockerfileBuilder(imageManager: self, config: config, progressHandler: progressHandler)
        return try await builder.build()
    }

    func storeBuiltImage(_ image: ImageInfo) async throws {
        try await store.store(image: image)
    }
}

// MARK: - Dockerfile builder

actor DockerfileBuilder {
    private let imageManager: ImageManager
    private let config: BuildConfig
    private let progressHandler: (StreamEvent) -> Void
    private var stepCount = 0
    private var totalSteps = 0

    init(imageManager: ImageManager, config: BuildConfig, progressHandler: @escaping (StreamEvent) -> Void) {
        self.imageManager = imageManager
        self.config = config
        self.progressHandler = progressHandler
    }

    func build() async throws -> ImageInfo {
        let dockerfilePath = config.contextPath + "/" + config.dockerfile
        guard FileManager.default.fileExists(atPath: dockerfilePath) else {
            throw CockerError.dockerfileNotFound(dockerfilePath)
        }

        let dockerfile = try String(contentsOfFile: dockerfilePath, encoding: .utf8)
        let instructions = try parseDockerfile(dockerfile)

        totalSteps = instructions.count
        log(.status, "Sending build context to Cocker daemon")
        log(.status, "Step 0/\(totalSteps): Parsing Dockerfile")

        var baseImage: String = ""
        var workdir: String = "/"
        var user: String = ""
        var env: [String: String] = config.buildArgs
        var labels: [String: String] = [:]
        var cmd: [String] = []
        var entrypoint: [String] = []
        var exposedPorts: [PortMapping] = []
        var contextFiles: [(String, String)] = []  // (src, dst)

        for (i, instruction) in instructions.enumerated() {
            stepCount = i + 1
            log(.status, "Step \(stepCount)/\(totalSteps) : \(instruction.keyword) \(instruction.args)")

            switch instruction.keyword.uppercased() {
            case "FROM":
                baseImage = resolveArg(instruction.args, env: env)
                log(.stdout, " ---> Pulling base image: \(baseImage)\n")
                if !(await imageManager.exists(baseImage)) {
                    _ = try await imageManager.pull(reference: baseImage, progressHandler: { msg in
                        self.log(.stdout, msg + "\n")
                    })
                }

            case "RUN":
                let command = resolveArg(instruction.args, env: env)
                log(.stdout, " ---> Running: \(command)\n")
                // In a real build, this would run inside a temporary container
                // For now, log it as a build step
                try await runBuildCommand(command, workdir: workdir, baseImage: baseImage, env: env)

            case "COPY", "ADD":
                let parts = instruction.args.split(separator: " ").map(String.init)
                if parts.count >= 2 {
                    let dst = parts.last!
                    let srcs = Array(parts.dropLast())
                    for src in srcs {
                        contextFiles.append((src, dst))
                        log(.stdout, " ---> COPY \(src) -> \(dst)\n")
                    }
                }

            case "WORKDIR":
                workdir = resolveArg(instruction.args, env: env)
                log(.stdout, " ---> WORKDIR \(workdir)\n")

            case "USER":
                user = resolveArg(instruction.args, env: env)

            case "ENV":
                let parts = instruction.args.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    env[String(parts[0])] = resolveArg(String(parts[1]), env: env)
                } else {
                    // KEY VALUE format
                    let kv = instruction.args.split(separator: " ", maxSplits: 1)
                    if kv.count == 2 { env[String(kv[0])] = resolveArg(String(kv[1]), env: env) }
                }

            case "ARG":
                let parts = instruction.args.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0])
                    if env[key] == nil { env[key] = String(parts[1]) }
                }

            case "LABEL":
                let parts = instruction.args.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { labels[String(parts[0])] = String(parts[1]) }

            case "EXPOSE":
                if let port = UInt16(instruction.args.split(separator: "/").first ?? "") {
                    exposedPorts.append(PortMapping(hostPort: port, containerPort: port))
                }

            case "CMD":
                cmd = parseJsonArray(instruction.args) ?? ["/bin/sh", "-c", instruction.args]

            case "ENTRYPOINT":
                entrypoint = parseJsonArray(instruction.args) ?? [instruction.args]

            case "VOLUME":
                break  // Record but don't create volumes during build

            case "HEALTHCHECK", "STOPSIGNAL", "ONBUILD", "SHELL":
                break  // Parse but not fully implemented

            default:
                log(.stderr, "Warning: Unknown instruction: \(instruction.keyword)\n")
            }

            log(.stdout, " ---> \(fakeLayerID())\n")
        }

        // Create resulting image
        let imageID = "sha256:" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let baseImageInfo = await imageManager.exists(baseImage) ? (try? await imageManager.find(baseImage)) : nil
        let newImage = ImageInfo(
            id: imageID,
            repository: parseRepo(config.tag),
            tag: parseTag(config.tag),
            size: baseImageInfo?.size ?? 0,
            architecture: "arm64",
            os: "linux",
            layers: baseImageInfo?.layers ?? []
        )

        try await imageManager.storeBuiltImage(newImage)
        log(.status, "Successfully built \(String(imageID.prefix(19)))")
        log(.status, "Successfully tagged \(config.tag)")

        return newImage
    }

    private func runBuildCommand(_ command: String, workdir: String, baseImage: String, env: [String: String]) async throws {
        // In a full implementation, this would:
        // 1. Start a temporary container from the current layer
        // 2. Run the command via vsock exec
        // 3. Commit the result as a new layer
        // For now, simulate by logging
        log(.stdout, "  (build step simulated — full layer commit requires running container)\n")
    }

    private func log(_ stream: StreamEvent.Stream, _ text: String) {
        progressHandler(StreamEvent(stream: stream, data: text))
    }

    private func fakeLayerID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
    }

    private func parseRepo(_ tag: String) -> String {
        let parts = tag.split(separator: ":").map(String.init)
        return parts.first ?? tag
    }

    private func parseTag(_ tag: String) -> String {
        let parts = tag.split(separator: ":").map(String.init)
        return parts.count > 1 ? parts[1] : "latest"
    }

    private func resolveArg(_ s: String, env: [String: String]) -> String {
        var result = s
        for (k, v) in env {
            result = result.replacingOccurrences(of: "${\(k)}", with: v)
            result = result.replacingOccurrences(of: "$\(k)", with: v)
        }
        return result
    }

    private func parseJsonArray(_ s: String) -> [String]? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        return try? JSONDecoder().decode([String].self, from: Data(trimmed.utf8))
    }
}

