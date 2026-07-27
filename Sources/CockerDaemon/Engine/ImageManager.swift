import Darwin
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
            layers: manifest.layers.map { $0.digest },
            cmd: config.config?.cmd,
            entrypoint: config.config?.entrypoint,
            env: config.config?.env,
            workdir: config.config?.workingDir,
            user: config.config?.user,
            labels: config.config?.labels ?? [:],
            exposedPorts: Array(config.config?.exposedPorts?.keys ?? [:].keys),
            healthcheck: {
                guard let h = config.config?.healthcheck, let test = h.Test else { return nil }
                // OCI durations are nanoseconds (Go time.Duration). Cap at
                // sensible defaults to avoid pathological 10000s waits.
                let ns: (Int64?) -> TimeInterval? = { v in v.map { TimeInterval($0) / 1_000_000_000 } }
                return Healthcheck(
                    test: test,
                    interval: ns(h.Interval) ?? 30,
                    timeout: ns(h.Timeout) ?? 30,
                    startPeriod: ns(h.StartPeriod) ?? 0,
                    retries: h.Retries ?? 3
                )
            }(),
            stopSignal: config.config?.stopSignal
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

    // MARK: - Push

    /// Push a locally-stored image to its registry. Reconstructs the OCI
    /// manifest (and config blob if missing) from ImageInfo + on-disk
    /// layers, then delegates to RegistryClient. Built images already have
    /// their config blob on disk ; pulled images don't, so we regenerate it.
    func push(reference: String, progressHandler: @escaping (String) -> Void) async throws {
        let ref = try ImageReference.parse(reference)
        // The local index keys images by `repository:tag` (no registry
        // prefix), so a user-supplied `127.0.0.1:5555/repo:tag` won't match
        // directly. Fall back through the parsed form before giving up.
        let candidates = [reference, "\(ref.repository):\(ref.tag)"]
        var found: ImageInfo? = nil
        for c in candidates {
            if let img = try? await find(c) { found = img; break }
        }
        guard let img = found else { throw CockerError.imageNotFound(reference) }
        progressHandler("status|\(ref.shortName)|Preparing manifest|0|0")

        // Rebuild the OCI config from ImageInfo. The digest will differ from
        // the original config IF the image was pulled (we don't keep the
        // original bytes), but the manifest we push is internally consistent.
        let ociConfig = OCIImageConfig(
            architecture: img.architecture,
            os: img.os,
            config: OCIImageConfig.ContainerConfig(
                user: nil,
                exposedPorts: img.exposedPorts.isEmpty ? nil : Dictionary(
                    uniqueKeysWithValues: img.exposedPorts.map { ($0, OCIImageConfig.Empty()) }
                ),
                env: img.env,
                cmd: img.cmd,
                entrypoint: img.entrypoint,
                workingDir: img.workdir,
                labels: img.labels.isEmpty ? nil : img.labels,
                stopSignal: nil,
                volumes: nil
            ),
            rootfs: OCIImageConfig.RootFS(type: "layers", diffIDs: img.layers),
            history: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configData = try encoder.encode(ociConfig)
        let configDigest = "sha256:" + SHA256.hash(data: configData).hexString

        // Make sure the config blob is on disk so the loader can hand it
        // back to RegistryClient.push.
        let blobsDir = await store.rootDir.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        let configBlobPath = blobsDir.appendingPathComponent(String(configDigest.dropFirst(7)))
        if !FileManager.default.fileExists(atPath: configBlobPath.path) {
            try configData.write(to: configBlobPath)
        }

        // Manifest descriptors : config + each layer.
        let layerDescriptors: [OCIDescriptor] = try img.layers.map { digest in
            let path = blobsDir.appendingPathComponent(String(digest.dropFirst(7)))
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw CockerError.layerDownloadFailed(digest, "Local blob missing — cannot push")
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            let size = (attrs[.size] as? Int) ?? 0
            return OCIDescriptor(mediaType: MediaType.ociLayerGzip, digest: digest, size: size, urls: nil)
        }
        let configDescriptor = OCIDescriptor(mediaType: MediaType.ociConfig,
                                             digest: configDigest, size: configData.count, urls: nil)
        let manifest = OCIManifest(
            schemaVersion: 2,
            mediaType: MediaType.ociManifest,
            config: configDescriptor,
            layers: layerDescriptors
        )
        let manifestData = try encoder.encode(manifest)

        // Push everything : blobs first, then manifest.
        try await registry.push(
            ref: ref,
            manifestData: manifestData,
            manifestMediaType: MediaType.ociManifest,
            blobs: [configDescriptor] + layerDescriptors,
            blobLoader: { digest in
                let path = blobsDir.appendingPathComponent(String(digest.dropFirst(7)))
                return try Data(contentsOf: path)
            },
            progress: progressHandler
        )
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

    /// The daemon's data root (the `--root` cockerd was launched with).
    /// `store.rootDir` is `<root>/images`, so its parent is the root.
    /// BuildCache uses this to place its cache next to the blobs instead
    /// of guessing from $HOME/COCKER_ROOT (which breaks non-default roots).
    func daemonRootDir() async -> URL {
        await store.rootDir.deletingLastPathComponent()
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

    func build(config: BuildConfig, vmRuntime: VMRuntime?, progressHandler: @escaping (StreamEvent) -> Void) async throws -> ImageInfo {
        let builder = DockerfileBuilder(imageManager: self, vmRuntime: vmRuntime, config: config, progressHandler: progressHandler)
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

        // Build OCI config. Preserve the base image's CMD/ENTRYPOINT/ENV/
        // WORKDIR/USER/HEALTHCHECK/EXPOSED_PORTS so a `cocker commit` of a
        // stopped container produces an image that runs the same way as
        // the base. Without this, `cocker run <committed>` would silently
        // lose the healthcheck inherited from the original FROM.
        let now = ISO8601DateFormatter().string(from: Date())
        let inheritedHealthcheck = baseImage?.healthcheck.map { hc in
            OCIImageConfig.ContainerConfig.HealthcheckSpec(
                Test: hc.test,
                Interval: Int64(hc.interval * 1_000_000_000),
                Timeout: Int64(hc.timeout * 1_000_000_000),
                StartPeriod: Int64(hc.startPeriod * 1_000_000_000),
                Retries: hc.retries
            )
        }
        let exposedPortsDict: [String: OCIImageConfig.Empty]? = {
            guard let ports = baseImage?.exposedPorts, !ports.isEmpty else { return nil }
            var dict: [String: OCIImageConfig.Empty] = [:]
            for p in ports { dict[p] = OCIImageConfig.Empty() }
            return dict
        }()
        let ociConfig = OCIImageConfig(
            architecture: "arm64",
            os: "linux",
            config: OCIImageConfig.ContainerConfig(
                user: baseImage?.user,
                exposedPorts: exposedPortsDict,
                env: baseImage?.env,
                cmd: baseImage?.cmd,
                entrypoint: baseImage?.entrypoint,
                workingDir: baseImage?.workdir,
                labels: {
                    var l = baseImage?.labels ?? [:]
                    if let a = author { l["author"] = a }
                    return l.isEmpty ? nil : l
                }(),
                stopSignal: nil,
                volumes: nil,
                healthcheck: inheritedHealthcheck
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
    private let vmRuntime: VMRuntime?  // optionnel : nil → RUN log un warning au lieu d'exécuter
    private var config: BuildConfig
    private let progressHandler: (StreamEvent) -> Void
    private var stepCount = 0
    private var totalSteps = 0
    /// When the original context lives in iCloud Drive we stage a copy
    /// under /tmp (see `build()` for the rationale) and rewrite
    /// `config.contextPath` to point at it. Kept here so we can clean up
    /// at the end of the build.
    private var stagedContextDir: URL?
    /// Patterns parsed from `.dockerignore` / `.cockerignore` at the build
    /// context root. Consulted in every COPY to filter out files Docker's
    /// build context normally excludes (node_modules, .git, etc.).
    private var ignorePatterns: [String] = []

    // Build state
    private var currentRootfsPath: URL?
    private var layers: [CreatedLayer] = []
    // Multi-stage: each FROM ... AS <name> snapshots its current rootfs URL
    // here so later stages can `COPY --from=<name> src dst`.
    private var stageRootfs: [String: URL] = [:]
    // Companion snapshot of per-stage runtime config so `FROM <stage>` can
    // inherit ENV / WORKDIR / USER / ENTRYPOINT / CMD / LABELS from the
    // parent stage. Without this, the parent stage's WORKDIR=/app and the
    // ENV that were set by its instructions would be lost the moment a
    // later stage references it. Mirrors what Docker does. PRO-43.
    private var stageConfig: [String: StageSnapshot] = [:]
    private var currentStageName: String?

    /// Frozen image-config-ish view of a stage at the moment we hand off
    /// to the next FROM. Only carries the fields a child stage needs to
    /// inherit — rootfs lives in `stageRootfs` to avoid double-bookkeeping.
    private struct StageSnapshot {
        let env: [String: String]
        let workdir: String
        let user: String
        let cmd: [String]
        let entrypoint: [String]
        let labels: [String: String]
        let exposedPorts: [PortMapping]
        let volumes: [String]
        let stopSignal: String?
        let layers: [CreatedLayer]
        let healthcheck: Healthcheck?
    }

    /// Rolling cache key for the build state at the current step. Updated
    /// after every RUN / COPY by hashing (previousKey || instruction).
    /// Layer cache hits skip the expensive RUN; misses execute and store
    /// the new state under this key.
    private var stepCacheKey: String = "init"

    struct CreatedLayer {
        let digest: String
        let size: Int
    }

    /// Per-stage default env for the build pipeline. PRO-54.
    ///
    /// Auto-injects `COREPACK_ENABLE_DOWNLOAD_PROMPT=0` so that `corepack`
    /// (which drives `pnpm` / `yarn` shims since Node 16) doesn't hang on
    /// its "! Corepack is about to download …" interactive prompt — build
    /// VMs have no TTY so that prompt would otherwise wait forever and
    /// hit the 600 s RUN timeout. The user's own `ENV` instructions are
    /// applied AFTER this default and overwrite any key they set, so a
    /// `ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=1` in the Dockerfile still
    /// wins.
    ///
    /// `nonisolated static` so it's directly unit-testable without
    /// spinning up the actor.
    nonisolated static func defaultBuildEnv(path: String) -> [String: String] {
        [
            "PATH": path,
            "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0",
        ]
    }

    init(imageManager: ImageManager, vmRuntime: VMRuntime?, config: BuildConfig, progressHandler: @escaping (StreamEvent) -> Void) {
        self.imageManager = imageManager
        self.vmRuntime = vmRuntime
        self.config = config
        self.progressHandler = progressHandler
    }

    func build() async throws -> ImageInfo {
        defer {
            if let staged = stagedContextDir {
                try? FileManager.default.removeItem(at: staged)
            }
        }
        // Cockerfile takes precedence over Dockerfile when both exist —
        // lets users keep a Docker-flavored Dockerfile for compatibility
        // with `docker build` while exposing cocker-specific tweaks
        // (init.c kernel cmdline overrides, VM resource caps, etc.) in
        // a Cockerfile. Honored only when the user didn't pick an
        // explicit file via `-f`; an explicit `--file foo` wins.
        let dockerfilePath: String
        let userPickedFile = config.dockerfile != "Dockerfile"
        if userPickedFile {
            dockerfilePath = config.contextPath + "/" + config.dockerfile
        } else {
            let cockerCandidate = config.contextPath + "/Cockerfile"
            if FileManager.default.fileExists(atPath: cockerCandidate) {
                dockerfilePath = cockerCandidate
            } else {
                dockerfilePath = config.contextPath + "/" + config.dockerfile
            }
        }
        guard FileManager.default.fileExists(atPath: dockerfilePath) else {
            throw CockerError.dockerfileNotFound(dockerfilePath)
        }

        let dockerfile = try String(contentsOfFile: dockerfilePath, encoding: .utf8)
        let instructions = try parseDockerfile(dockerfile)

        // Load .dockerignore / .cockerignore from the context root so the
        // COPY loop below can skip ignored paths the same way docker does.
        // Only the file at the context root counts — Docker doesn't merge
        // nested ones.
        ignorePatterns = Self.loadIgnoreFile(at: config.contextPath)

        totalSteps = instructions.count
        log(.status, "Sending build context to Cocker daemon")
        log(.status, "Step 0/\(totalSteps): Parsing Dockerfile")

        // When the build context lives in iCloud Drive
        // (`~/Library/Mobile Documents/com~apple~CloudDocs/`), repeated COPY
        // operations against the same files hit EDEADLK ("Resource deadlock
        // avoided") inside cockerd because iCloud's `bird` daemon serializes
        // access in a way that deadlocks with the daemon's own threads (the
        // FIRST access works ; the SECOND fails). `ditto` from a terminal
        // doesn't have this problem, so we stage the entire context to
        // `/tmp` ONCE up front with `ditto` and rewrite `config.contextPath`
        // to point at the staged copy. All subsequent COPYs read from a
        // local /tmp tree, no iCloud involvement.
        if config.contextPath.contains("/Mobile Documents/com~apple~CloudDocs/") {
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("cocker-context-\(UUID().uuidString)")
            log(.stdout, " ---> Staging iCloud build context to \(staged.lastPathComponent)\n")
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            let rsyncP = Process()
            rsyncP.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            rsyncP.arguments = ["-a", config.contextPath + "/", staged.path + "/"]
            let rsyncErr = Pipe()
            rsyncP.standardError = rsyncErr
            rsyncP.standardOutput = Pipe()
            try rsyncP.run()
            rsyncP.waitUntilExit()
            if rsyncP.terminationStatus != 0 {
                let errData = (try? rsyncErr.fileHandleForReading.readToEnd()) ?? Data()
                let msg = String(data: errData, encoding: .utf8) ?? ""
                throw CockerError.buildFailed("Failed to stage iCloud context: \(msg)")
            }
            stagedContextDir = staged
            config.contextPath = staged.path
        }

        // Accumulated image config
        var baseImage: String = ""
        var workdir: String = "/"
        var user: String = ""
        var healthcheck: Healthcheck? = nil
        // Match Docker's default container PATH so `RUN addgroup`, `apk`,
        // etc. resolve under /usr/sbin without each Dockerfile having to
        // re-declare it.
        let defaultPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        // ENV instructions only — these end up in the final image's runtime
        // env. Reset per stage.
        var env: [String: String] = Self.defaultBuildEnv(path: defaultPath)
        // Build-only variables (ARG + --build-arg). Persist across stages
        // (matches Docker), used for variable substitution, NOT persisted
        // into the final image.
        var args: [String: String] = config.buildArgs
        // resolveArg consults both ; ENV wins over ARG when they collide.
        func substEnv() -> [String: String] {
            var merged = args
            for (k, v) in env { merged[k] = v }
            return merged
        }
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
                // Persist the OUTGOING stage rootfs (if any) under its alias
                // so later `COPY --from=<alias>` can reach it.
                if let outgoingRootfs = currentRootfsPath,
                   let outgoingName = currentStageName {
                    stageRootfs[outgoingName] = outgoingRootfs
                    // PRO-43: also snapshot the per-stage runtime config so
                    // `FROM <stage>` further down can inherit it. Without
                    // this, `FROM base AS deps` would lose the base stage's
                    // ENV / WORKDIR / USER set by intermediate instructions.
                    stageConfig[outgoingName] = StageSnapshot(
                        env: env, workdir: workdir, user: user,
                        cmd: cmd, entrypoint: entrypoint, labels: labels,
                        exposedPorts: exposedPorts, volumes: volumes,
                        stopSignal: stopSignal, layers: layers,
                        healthcheck: healthcheck
                    )
                }

                // Parse `image[:tag] [AS alias]`.
                let argsParts = instruction.args.split(separator: " ").map(String.init)
                baseImage = resolveArg(argsParts.first ?? instruction.args, env: substEnv())
                var newStageName: String? = nil
                if let asIdx = argsParts.firstIndex(where: { $0.uppercased() == "AS" }),
                   asIdx + 1 < argsParts.count {
                    newStageName = argsParts[asIdx + 1]
                }

                // PRO-43: if `baseImage` matches a stage we've already
                // built in this Dockerfile, reuse its rootfs + config
                // instead of trying to pull `library/<stage>:latest` from
                // the registry (which fails with "Manifest not found" and
                // breaks every real multi-stage Dockerfile).
                if let parentRootfs = stageRootfs[baseImage] {
                    log(.stdout, " ---> Reusing stage: \(baseImage)\n")
                    let stageDirName = "rootfs-\(stageRootfs.count + 1)"
                    let layerDir = buildDir.appendingPathComponent(stageDirName)
                    if FileManager.default.fileExists(atPath: layerDir.path) {
                        try FileManager.default.removeItem(at: layerDir)
                    }
                    try FileManager.default.copyItem(at: parentRootfs, to: layerDir)
                    currentRootfsPath = layerDir
                    currentStageName = newStageName
                    // Inherit the parent stage's runtime config so the
                    // child stage sees the same WORKDIR / ENV / USER /
                    // CMD / ENTRYPOINT / labels / etc. Falls back to
                    // defaults if no snapshot exists (shouldn't happen
                    // since the parent FROM would have set one).
                    if let snap = stageConfig[baseImage] {
                        env = snap.env
                        workdir = snap.workdir
                        user = snap.user
                        cmd = snap.cmd
                        entrypoint = snap.entrypoint
                        labels = snap.labels
                        exposedPorts = snap.exposedPorts
                        volumes = snap.volumes
                        stopSignal = snap.stopSignal
                        layers = snap.layers
                        healthcheck = snap.healthcheck
                    } else {
                        layers = []
                    }
                    log(.stdout, " ---> \(shortID())\n")
                    continue
                }

                log(.stdout, " ---> Pulling base image: \(baseImage)\n")
                if !(await imageManager.exists(baseImage)) {
                    _ = try await imageManager.pull(reference: baseImage, progressHandler: { msg in
                        self.log(.stdout, msg + "\n")
                    })
                }
                // Each stage gets its own rootfs directory so the previous
                // stage's tree survives for later `--from=` lookups.
                let stageDirName = "rootfs-\(stageRootfs.count + 1)"
                let layerDir = buildDir.appendingPathComponent(stageDirName)
                if FileManager.default.fileExists(atPath: layerDir.path) {
                    try FileManager.default.removeItem(at: layerDir)
                }
                if let baseRootfs = try? await imageManager.rootfsPath(for: baseImage) {
                    try FileManager.default.copyItem(at: baseRootfs, to: layerDir)
                } else {
                    // FROM scratch — empty rootfs
                    try FileManager.default.createDirectory(at: layerDir, withIntermediateDirectories: true)
                }
                currentRootfsPath = layerDir
                currentStageName = newStageName
                // Reset per-stage layer accumulation : the final image is the
                // LAST stage, intermediate stages must not contribute layers.
                layers = []
                healthcheck = nil
                // Per-stage metadata reset (labels/env/cmd/entrypoint/workdir/user/exposed/volumes/stopSignal).
                // Without this, a builder-stage's LABEL/ENV/CMD/EXPOSE leak
                // into the final runtime image and corrupt its metadata.
                // `args` is intentionally NOT reset : build args (declared
                // before the first FROM or on the CLI) persist across stages
                // — that's Docker's documented behavior so a global
                // `ARG BUILD_VERSION` can be reused in any stage.
                labels = [:]
                cmd = []
                entrypoint = []
                exposedPorts = []
                volumes = []
                stopSignal = nil
                user = ""
                workdir = "/"
                env = Self.defaultBuildEnv(path: defaultPath)
                // Inherit base image layers + runtime config. Without
                // this a Dockerfile that only declares HEALTHCHECK / LABEL
                // would lose the parent image's CMD/ENTRYPOINT/ENV and
                // boot into "empty command in /cocker-spec".
                if let baseInfo = try? await imageManager.find(baseImage) {
                    layers = baseInfo.layers.map { CreatedLayer(digest: $0, size: 0) }
                    if let baseCmd = baseInfo.cmd { cmd = baseCmd }
                    if let baseEntry = baseInfo.entrypoint { entrypoint = baseEntry }
                    if let baseEnv = baseInfo.env {
                        for entry in baseEnv {
                            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                            if parts.count == 2 { env[parts[0]] = parts[1] }
                        }
                    }
                    if let baseWd = baseInfo.workdir { workdir = baseWd }
                    if let baseUser = baseInfo.user { user = baseUser }
                    labels = baseInfo.labels
                    healthcheck = baseInfo.healthcheck
                    // exposedPorts arrive as ["80/tcp"] — convert back.
                    exposedPorts = baseInfo.exposedPorts.compactMap { spec in
                        let parts = spec.split(separator: "/", maxSplits: 1)
                        guard let port = UInt16(parts[0]) else { return nil }
                        let proto: TransportProto = (parts.count == 2 && parts[1].lowercased() == "udp") ? .udp : .tcp
                        return PortMapping(hostPort: port, containerPort: port, proto: proto)
                    }
                }
                log(.stdout, " ---> \(shortID())\n")

            case "RUN":
                let command = resolveArg(instruction.args, env: substEnv())
                log(.stdout, " ---> Running: \(command)\n")
                guard let rootfs = currentRootfsPath else {
                    log(.stderr, "Error: RUN before FROM — skipping\n")
                    log(.stdout, " ---> \(shortID())\n")
                    continue
                }

                // Build-cache check : if a previous build with the same
                // parent state + same RUN argument string produced a
                // layer, reuse it and skip the VM round-trip. The cache
                // key is rolled forward by hashing (previousKey || step)
                // so a divergence at any step invalidates everything
                // downstream — matches docker's behaviour.
                let stepHash = self.advanceCacheKey("RUN " + command)
                let buildRoot = await imageManager.daemonRootDir()
                if config.noCache == false,
                   let cached = try await BuildCache.lookup(key: stepHash, root: buildRoot) {
                    log(.stdout, " ---> Using cache (layer \(String(cached.digest.prefix(19))))\n")
                    try await BuildCache.apply(layer: cached, to: rootfs, root: buildRoot)
                    layers.append(CreatedLayer(digest: cached.digest, size: cached.size))
                    log(.stdout, " ---> \(shortID())\n")
                    continue
                }

                if let vm = vmRuntime {
                    // Mode "vraie VM" : on lance une VM éphémère, on capture les
                    // changements filesystem, on crée un layer OCI.
                    // The platform field (e.g. "linux/amd64") tells the VM
                    // to mount the qemu-user-static share + register
                    // binfmt_misc so x86_64 RUN steps work on Apple Silicon.
                    let buildArch = config.platform.flatMap { plat in
                        plat.split(separator: "/").last.map(String.init)
                    }

                    // PRO-73 : ext4-overlay build path (now the default ;
                    // COCKER_BUILD_LEGACY=1 forces the old host-diff path).
                    // The RUN's writes land on a native ext4 overlay upper
                    // instead of straight through Apple virtiofs, which
                    // EACCESes on dpkg's mode-000 file creates and broke every
                    // `apt-get install` of a package shipping files. The guest
                    // wrapper tars the overlay upperdir (= exactly this step's
                    // changes) into the outbox share ; we read that back as the
                    // OCI layer and replay it onto the host working dir so
                    // subsequent steps see a cumulative base (host-side tar →
                    // no virtiofs, no EACCES, final modes preserved). Needs
                    // `tar`/`find` in the base image (guarded below).
                    if ProcessInfo.processInfo.environment["COCKER_BUILD_LEGACY"] == nil {
                        let outbox = buildDir.appendingPathComponent("outbox-\(UUID().uuidString.prefix(8))")
                        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
                        // The wrapper runs the RUN command, then (on success)
                        // turns the overlay upperdir into an OCI layer tarball
                        // in the outbox:
                        //  - overlayfs marks deletions with char-device 0:0
                        //    whiteouts → convert to OCI `.wh.` markers so the
                        //    tar carries no device nodes the unprivileged host
                        //    tar can't recreate, and deletions are expressed
                        //    the OCI way.
                        //  - a wholesale-replaced dir is marked opaque via the
                        //    trusted.overlay.opaque xattr → emit `.wh..wh..opq`
                        //    when getfattr is available (best-effort: images
                        //    without the attr tools skip this rare case).
                        let wrapped = command + "\n"
                            + "__cocker_rc=$?\n"
                            + "if [ \"$__cocker_rc\" -eq 0 ]; then "
                            + "find /.cocker-upper -mindepth 1 -type c 2>/dev/null | "
                            + "while IFS= read -r p; do d=${p%/*}; b=${p##*/}; "
                            + "rm -f \"$p\" && : > \"$d/.wh.$b\"; done; "
                            + "if command -v getfattr >/dev/null 2>&1; then "
                            + "find /.cocker-upper -mindepth 1 -type d 2>/dev/null | "
                            + "while IFS= read -r d; do "
                            + "getfattr -n trusted.overlay.opaque --only-values \"$d\" 2>/dev/null "
                            + "| grep -q y && : > \"$d/.wh..wh..opq\"; done; fi; "
                            + "tar czf /.cocker-outbox/layer.tar -C /.cocker-upper "
                            + "--exclude=./.cocker-upper --exclude=./.cocker-outbox --exclude=./tmp . "
                            + "2>/.cocker-outbox/tar.err || echo 'cocker: layer tar failed' >&2; "
                            + "sync; fi\n"
                            + "exit \"$__cocker_rc\"\n"
                        let result = try await vm.runEphemeral(
                            rootfsPath: rootfs,
                            command: ["/bin/sh", "-c", wrapped],
                            env: substEnv(),
                            workdir: workdir,
                            timeout: 600,
                            targetArch: buildArch,
                            buildOverlayOutbox: outbox
                        )
                        if result.exitCode != 0 {
                            try? FileManager.default.removeItem(at: outbox)
                            throw runStepFailure(command, result)
                        }
                        let blobsDir = await imageManager.blobDir()
                        let layerTar = outbox.appendingPathComponent("layer.tar")
                        // The wrapper always tars the upperdir after a
                        // successful RUN, so a missing layer.tar means the
                        // base image has no `tar` — fail loudly instead of
                        // silently dropping the step's changes. (Set
                        // COCKER_BUILD_LEGACY=1 to fall back to the host-diff
                        // path for such images.)
                        guard FileManager.default.fileExists(atPath: layerTar.path) else {
                            try? FileManager.default.removeItem(at: outbox)
                            throw CockerError.buildFailed(
                                "RUN '\(command)': could not capture the layer — the base image " +
                                "needs `tar` (and `find`) for build steps. Add it (apk add tar / " +
                                "apt-get install tar) or set COCKER_BUILD_LEGACY=1.")
                        }
                        if let layer = try await registerOverlayLayer(tar: layerTar, rootfs: rootfs, blobsDir: blobsDir) {
                            layers.append(layer)
                            try? await BuildCache.store(key: stepHash, layer: layer, root: buildRoot)
                            log(.stdout, " ---> Created layer \(String(layer.digest.prefix(19))) (ext4 overlay)\n")
                        }
                        try? FileManager.default.removeItem(at: outbox)
                    } else {
                    let before = try snapshotFiles(at: rootfs)
                    let result = try await vm.runEphemeral(
                        rootfsPath: rootfs,
                        command: ["/bin/sh", "-c", command],
                        env: substEnv(),
                        workdir: workdir,
                        timeout: 600,
                        targetArch: buildArch
                    )
                    if result.exitCode != 0 {
                        throw runStepFailure(command, result)
                    }
                    let after = try snapshotFiles(at: rootfs)
                    let changed = after.filter { key, hash in before[key] != hash }.map { $0.key }
                    let deleted = before.keys.filter { after[$0] == nil }
                    if !changed.isEmpty || !deleted.isEmpty {
                        let blobsDir = await imageManager.blobDir()
                        let layer = try await createLayer(
                            from: rootfs,
                            changedPaths: changed,
                            deletedPaths: Array(deleted),
                            blobsDir: blobsDir
                        )
                        layers.append(layer)
                        // Persist the produced layer under the rolling
                        // cache key so the next build of the same
                        // sequence skips the VM exec entirely.
                        try? await BuildCache.store(key: stepHash,
                                                     layer: layer,
                                                     root: buildRoot)
                        log(.stdout, " ---> Created layer \(String(layer.digest.prefix(19))) (\(changed.count) changed, \(deleted.count) deleted)\n")
                    }
                    }
                } else {
                    // Fallback : exec via /bin/sh macOS (commandes manipulant
                    // juste des fichiers — pas de binaires Linux ELF).
                    try await runBuildCommand(command, workdir: workdir, baseImage: baseImage, env: env, rootfsPath: rootfs)
                }
                log(.stdout, " ---> \(shortID())\n")

            case "COPY", "ADD":
                guard let rootfs = currentRootfsPath else {
                    log(.stderr, "Error: COPY before FROM\n"); continue
                }
                let before = try snapshotFiles(at: rootfs)
                let rawArgs = instruction.args

                // Parse leading flags (--from=, --chown=, --chmod=). Keep
                // --from because we need to resolve sources from a previous
                // stage instead of the build context.
                var effectiveArgs = rawArgs
                var fromStage: String? = nil
                while effectiveArgs.hasPrefix("--") {
                    let spaceIdx = effectiveArgs.firstIndex(of: " ") ?? effectiveArgs.endIndex
                    let flag = String(effectiveArgs[..<spaceIdx])
                    if flag.hasPrefix("--from=") {
                        fromStage = String(flag.dropFirst("--from=".count))
                    }
                    // Discard the flag (chown / chmod are silently ignored for now).
                    if spaceIdx == effectiveArgs.endIndex { effectiveArgs = ""; break }
                    effectiveArgs = String(effectiveArgs[effectiveArgs.index(after: spaceIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                // Where to read sources from. Three cases :
                //   1. --from=<stage>  → a prior `FROM ... AS <stage>` rootfs
                //   2. --from=<image>  → an external OCI image (pull if needed,
                //                        extract rootfs, read from there) —
                //                        e.g. `COPY --from=ghcr.io/astral-sh/uv:latest`
                //   3. no --from       → the build context directory on the host
                let sourceRoot: URL
                if let stage = fromStage, let stageDir = stageRootfs[stage] {
                    sourceRoot = stageDir
                } else if let stage = fromStage {
                    do {
                        sourceRoot = try await resolveExternalImageForCopy(stage)
                    } catch {
                        log(.stderr, "Warning: --from=\(stage) is neither a known stage nor a pullable image reference (\(error)); falling back to build context\n")
                        sourceRoot = URL(fileURLWithPath: config.contextPath)
                    }
                } else {
                    sourceRoot = URL(fileURLWithPath: config.contextPath)
                }

                let parts = splitArgs(effectiveArgs)
                guard parts.count >= 2 else {
                    log(.stderr, "Warning: COPY/ADD needs at least src and dst\n"); continue
                }
                let dst = parts.last!
                let rawSrcs = Array(parts.dropLast())

                // Dockerfile COPY supports glob patterns in source paths
                // (e.g. `COPY package*.json ./`). Expand each src against the
                // build context root using fnmatch ; non-glob srcs pass
                // through untouched. If a glob matches nothing we leave the
                // original literal in place so the "not found" warning still
                // fires for the user.
                let expanded: [String] = rawSrcs.flatMap { src -> [String] in
                    if !src.contains("*") && !src.contains("?") && !src.contains("[") {
                        return [src]
                    }
                    let matches = Self.expandGlob(src, root: sourceRoot)
                    return matches.isEmpty ? [src] : matches
                }
                // Apply .dockerignore / .cockerignore patterns only when the
                // source dir is the build context (not for `--from=<stage>`
                // copies — those obey the source stage's own filesystem).
                let applyIgnore = (fromStage == nil) && !ignorePatterns.isEmpty
                let srcs: [String] = expanded.filter { src in
                    if !applyIgnore { return true }
                    let rel = src.hasPrefix("/") ? String(src.dropFirst()) : src
                    return !Self.isIgnoredPath(rel, patterns: ignorePatterns)
                }

                for src in srcs {
                    // Strip leading "/" so the path is appended UNDER the
                    // source root rather than rebased to host /.
                    let srcRel = src.hasPrefix("/") ? String(src.dropFirst()) : src
                    let srcURL = sourceRoot.appendingPathComponent(srcRel)
                    let absWorkdir = rootfs.appendingPathComponent(workdir.hasPrefix("/") ? String(workdir.dropFirst()) : workdir)

                    // `COPY . dst/` is supposed to copy the build context's
                    // CONTENTS into dst, not the context dir itself nested
                    // under dst. Swift's URL.lastPathComponent for paths
                    // ending in "." returns "." literally, which used to
                    // make the path arithmetic below produce `dst/./` and
                    // either NOOP-loop or crash FileManager with "The file
                    // 'foo' doesn't exist." Detecting this upfront and
                    // recursing into the context for each entry is the
                    // standard Docker semantics here.
                    let isWholeContextCopy = (src == "." || src == "./")
                    let srcBasename: String? = isWholeContextCopy
                        ? nil
                        : srcURL.lastPathComponent

                    // Resolve dst to an absolute URL inside the rootfs.
                    // Dockerfile dst rules:
                    //   1. trailing `/` → directory target, append src basename
                    //   2. `.` / `..` / empty → directory target relative to WORKDIR
                    //   3. otherwise → file path (replace if exists)
                    let dstIsDir = dst.hasSuffix("/")
                        || dst == "." || dst == ".."
                        || (!dst.hasPrefix("/") && {
                            // Existing in-rootfs dir → treat as directory.
                            let probe = absWorkdir.appendingPathComponent(dst)
                            var isDir: ObjCBool = false
                            return FileManager.default.fileExists(atPath: probe.path, isDirectory: &isDir) && isDir.boolValue
                        }())
                    // When src is a whole context copy (`.` / `./`), the
                    // destination IS the directory we merge into — no
                    // basename to append.
                    let dstPath: String
                    if let basename = srcBasename, dstIsDir {
                        dstPath = dst.hasSuffix("/")
                            ? dst + basename
                            : "\(dst)/\(basename)"
                    } else {
                        dstPath = dst
                    }

                    // Normalize leading "./" so URL doesn't carry a literal
                    // "/./" segment (FileManager copyItem chokes on those —
                    // e.g. dst="./" + basename="x" → dstPath="./x" → the URL
                    // ends up as "<workdir>/./x" and the copy fails with
                    // "couldn't be copied to '.'").
                    let normalizedDst: String = {
                        if dstPath == "./" || dstPath == "." { return "" }
                        if dstPath.hasPrefix("./") { return String(dstPath.dropFirst(2)) }
                        return dstPath
                    }()
                    let dstURL: URL
                    if normalizedDst.hasPrefix("/") {
                        dstURL = rootfs.appendingPathComponent(String(normalizedDst.dropFirst()))
                    } else if normalizedDst.isEmpty {
                        dstURL = absWorkdir
                    } else {
                        dstURL = absWorkdir.appendingPathComponent(normalizedDst)
                    }

                    try FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                    if isWholeContextCopy {
                        // Iterate context entries and copy each one INTO dst.
                        // Mirrors `cp -r src/. dst/` (note the trailing dot).
                        try FileManager.default.createDirectory(at: dstURL, withIntermediateDirectories: true)
                        let rawEntries = (try? FileManager.default.contentsOfDirectory(at: srcURL, includingPropertiesForKeys: nil, options: [])) ?? []
                        // Filter out entries that match a .dockerignore /
                        // .cockerignore pattern — same filter the CLI rsync
                        // staging applies, but evaluated again here so plain
                        // `cocker build` (not via compose) and any non-iCloud
                        // build also honors the ignore file.
                        let entries: [URL] = applyIgnore
                            ? rawEntries.filter { !Self.isIgnoredPath($0.lastPathComponent, patterns: ignorePatterns) }
                            : rawEntries
                        for entry in entries {
                            let entryDst = dstURL.appendingPathComponent(entry.lastPathComponent)
                            if FileManager.default.fileExists(atPath: entryDst.path) {
                                try? FileManager.default.removeItem(at: entryDst)
                            }
                            try Self.copyTree(from: entry, to: entryDst)
                        }
                        let skipped = rawEntries.count - entries.count
                        let skipNote = skipped > 0 ? " (\(skipped) ignored)" : ""
                        log(.stdout, " ---> COPY \(src) -> \(dstPath) (\(entries.count) entries)\(skipNote)\n")
                    } else if FileManager.default.fileExists(atPath: srcURL.path) {
                        // Only remove the destination if it is an existing
                        // regular file we're about to overwrite — never a
                        // directory (would nuke unrelated files).
                        var dstIsExistingDir: ObjCBool = false
                        let exists = FileManager.default.fileExists(atPath: dstURL.path,
                                                                    isDirectory: &dstIsExistingDir)
                        if exists && !dstIsExistingDir.boolValue {
                            try FileManager.default.removeItem(at: dstURL)
                        }
                        if exists && dstIsExistingDir.boolValue {
                            // Merge into existing dir : copy contents in.
                            let merged = dstURL.appendingPathComponent(srcURL.lastPathComponent)
                            if FileManager.default.fileExists(atPath: merged.path) {
                                try FileManager.default.removeItem(at: merged)
                            }
                            try Self.copyTree(from: srcURL, to: merged)
                        } else {
                            try Self.copyTree(from: srcURL, to: dstURL)
                        }
                        // No " ---> COPY src -> dst" echo here : the "Step N/M :
                        // COPY ..." header already announced this instruction, so
                        // repeating the resolved path added a redundant line with
                        // no new information for the single-file/dir case. The
                        // multi-entry branch above keeps its echo because it also
                        // reports entry / ignored counts, which the header can't.
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
                workdir = resolveArg(instruction.args, env: substEnv())
                // Create the directory in rootfs
                if let rootfs = currentRootfsPath {
                    let dirPath = rootfs.appendingPathComponent(workdir.hasPrefix("/") ? String(workdir.dropFirst()) : workdir)
                    try? FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
                }
                log(.stdout, " ---> WORKDIR \(workdir)\n")
                log(.stdout, " ---> \(shortID())\n")

            case "USER":
                user = resolveArg(instruction.args, env: substEnv())
                log(.stdout, " ---> \(shortID())\n")

            case "ENV":
                let raw = instruction.args
                if let eqIdx = raw.firstIndex(of: "=") {
                    let key = String(raw[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                    let val = resolveArg(String(raw[raw.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces), env: substEnv())
                    env[key] = val
                } else {
                    let kv = raw.split(separator: " ", maxSplits: 1)
                    if kv.count == 2 { env[String(kv[0])] = resolveArg(String(kv[1]), env: substEnv()) }
                }
                log(.stdout, " ---> \(shortID())\n")

            case "ARG":
                let parts = instruction.args.split(separator: "=", maxSplits: 1)
                if parts.count >= 1 {
                    let key = String(parts[0])
                    // CLI --build-arg wins over the Dockerfile default.
                    if args[key] == nil {
                        args[key] = parts.count == 2 ? String(parts[1]) : ""
                    }
                }

            case "LABEL":
                // Variables (${X} / $X) must be expanded — Dockerfile spec.
                let raw = resolveArg(instruction.args, env: substEnv())
                let pairs = raw.components(separatedBy: " ").filter { !$0.isEmpty }
                for pair in pairs {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { labels[String(kv[0])] = String(kv[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                }
                log(.stdout, " ---> \(shortID())\n")

            case "EXPOSE":
                // EXPOSE accepts space-separated ports, each optionally with /tcp or /udp.
                for token in instruction.args.split(separator: " ").map(String.init) {
                    let segs = token.split(separator: "/", maxSplits: 1).map(String.init)
                    guard let port = UInt16(segs[0]) else { continue }
                    let proto: TransportProto = (segs.count == 2 && segs[1].lowercased() == "udp") ? .udp : .tcp
                    exposedPorts.append(PortMapping(hostPort: port, containerPort: port, proto: proto))
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

            case "HEALTHCHECK":
                // Dockerfile syntax:
                //   HEALTHCHECK NONE
                //   HEALTHCHECK [--interval=30s --timeout=30s --start-period=0s --retries=3] CMD <cmd...>
                //   HEALTHCHECK [...] CMD-SHELL <shell snippet>
                // We support the common shapes and the time-suffix duration
                // format ("30s", "1m", "500ms").
                let raw = resolveArg(instruction.args, env: substEnv())
                if raw.trimmingCharacters(in: .whitespaces).uppercased() == "NONE" {
                    healthcheck = Healthcheck(test: ["NONE"])
                } else {
                    var interval: TimeInterval = 30
                    var timeout: TimeInterval = 30
                    var startPeriod: TimeInterval = 0
                    var retries = 3
                    var rest = raw
                    // Strip leading --flag=value pairs.
                    while rest.hasPrefix("--") {
                        let spaceIdx = rest.firstIndex(of: " ") ?? rest.endIndex
                        let flag = String(rest[..<spaceIdx])
                        if flag.hasPrefix("--interval=") {
                            interval = parseDuration(String(flag.dropFirst("--interval=".count))) ?? interval
                        } else if flag.hasPrefix("--timeout=") {
                            timeout = parseDuration(String(flag.dropFirst("--timeout=".count))) ?? timeout
                        } else if flag.hasPrefix("--start-period=") {
                            startPeriod = parseDuration(String(flag.dropFirst("--start-period=".count))) ?? startPeriod
                        } else if flag.hasPrefix("--retries=") {
                            retries = Int(flag.dropFirst("--retries=".count)) ?? retries
                        }
                        if spaceIdx == rest.endIndex { rest = ""; break }
                        rest = String(rest[rest.index(after: spaceIdx)...])
                            .trimmingCharacters(in: .whitespaces)
                    }
                    // What's left is `CMD ...` or `CMD-SHELL ...`.
                    var test: [String] = []
                    if rest.uppercased().hasPrefix("CMD-SHELL") {
                        var body = String(rest.dropFirst("CMD-SHELL".count)).trimmingCharacters(in: .whitespaces)
                        // Strip surrounding quotes that Dockerfile authors
                        // routinely add — `CMD-SHELL "..."`. Without this
                        // /bin/sh -c receives the literal quoted blob and
                        // tries to run it as a single filename (exit 127).
                        if (body.hasPrefix("\"") && body.hasSuffix("\""))
                            || (body.hasPrefix("'") && body.hasSuffix("'")) {
                            body = String(body.dropFirst().dropLast())
                        }
                        test = ["CMD-SHELL", body]
                    } else if rest.uppercased().hasPrefix("CMD") {
                        let body = String(rest.dropFirst("CMD".count)).trimmingCharacters(in: .whitespaces)
                        // Docker semantics : `HEALTHCHECK CMD <body>` is
                        // shell form unless `<body>` is a JSON array. We
                        // were splitting non-JSON bodies on whitespace and
                        // passing them straight to execvp, which broke
                        // `HEALTHCHECK CMD foo && bar` (treated as
                        // `["foo", "&&", "bar"]` instead of running through
                        // /bin/sh -c).
                        if let arr = parseJsonArray(body) {
                            test = ["CMD"] + arr
                        } else if !body.isEmpty {
                            test = ["CMD-SHELL", body]
                        }
                    }
                    if !test.isEmpty {
                        healthcheck = Healthcheck(test: test, interval: interval,
                                                  timeout: timeout, startPeriod: startPeriod,
                                                  retries: retries)
                    }
                }
                log(.stdout, " ---> HEALTHCHECK \(healthcheck?.test.joined(separator: " ") ?? "(skipped)")\n")
                log(.stdout, " ---> \(shortID())\n")

            case "ONBUILD", "SHELL":
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

        // Map env dict → ["KEY=VALUE", ...] (format OCI)
        let envArray: [String]? = env.isEmpty ? nil : env.map { "\($0.key)=\($0.value)" }

        let imageInfo = ImageInfo(
            id: manifestDigest,
            repository: parseRepo(config.tag),
            tag: parseTag(config.tag),
            size: totalSize,
            architecture: arch,
            os: "linux",
            layers: layers.map { $0.digest },
            cmd: cmd.isEmpty ? nil : cmd,
            entrypoint: entrypoint.isEmpty ? nil : entrypoint,
            env: envArray,
            workdir: workdir == "/" ? nil : workdir,
            user: user.isEmpty ? nil : user,
            labels: labels,
            exposedPorts: exposedPorts.map { "\($0.containerPort)/\($0.proto.rawValue)" },
            healthcheck: healthcheck,
            stopSignal: stopSignal
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

    // MARK: - COPY filesystem helpers

    /// Copy a file or directory tree from `src` to `dst` by spawning
    /// `/bin/cp -Rp`. We deliberately use a subprocess instead of any
    /// in-process API : on iCloud-managed sources (`~/Library/Mobile
    /// Documents/com~apple~CloudDocs/`), `FileManager.copyItem`,
    /// `copyfile(3)`, and even raw `open()`/`read()` from cockerd all
    /// deadlock with `EDEADLK` ("Resource deadlock avoided") on the SECOND
    /// concurrent access to a file in the same iCloud-managed directory —
    /// iCloud's `bird` coordinator serializes inside the calling process.
    /// A subprocess gets a fresh coordinator state per invocation, so each
    /// `cp` runs cleanly.
    static func copyTree(from src: URL, to dst: URL) throws {
        // `cp -R src dst` copies src AS dst when dst doesn't exist. If dst
        // already exists as a dir, cp would nest src INSIDE dst (i.e.
        // dst/src.lastPathComponent), which is not what callers expect — they
        // want dst itself to be the copy. We pre-check & remove an existing
        // dst here so the resulting layout is predictable.
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/cp")
        proc.arguments = ["-Rp", src.path, dst.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "ImageManager.copyTree", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "cp -Rp \(src.lastPathComponent) → \(dst.lastPathComponent) failed (exit \(proc.terminationStatus)): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
            ])
        }
    }

    // MARK: - .dockerignore / .cockerignore support

    /// Parse `.cockerignore` (preferred) or `.dockerignore` at the build
    /// context root. Returns the list of pattern lines, stripped of
    /// comments and blank lines, preserving order so leading-negation
    /// (`!pattern`) re-includes work the same way Docker's buildkit
    /// resolves them.
    static func loadIgnoreFile(at contextPath: String) -> [String] {
        // .cockerignore wins if both exist, mirroring how Compose and
        // Docker themselves let project-specific config override the
        // shared default file.
        for name in [".cockerignore", ".dockerignore"] {
            let p = contextPath + "/" + name
            guard let content = try? String(contentsOfFile: p, encoding: .utf8) else {
                continue
            }
            return content.split(separator: "\n").compactMap { raw -> String? in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { return nil }
                return line
            }
        }
        return []
    }

    /// True if `relPath` (relative to the build context root, no leading
    /// `/`) matches an ignore pattern. Patterns containing `**` match
    /// arbitrary path depth ; a single trailing `*` matches one segment
    /// only. Leading `!` re-includes : applied in file order so a later
    /// negation can rescue an earlier exclusion (Docker semantics).
    static func isIgnoredPath(_ relPath: String, patterns: [String]) -> Bool {
        if patterns.isEmpty { return false }
        var ignored = false
        for p in patterns {
            let isNegate = p.hasPrefix("!")
            let pat = isNegate ? String(p.dropFirst()) : p
            if matchesPattern(pat, path: relPath) {
                ignored = !isNegate
            }
        }
        return ignored
    }

    private static func matchesPattern(_ pattern: String, path: String) -> Bool {
        // Normalize : strip trailing "/" (Docker treats `dir` and `dir/`
        // as the same), strip leading "/" (always rooted at context).
        var pat = pattern
        if pat.hasSuffix("/") { pat = String(pat.dropLast()) }
        if pat.hasPrefix("/") { pat = String(pat.dropFirst()) }

        // Bare basename → match anywhere in the tree (Docker's `node_modules`
        // shouldn't require `**/node_modules` to match nested copies).
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path

        // Direct match on full path
        if fnmatchMatch(pat, path) { return true }
        // Match as prefix (so `node_modules` excludes `node_modules/foo/bar`)
        if fnmatchMatch(pat, path) || path.hasPrefix(pat + "/") { return true }
        // Bare-basename anywhere : prepend `**/` if no slash in pattern
        if !pat.contains("/") {
            if fnmatchMatch("**/" + pat, path) { return true }
            if path.hasSuffix("/" + pat) { return true }
            // any segment equals pat
            for seg in path.split(separator: "/") where String(seg) == pat {
                return true
            }
        }
        return false
    }

    private static func fnmatchMatch(_ pattern: String, _ name: String) -> Bool {
        // FNM_PATHNAME so `*` doesn't cross `/` boundaries — matches
        // Docker / gitignore semantics. `**` is expanded as two passes.
        let expanded = pattern.replacingOccurrences(of: "**", with: "*")
        return pattern.withCString { _ in
            expanded.withCString { pCStr in
                name.withCString { nCStr in
                    // FNM_PATHNAME = 2 on Darwin
                    fnmatch(pCStr, nCStr, Int32(FNM_PATHNAME)) == 0
                }
            }
        }
    }

    // MARK: - COPY glob expansion

    /// Expand a Dockerfile COPY source pattern (`package*.json`, `src/*.ts`,
    /// `foo/bar?.txt`) against the build context root. Glob chars are only
    /// honored in the basename — `dir*/file.txt` falls back to literal.
    /// Returns matching paths relative to the context root, or `[]` on no
    /// match. Uses libc `fnmatch` so semantics match what Bash / coreutils
    /// would do.
    static func expandGlob(_ pattern: String, root: URL) -> [String] {
        let dir = (pattern as NSString).deletingLastPathComponent
        let name = (pattern as NSString).lastPathComponent
        guard name.contains("*") || name.contains("?") || name.contains("[") else {
            return []
        }
        let searchDir = dir.isEmpty ? root : root.appendingPathComponent(dir)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: searchDir.path) else {
            return []
        }
        let matches = entries.filter { entry in
            pattern.withCString { _ in
                name.withCString { pCStr in
                    entry.withCString { eCStr in
                        fnmatch(pCStr, eCStr, 0) == 0
                    }
                }
            }
        }
        return matches.map { dir.isEmpty ? $0 : "\(dir)/\($0)" }.sorted()
    }

    // MARK: - COPY --from=<image> support

    /// Resolves a `--from=<value>` flag to an extracted-rootfs directory when
    /// `<value>` is an external image reference rather than a known build stage.
    /// Pulls the image on cache miss, then returns the rootfs path from the
    /// image store so the COPY loop can read files out of it like a stage.
    ///
    /// Throws if `<value>` doesn't even look like an image reference (caller
    /// catches and falls back to "build context") OR if pull/extract fails.
    private func resolveExternalImageForCopy(_ reference: String) async throws -> URL {
        // Reject obvious non-references early : paths and stage-name patterns.
        // We do this before hitting the registry so a typo'd stage name
        // doesn't trigger a 30 s registry lookup.
        if reference.isEmpty
            || reference.hasPrefix(".")
            || reference.hasPrefix("/")
            || reference.contains(" ") {
            throw CockerError.imageNotFound("'\(reference)' is not a valid image reference")
        }
        // Accept if it looks like a registry reference (has `:` for tag/digest,
        // `/` for registry/org path, or matches a plain image name we might be
        // able to resolve from Docker Hub like `alpine`).
        let looksLikeRef = reference.contains(":")
            || reference.contains("/")
            || reference.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil
        guard looksLikeRef else {
            throw CockerError.imageNotFound("'\(reference)' is not a valid image reference")
        }

        // Pull always, even on cache hit. exists() / find() can't reliably
        // resolve fully-qualified references like `ghcr.io/astral-sh/uv:latest`
        // because the local index keys are `<repository>:<tag>` (registry
        // stripped). pull() handles re-pull-as-noop internally if the image
        // is already there. We keep the ImageInfo it returns to look up the
        // rootfs directory directly, sidestepping the find() ambiguity.
        log(.stdout, " ---> Resolving --from image: \(reference)\n")
        let imageInfo = try await imageManager.pull(reference: reference, progressHandler: { msg in
            self.log(.stdout, msg + "\n")
        })
        return await imageManager.rootfsDirectory(for: imageInfo)
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

        // Pass paths via -T <file> instead of argv — RUN steps that install
        // node_modules / .venv / GOPATH routinely generate 10k+ paths, well
        // past NSConcreteTask's 4096-argv limit, and we crashed with
        // "too many arguments (14925) -- limit is 4096".
        let pathsFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".paths")
        defer { try? FileManager.default.removeItem(at: pathsFile) }
        let pathsContent = changedPaths
            .map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        try pathsContent.write(to: pathsFile, atomically: true, encoding: .utf8)

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
        proc.arguments = ["-czf", tmpTar.path, "-C", rootfs.path, "-T", pathsFile.path]
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

    // PRO-73 : turn the guest-produced overlay-upper tarball (sitting in
    // the build outbox) into a registered OCI layer, and replay it onto the
    // host working rootfs so later steps build on a cumulative base.
    //
    // Returns nil when the step produced no changes (no tarball, or an
    // empty one) so the caller simply appends no layer — matching the
    // legacy path's "changed.isEmpty" behaviour.
    /// Surface a failed RUN step's real console output at the terminal,
    /// then build the error to throw. Before this, that output only went to
    /// cockerd.log, so the user saw a bare "exited with code N" while the
    /// actual cause (apt's EACCES, a compiler error, a missing package)
    /// sat invisible in the tail. (PRO-73)
    private func runStepFailure(_ command: String, _ result: VMRuntime.EphemeralRunResult) -> CockerError {
        let tail = String(result.output.suffix(4096))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            log(.stderr, "\nThe command '\(command)' returned a non-zero code \(result.exitCode). Output:\n")
            log(.stderr, tail + "\n")
        }
        return CockerError.buildFailed("RUN '\(command)' exited with code \(result.exitCode)")
    }

    private func registerOverlayLayer(tar: URL, rootfs: URL, blobsDir: URL) async throws -> CreatedLayer? {
        guard FileManager.default.fileExists(atPath: tar.path),
              let tarData = try? Data(contentsOf: tar), !tarData.isEmpty else {
            return nil
        }
        let digest = "sha256:" + SHA256.hash(data: tarData).hexString
        let blobPath = blobsDir.appendingPathComponent(String(digest.dropFirst(7)))
        if !FileManager.default.fileExists(atPath: blobPath.path) {
            try tarData.write(to: blobPath)
        }

        // Replay onto the host base dir (opaque-dir clear → extract →
        // whiteouts), the same helper the cache-hit path uses so a fresh
        // build and a cached rebuild reconstruct the exact same tree.
        // Host-side tar writes to a local APFS dir (not virtiofs), so dpkg's
        // transient mode-000 files — already chmod'd to their final mode in
        // the layer — extract fine, and the next RUN's virtiofs lower sees
        // the new state.
        try BuildCache.applyLayer(tarPath: tar, to: rootfs)

        return CreatedLayer(digest: digest, size: tarData.count)
    }

    // MARK: - Filesystem snapshot / diff

    private func snapshotFiles(at directory: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        // Résout les liens symboliques (ex: /tmp → /private/tmp) pour que
        // les paths capturés correspondent vraiment à ce que tar verra.
        let resolved = directory.resolvingSymlinksInPath()
        let prefix = resolved.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: resolved,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return snapshot }

        for case let url as URL in enumerator {
            let absolute = url.resolvingSymlinksInPath().path
            guard absolute.hasPrefix(prefix) else { continue }
            let rel = String(absolute.dropFirst(prefix.count))
            if rel.isEmpty { continue }
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
        // Synthetic per-step marker mimicking Docker's intermediate image IDs.
        // Foundation returns UUID strings uppercase ; lowercase them so these
        // read as hex consistent with the lowercase `sha256:` layer digests
        // printed alongside — no more UPPERCASE/lowercase mix in one build log.
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
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

    /// Parse Dockerfile duration strings like "30s", "1m", "500ms", "2h"
    /// into seconds. Returns nil on garbage input. Matches Docker's
    /// time.ParseDuration semantics for the cases the HEALTHCHECK flag
    /// language actually exposes.
    private func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let suffixes: [(String, Double)] = [
            ("ms", 0.001),
            ("us", 0.000_001),
            ("ns", 0.000_000_001),
            ("s", 1),
            ("m", 60),
            ("h", 3600),
        ]
        for (suffix, factor) in suffixes {
            if trimmed.hasSuffix(suffix) {
                let numStr = String(trimmed.dropLast(suffix.count))
                if let n = Double(numStr) { return n * factor }
            }
        }
        // No suffix → assume seconds.
        return Double(trimmed)
    }

    /// Roll the cache key forward by appending the current instruction's
    /// textual form. Same input sequence → same SHA. Returns the new key
    /// so the caller can use it as a one-shot.
    func advanceCacheKey(_ step: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(stepCacheKey.utf8))
        hasher.update(data: Data(step.utf8))
        let next = hasher.finalize().hexString
        stepCacheKey = next
        return next
    }
}

/// On-disk build layer cache. Keyed by the rolling SHA from the
/// DockerfileBuilder ; value is a layer descriptor pointing into the
/// regular blob store. Layers are NOT duplicated — the cache only
/// records "this build step produced layer X with size Y".
///
/// Layout :
///   `~/.cocker/build-cache/<key>.json`  → CachedLayerEntry
///
/// On hit, BuildCache.apply extracts the cached layer's tar diff onto
/// the current rootfs (so subsequent steps see the same state the
/// previous build produced).
enum BuildCache {
    struct CachedLayerEntry: Codable {
        let digest: String
        let size: Int
    }

    // Cache + blob locations, derived from the daemon's actual data root
    // (passed in by the caller). They must track the root cockerd was
    // launched with (`--root`), NOT $HOME/.cocker or a COCKER_ROOT env var
    // — otherwise a non-default root (e.g. the dev-mode `cocker-dev`
    // install) writes cache pointers into ~/.cocker while its blobs live
    // elsewhere, so the cache never hits and it pollutes the prod cache.
    private static func cacheDir(_ root: URL) -> URL {
        root.appendingPathComponent("build-cache")
    }
    private static func blobsDir(_ root: URL) -> URL {
        root.appendingPathComponent("images/blobs/sha256")
    }

    static func lookup(key: String, root: URL) async throws -> CachedLayerEntry? {
        let url = cacheDir(root).appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CachedLayerEntry.self, from: data)
        else { return nil }
        // Sanity check : the blob still exists in the store. The blob
        // GC sweep might have collected it between builds.
        let blobName = String(entry.digest.dropFirst("sha256:".count))
        let blobPath = blobsDir(root).appendingPathComponent(blobName)
        guard FileManager.default.fileExists(atPath: blobPath.path) else {
            // Stale cache pointer ; wipe it so future lookups don't waste IO.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return entry
    }

    static func store(key: String,
                       layer: DockerfileBuilder.CreatedLayer,
                       root: URL) async throws {
        let dir = cacheDir(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry = CachedLayerEntry(digest: layer.digest, size: layer.size)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: dir.appendingPathComponent("\(key).json"), options: .atomic)
    }

    /// Materialise a cached layer onto an existing rootfs. The layer blob
    /// is a gzipped tar diff produced by `createLayer` ; we extract it
    /// in-place so the next Dockerfile step sees the same filesystem the
    /// cached build produced at this point.
    static func apply(layer: CachedLayerEntry, to rootfs: URL, root: URL) async throws {
        let blobName = String(layer.digest.dropFirst("sha256:".count))
        let blobPath = blobsDir(root).appendingPathComponent(blobName)
        guard FileManager.default.fileExists(atPath: blobPath.path) else {
            throw CockerError.buildFailed("cached layer blob missing: \(layer.digest)")
        }
        // Same replay as a fresh build (opaque-dir clear → extract →
        // whiteouts) so a cache HIT reconstructs exactly the rootfs the
        // original build produced at this step.
        try applyLayer(tarPath: blobPath, to: rootfs)
    }

    /// Compute the (marker, target) URL pairs an OCI layer's whiteout
    /// entries map to under `rootfs`. `.wh.NAME` deletes NAME in the same
    /// directory ; the opaque-dir marker `.wh..wh..opq` is skipped (handled
    /// separately). Pure path math, split out so it's unit-testable without
    /// any tar/filesystem.
    static func whiteoutTargets(in entries: [String], rootfs: URL) -> [(marker: URL, target: URL)] {
        var pairs: [(URL, URL)] = []
        for entry in entries {
            var rel = entry
            if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
            let base = (rel as NSString).lastPathComponent
            guard base.hasPrefix(".wh."), base != ".wh..wh..opq" else { continue }
            let dir = (rel as NSString).deletingLastPathComponent
            let targetName = String(base.dropFirst(4))
            let marker = rootfs.appendingPathComponent(rel)
            let target = dir.isEmpty
                ? rootfs.appendingPathComponent(targetName)
                : rootfs.appendingPathComponent(dir).appendingPathComponent(targetName)
            pairs.append((marker, target))
        }
        return pairs
    }

    /// Replay a layer tarball onto `rootfs` the OCI way — opaque-dir clear,
    /// extract, then whiteout apply. Shared by the fresh ext4-overlay build
    /// (registerOverlayLayer) and cache replay (apply) so both reconstruct
    /// exactly the same tree.
    static func applyLayer(tarPath: URL, to rootfs: URL) throws {
        let entries = try listTar(tarPath)

        // 1. Opaque dirs : `<dir>/.wh..wh..opq` means the layer replaces
        //    <dir> wholesale, so wipe the base's inherited contents BEFORE
        //    extracting the layer's version on top. (Arises from a
        //    remove-then-recreate of a directory that existed in the base.)
        for rel in entries.map(stripDotSlash) where (rel as NSString).lastPathComponent == ".wh..wh..opq" {
            let dir = (rel as NSString).deletingLastPathComponent
            let dirURL = dir.isEmpty ? rootfs : rootfs.appendingPathComponent(dir)
            if let kids = try? FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: nil) {
                for k in kids { try? FileManager.default.removeItem(at: k) }
            }
        }

        // 2. Extract the diff.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xzf", tarPath.path, "-C", rootfs.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CockerError.buildFailed("apply layer to rootfs: \(e)")
        }

        // 3. Whiteouts : drop each `.wh.NAME` target + its marker, and the
        //    extracted `.wh..wh..opq` markers (their effect was applied in 1).
        for (marker, target) in whiteoutTargets(in: entries, rootfs: rootfs) {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: marker)
        }
        for rel in entries.map(stripDotSlash) where (rel as NSString).lastPathComponent == ".wh..wh..opq" {
            try? FileManager.default.removeItem(at: rootfs.appendingPathComponent(rel))
        }
    }

    private static func stripDotSlash(_ entry: String) -> String {
        entry.hasPrefix("./") ? String(entry.dropFirst(2)) : entry
    }

    private static func listTar(_ tarPath: URL) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-tzf", tarPath.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
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
