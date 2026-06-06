import Foundation
import CockerCore
import Crypto

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

    func rootfsDirectory(for image: ImageInfo) async -> URL {
        await store.rootfsDirectory(for: image)
    }

    func blobPath(for digest: String) async -> URL {
        await store.blobPath(for: digest)
    }

    func blobDir() async -> URL {
        await store.rootDir.appendingPathComponent("blobs/sha256")
    }

    /// Clone le rootfs d'une image vers un rootfs dédié au container (overlay
    /// via APFS clonefile). Garantit l'isolation entre containers de la même
    /// image. Voir ImageStore.cloneRootfs pour les détails.
    func cloneRootfs(for reference: String, containerID: String) async throws -> URL {
        let img = try await find(reference)
        return try await store.cloneRootfs(for: img, containerID: containerID)
    }

    /// Supprime le rootfs cloné d'un container.
    func removeContainerRootfs(containerID: String) async throws {
        try await store.removeContainerRootfs(containerID: containerID)
    }

    // MARK: - Build

    func build(config: BuildConfig, progressHandler: @escaping (StreamEvent) -> Void) async throws -> ImageInfo {
        let builder = DockerfileBuilder(imageManager: self, config: config, progressHandler: progressHandler)
        return try await builder.build()
    }

    func storeBuiltImage(_ image: ImageInfo) async throws {
        try await store.store(image: image)
    }

    // MARK: - Commit (create image from container rootfs)

    func commit(fromRootfs rootfsPath: URL, tag: String, baseImage: ImageInfo?, author: String?, message: String?) async throws -> ImageInfo {
        let blobsDir = await store.rootDir.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        // Create a tar of the rootfs
        let tmpTar = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
        defer { try? FileManager.default.removeItem(at: tmpTar) }

        let tarProc = Process()
        tarProc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProc.arguments = ["-czf", tmpTar.path, "-C", rootfsPath.path, "."]
        let errPipe = Pipe()
        tarProc.standardError = errPipe
        try tarProc.run()
        tarProc.waitUntilExit()

        let tarData = try Data(contentsOf: tmpTar)
        let tarDigest = "sha256:" + SHA256.hash(data: tarData).hexString
        let blobPath = blobsDir.appendingPathComponent(String(tarDigest.dropFirst(7)))
        if !FileManager.default.fileExists(atPath: blobPath.path) {
            try tarData.write(to: blobPath)
        }

        // Build OCI config
        let now = ISO8601DateFormatter().string(from: Date())
        let ociConfig = OCIImageConfig(
            architecture: "arm64",
            os: "linux",
            config: OCIImageConfig.ContainerConfig(
                user: nil,
                exposedPorts: nil,
                env: nil,
                cmd: nil,
                entrypoint: nil,
                workingDir: nil,
                labels: author.map { ["author": $0] },
                stopSignal: nil,
                volumes: nil
            ),
            rootfs: OCIImageConfig.RootFS(
                type: "layers",
                diffIDs: (baseImage?.layers ?? []) + [tarDigest]
            ),
            history: [OCIImageConfig.LayerHistory(
                created: now,
                createdBy: message ?? "cocker commit",
                emptyLayer: false,
                comment: author ?? ""
            )]
        )

        let configData = try JSONEncoder().encode(ociConfig)
        let configDigest = "sha256:" + SHA256.hash(data: configData).hexString
        let configPath = blobsDir.appendingPathComponent(String(configDigest.dropFirst(7)))
        try configData.write(to: configPath)

        // Build manifest
        let manifest = OCIManifest(
            schemaVersion: 2,
            mediaType: MediaType.ociManifest,
            config: OCIDescriptor(mediaType: MediaType.ociConfig, digest: configDigest, size: configData.count, urls: nil),
            layers: ((baseImage?.layers ?? []).map { d in
                OCIDescriptor(mediaType: MediaType.ociLayerGzip, digest: d, size: 0, urls: nil)
            }) + [OCIDescriptor(mediaType: MediaType.ociLayerGzip, digest: tarDigest, size: tarData.count, urls: nil)]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestDigest = "sha256:" + SHA256.hash(data: manifestData).hexString

        // Parse repo/tag
        let (repo, tagStr) = parseRepoTag(tag)
        let imageInfo = ImageInfo(
            id: manifestDigest,
            repository: repo,
            tag: tagStr,
            size: UInt64(tarData.count),
            architecture: "arm64",
            os: "linux",
            layers: (baseImage?.layers ?? []) + [tarDigest]
        )
        try await store.store(image: imageInfo)

        // Copy rootfs to store
        let destRootfs = await store.rootfsDirectory(for: imageInfo)
        if FileManager.default.fileExists(atPath: destRootfs.path) {
            try FileManager.default.removeItem(at: destRootfs)
        }
        try FileManager.default.createDirectory(at: destRootfs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: rootfsPath, to: destRootfs)

        return imageInfo
    }

    // MARK: - Import (create image from a raw filesystem tar)

    func importTar(_ tarData: Data, tag: String) async throws -> ImageInfo {
        let blobsDir = await store.rootDir.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        // Store the tar as a blob
        let tarDigest = "sha256:" + SHA256.hash(data: tarData).hexString
        let blobPath = blobsDir.appendingPathComponent(String(tarDigest.dropFirst(7)))
        if !FileManager.default.fileExists(atPath: blobPath.path) {
            try tarData.write(to: blobPath)
        }

        let (repo, tagStr) = parseRepoTag(tag)
        let imageInfo = ImageInfo(
            id: tarDigest,
            repository: repo,
            tag: tagStr,
            size: UInt64(tarData.count),
            architecture: "arm64",
            os: "linux",
            layers: [tarDigest]
        )
        try await store.store(image: imageInfo)

        // Extract rootfs
        let rootfsDir = await store.rootfsDirectory(for: imageInfo)
        try FileManager.default.createDirectory(at: rootfsDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xzf", blobPath.path, "-C", rootfsDir.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        return imageInfo
    }

    // MARK: - Export (tar of container rootfs, no OCI metadata)

    func exportRootfs(at rootfsPath: URL) async throws -> Data {
        let tmpTar = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar")
        defer { try? FileManager.default.removeItem(at: tmpTar) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-cf", tmpTar.path, "-C", rootfsPath.path, "."]
        try proc.run()
        proc.waitUntilExit()

        return try Data(contentsOf: tmpTar)
    }

    // MARK: - Helpers

    private func parseRepoTag(_ ref: String) -> (String, String) {
        let parts = ref.split(separator: ":").map(String.init)
        return (parts.first ?? ref, parts.count > 1 ? parts[1] : "latest")
    }
}

// MARK: - Dockerfile builder

actor DockerfileBuilder {
    private let imageManager: ImageManager
    private let config: BuildConfig
    private let progressHandler: (StreamEvent) -> Void
    private var stepCount = 0
    private var totalSteps = 0

    // Build state
    private var currentRootfsPath: URL?
    private var layers: [CreatedLayer] = []

    struct CreatedLayer {
        let digest: String
        let size: Int
    }

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

        // Accumulated image config
        var baseImage: String = ""
        var workdir: String = "/"
        var user: String = ""
        var env: [String: String] = config.buildArgs
        var labels: [String: String] = [:]
        var cmd: [String] = []
        var entrypoint: [String] = []
        var exposedPorts: [PortMapping] = []
        var stopSignal: String? = nil
        var volumes: [String] = []

        let blobsDir = await imageManager.blobDir()
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        // Build temp dir
        let buildDir = FileManager.default.temporaryDirectory.appendingPathComponent("cocker-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: buildDir) }

        for (i, instruction) in instructions.enumerated() {
            stepCount = i + 1
            log(.status, "Step \(stepCount)/\(totalSteps) : \(instruction.keyword) \(instruction.args)")

            switch instruction.keyword.uppercased() {
            case "FROM":
                baseImage = resolveArg(instruction.args.split(separator: " ").first.map(String.init) ?? instruction.args, env: env)
                log(.stdout, " ---> Pulling base image: \(baseImage)\n")
                if !(await imageManager.exists(baseImage)) {
                    _ = try await imageManager.pull(reference: baseImage, progressHandler: { msg in
                        self.log(.stdout, msg + "\n")
                    })
                }
                // Copy base rootfs into our working directory
                if let baseRootfs = try? await imageManager.rootfsPath(for: baseImage) {
                    let layerDir = buildDir.appendingPathComponent("rootfs")
                    if FileManager.default.fileExists(atPath: layerDir.path) {
                        try FileManager.default.removeItem(at: layerDir)
                    }
                    try FileManager.default.copyItem(at: baseRootfs, to: layerDir)
                    currentRootfsPath = layerDir
                } else {
                    // FROM scratch — empty rootfs
                    let layerDir = buildDir.appendingPathComponent("rootfs")
                    try FileManager.default.createDirectory(at: layerDir, withIntermediateDirectories: true)
                    currentRootfsPath = layerDir
                }
                // Inherit base image layers
                if let baseInfo = try? await imageManager.find(baseImage) {
                    layers = baseInfo.layers.map { CreatedLayer(digest: $0, size: 0) }
                    // Inherit config from base image
                    // (we will override as we process more instructions)
                }
                log(.stdout, " ---> \(shortID())\n")

            case "RUN":
                let command = resolveArg(instruction.args, env: env)
                log(.stdout, " ---> Running: \(command)\n")
                if let rootfs = currentRootfsPath {
                    try await runBuildCommand(command, workdir: workdir, baseImage: baseImage, env: env, rootfsPath: rootfs)
                } else {
                    log(.stderr, "Warning: RUN before FROM — skipping\n")
                }
                log(.stdout, " ---> \(shortID())\n")

            case "COPY", "ADD":
                guard let rootfs = currentRootfsPath else {
                    log(.stderr, "Error: COPY before FROM\n"); continue
                }
                let before = try snapshotFiles(at: rootfs)
                let rawArgs = instruction.args

                // Strip --from=xxx flag if present
                var effectiveArgs = rawArgs
                if rawArgs.hasPrefix("--") {
                    let spaceIdx = rawArgs.firstIndex(of: " ") ?? rawArgs.endIndex
                    effectiveArgs = String(rawArgs[rawArgs.index(after: spaceIdx)...])
                }

                let parts = splitArgs(effectiveArgs)
                guard parts.count >= 2 else {
                    log(.stderr, "Warning: COPY/ADD needs at least src and dst\n"); continue
                }
                let dst = parts.last!
                let srcs = Array(parts.dropLast())

                for src in srcs {
                    let srcURL = URL(fileURLWithPath: config.contextPath).appendingPathComponent(src)
                    // Resolve dst — if dst ends with / it's a dir target
                    let dstPath: String
                    if dst.hasSuffix("/") {
                        dstPath = dst + srcURL.lastPathComponent
                    } else {
                        dstPath = dst
                    }
                    let absWorkdir = rootfs.appendingPathComponent(workdir.hasPrefix("/") ? String(workdir.dropFirst()) : workdir)
                    let dstURL: URL
                    if dstPath.hasPrefix("/") {
                        dstURL = rootfs.appendingPathComponent(String(dstPath.dropFirst()))
                    } else {
                        dstURL = absWorkdir.appendingPathComponent(dstPath)
                    }

                    try FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: srcURL.path) {
                        if FileManager.default.fileExists(atPath: dstURL.path) {
                            try FileManager.default.removeItem(at: dstURL)
                        }
                        try FileManager.default.copyItem(at: srcURL, to: dstURL)
                        log(.stdout, " ---> COPY \(src) -> \(dstPath)\n")
                    } else {
                        log(.stderr, "Warning: source \(src) not found in build context\n")
                    }
                }

                let after = try snapshotFiles(at: rootfs)
                let (changed, deleted) = diff(before: before, after: after)
                if !changed.isEmpty || !deleted.isEmpty {
                    if let layer = try? await createLayer(from: rootfs, changedPaths: changed, deletedPaths: deleted, blobsDir: blobsDir) {
                        layers.append(layer)
                        log(.stdout, " ---> Created layer \(String(layer.digest.prefix(19))) (\(formatBytes(UInt64(layer.size))))\n")
                    }
                }
                log(.stdout, " ---> \(shortID())\n")

            case "WORKDIR":
                workdir = resolveArg(instruction.args, env: env)
                // Create the directory in rootfs
                if let rootfs = currentRootfsPath {
                    let dirPath = rootfs.appendingPathComponent(workdir.hasPrefix("/") ? String(workdir.dropFirst()) : workdir)
                    try? FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
                }
                log(.stdout, " ---> WORKDIR \(workdir)\n")
                log(.stdout, " ---> \(shortID())\n")

            case "USER":
                user = resolveArg(instruction.args, env: env)
                log(.stdout, " ---> \(shortID())\n")

            case "ENV":
                // Support KEY=VALUE and KEY VALUE formats
                let raw = instruction.args
                if let eqIdx = raw.firstIndex(of: "=") {
                    let key = String(raw[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                    let val = resolveArg(String(raw[raw.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces), env: env)
                    env[key] = val
                } else {
                    let kv = raw.split(separator: " ", maxSplits: 1)
                    if kv.count == 2 { env[String(kv[0])] = resolveArg(String(kv[1]), env: env) }
                }
                log(.stdout, " ---> \(shortID())\n")

            case "ARG":
                let parts = instruction.args.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0])
                    if env[key] == nil { env[key] = String(parts[1]) }
                }

            case "LABEL":
                let raw = instruction.args
                // Support multiple KEY=VALUE pairs
                let pairs = raw.components(separatedBy: " ").filter { !$0.isEmpty }
                for pair in pairs {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { labels[String(kv[0])] = String(kv[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                }
                log(.stdout, " ---> \(shortID())\n")

            case "EXPOSE":
                if let port = UInt16(instruction.args.split(separator: "/").first ?? "") {
                    exposedPorts.append(PortMapping(hostPort: port, containerPort: port))
                }

            case "CMD":
                cmd = parseJsonArray(instruction.args) ?? ["/bin/sh", "-c", instruction.args]
                log(.stdout, " ---> \(shortID())\n")

            case "ENTRYPOINT":
                entrypoint = parseJsonArray(instruction.args) ?? [instruction.args]
                log(.stdout, " ---> \(shortID())\n")

            case "VOLUME":
                volumes.append(instruction.args.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))

            case "STOPSIGNAL":
                stopSignal = instruction.args.trimmingCharacters(in: .whitespaces)

            case "HEALTHCHECK", "ONBUILD", "SHELL":
                break  // acknowledged but not implemented

            default:
                log(.stderr, "Warning: Unknown instruction: \(instruction.keyword)\n")
            }
        }

        // Determine architecture from platform config
        let arch: String
        if let plat = config.platform {
            arch = plat.contains("amd64") ? "amd64" : "arm64"
        } else {
            arch = "arm64"
        }

        // Build OCI image config
        let ociConfig = OCIImageConfig(
            architecture: arch,
            os: "linux",
            config: OCIImageConfig.ContainerConfig(
                user: user.isEmpty ? nil : user,
                exposedPorts: exposedPorts.isEmpty ? nil : Dictionary(
                    uniqueKeysWithValues: exposedPorts.map { ("\($0.containerPort)/\($0.proto.rawValue)", OCIImageConfig.Empty()) }
                ),
                env: env.isEmpty ? nil : env.map { "\($0.key)=\($0.value)" }.sorted(),
                cmd: cmd.isEmpty ? nil : cmd,
                entrypoint: entrypoint.isEmpty ? nil : entrypoint,
                workingDir: (workdir.isEmpty || workdir == "/") ? nil : workdir,
                labels: labels.isEmpty ? nil : labels,
                stopSignal: stopSignal,
                volumes: volumes.isEmpty ? nil : Dictionary(uniqueKeysWithValues: volumes.map { ($0, OCIImageConfig.Empty()) })
            ),
            rootfs: OCIImageConfig.RootFS(
                type: "layers",
                diffIDs: layers.map { $0.digest }
            ),
            history: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configData = try encoder.encode(ociConfig)
        let configDigest = "sha256:" + SHA256.hash(data: configData).hexString
        let configBlobPath = blobsDir.appendingPathComponent(String(configDigest.dropFirst(7)))
        try configData.write(to: configBlobPath)

        // Build OCI manifest
        let manifest = OCIManifest(
            schemaVersion: 2,
            mediaType: MediaType.ociManifest,
            config: OCIDescriptor(mediaType: MediaType.ociConfig, digest: configDigest, size: configData.count, urls: nil),
            layers: layers.map { layer in
                OCIDescriptor(mediaType: MediaType.ociLayerGzip, digest: layer.digest, size: layer.size, urls: nil)
            }
        )
        let manifestData = try encoder.encode(manifest)
        let manifestDigest = "sha256:" + SHA256.hash(data: manifestData).hexString

        let totalSize = layers.reduce(UInt64(0)) { $0 + UInt64($1.size) }

        let imageInfo = ImageInfo(
            id: manifestDigest,
            repository: parseRepo(config.tag),
            tag: parseTag(config.tag),
            size: totalSize,
            architecture: arch,
            os: "linux",
            layers: layers.map { $0.digest }
        )

        try await imageManager.storeBuiltImage(imageInfo)

        // Move rootfs to the image store location
        if let rootfs = currentRootfsPath {
            let finalRootfs = await imageManager.rootfsDirectory(for: imageInfo)
            try FileManager.default.createDirectory(at: finalRootfs.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: finalRootfs.path) {
                try FileManager.default.removeItem(at: finalRootfs)
            }
            try FileManager.default.copyItem(at: rootfs, to: finalRootfs)
        }

        log(.status, "Successfully built \(String(manifestDigest.prefix(19)))")
        log(.status, "Successfully tagged \(config.tag)")

        return imageInfo
    }

    // MARK: - RUN command execution

    private func runBuildCommand(
        _ command: String,
        workdir: String,
        baseImage: String,
        env: [String: String],
        rootfsPath: URL
    ) async throws {
        // Essai 1 : si le kernel est dispo, utiliser un vrai container VM
        // (futur — pour l'instant, passer à l'essai 2)

        // Essai 2 : exécuter via /bin/sh macOS dans le rootfs avec sandbox
        // Attention : les binaires Linux ELF ne tourneront pas, mais les commandes
        // qui manipulent juste des fichiers fonctionneront
        let actualWorkdirPath = rootfsPath.appendingPathComponent(workdir.hasPrefix("/") ? String(workdir.dropFirst()) : workdir).path

        let shell = "/bin/sh"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-c", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: actualWorkdirPath) ? actualWorkdirPath : rootfsPath.path)

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        environment["ROOT"] = rootfsPath.path
        proc.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()

            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if !out.isEmpty { log(.stdout, out) }
            if !err.isEmpty { log(.stderr, err) }

            if proc.terminationStatus != 0 {
                log(.stderr, "Warning: RUN exited with code \(proc.terminationStatus) (Linux binaries may not work on macOS without kernel)\n")
                // Ne pas throw — on continue le build même si la commande échoue partiellement
            }
        } catch {
            log(.stderr, "Warning: Cannot execute RUN on macOS host: \(error.localizedDescription)\n")
            log(.stderr, "Tip: Run `cockerd setup` to install the Linux kernel and enable full RUN support\n")
        }
    }

    // MARK: - Layer creation

    private func createLayer(
        from rootfs: URL,
        changedPaths: [String],
        deletedPaths: [String],
        blobsDir: URL
    ) async throws -> CreatedLayer {
        let tmpTar = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
        defer { try? FileManager.default.removeItem(at: tmpTar) }

        var tarArgs = ["-czf", tmpTar.path, "-C", rootfs.path]
        tarArgs += changedPaths.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }

        // Add whiteout files for deleted paths (write .wh. files to a temp dir)
        let whiteoutDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: whiteoutDir) }

        if !deletedPaths.isEmpty {
            try FileManager.default.createDirectory(at: whiteoutDir, withIntermediateDirectories: true)
            for deleted in deletedPaths {
                let rel = deleted.hasPrefix("/") ? String(deleted.dropFirst()) : deleted
                let dir = whiteoutDir.appendingPathComponent((rel as NSString).deletingLastPathComponent)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let filename = ".wh." + (rel as NSString).lastPathComponent
                let whPath = dir.appendingPathComponent(filename)
                FileManager.default.createFile(atPath: whPath.path, contents: nil)
            }
        }

        if changedPaths.isEmpty && deletedPaths.isEmpty {
            // No changes — return a dummy digest
            let emptyData = Data()
            let digest = "sha256:" + SHA256.hash(data: emptyData).hexString
            return CreatedLayer(digest: digest, size: 0)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = tarArgs
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CockerError.buildFailed("tar failed: \(errMsg)")
        }

        let tarData = try Data(contentsOf: tmpTar)
        let digest = "sha256:" + SHA256.hash(data: tarData).hexString
        let blobPath = blobsDir.appendingPathComponent(String(digest.dropFirst(7)))
        if !FileManager.default.fileExists(atPath: blobPath.path) {
            try tarData.write(to: blobPath)
        }

        return CreatedLayer(digest: digest, size: tarData.count)
    }

    // MARK: - Filesystem snapshot / diff

    private func snapshotFiles(at directory: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return snapshot }

        for case let url as URL in enumerator {
            let rel = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            if rel.isEmpty || rel == directory.path { continue }
            // Hash file contents
            if let data = try? Data(contentsOf: url) {
                snapshot[rel] = Data(SHA256.hash(data: data))
            } else {
                // Directory or symlink — use path as sentinel
                snapshot[rel] = Data(rel.utf8)
            }
        }
        return snapshot
    }

    private func diff(before: [String: Data], after: [String: Data]) -> (changed: [String], deleted: [String]) {
        let changed = after.filter { key, hash in before[key] != hash }.map { "/" + $0.key }
        let deleted = before.keys.filter { after[$0] == nil }.map { "/" + $0 }
        return (changed, deleted)
    }

    // MARK: - Helpers

    private func splitArgs(_ s: String) -> [String] {
        // Split on spaces, respecting quoted strings
        var result: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        for ch in s {
            if inQuote {
                if ch == quoteChar { inQuote = false }
                else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                inQuote = true; quoteChar = ch
            } else if ch == " " {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func log(_ stream: StreamEvent.Stream, _ text: String) {
        progressHandler(StreamEvent(stream: stream, data: text))
    }

    private func shortID() -> String {
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

// MARK: - Hex helpers

extension Digest {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Byte formatter (available in Daemon module)

private func formatBytes(_ bytes: UInt64) -> String {
    let kb = Double(bytes) / 1024
    let mb = kb / 1024
    let gb = mb / 1024
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    if mb >= 1 { return String(format: "%.2f MB", mb) }
    if kb >= 1 { return String(format: "%.2f KB", kb) }
    return "\(bytes) B"
}
