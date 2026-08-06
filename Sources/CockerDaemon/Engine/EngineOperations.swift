import Foundation
import CockerCore

// Business-layer operations shared by BOTH API surfaces (the native IPC
// DaemonServer and the Docker-compatible DockerAPIServer).
//
// Rationale (A-series architecture fix) : these used to live as private
// helpers inside DaemonServer, i.e. inside a *transport adapter*. The
// Docker HTTP server then either reimplemented them or silently diverged —
// e.g. `commit` was fixed to snapshot the container's overlay rootfs while
// `export` kept reading the image's shared rootfs and lost every change the
// container had made. Keeping the logic here means a fix lands once, for
// every client.

extension ContainerEngine {

    // MARK: - Rootfs resolution

    /// The directory that actually contains a container's filesystem.
    ///
    /// Every container gets an APFS-clonefile copy of its image rootfs
    /// ("overlay") ; that copy — not the image's shared rootfs — is where
    /// the container's writes live. Reading the image rootfs instead
    /// silently discards all container modifications (the historical
    /// `export`/`commit` drift). Falls back to the image rootfs only when
    /// the clone doesn't exist (very early lifecycle, or cleaned up).
    func effectiveRootfs(for container: Container) async throws -> URL {
        let cloned = await images.store.containerRootfsDirectory(containerID: container.id)
        if FileManager.default.fileExists(atPath: cloned.path) {
            return cloned
        }
        let img = try await images.find(container.image)
        return await images.store.rootfsDirectory(for: img)
    }

    // MARK: - cp

    func copy(request req: CpRequest) async throws {
        guard let container = await state.container(id: req.containerID) else {
            throw CockerError.containerNotFound(req.containerID)
        }
        let rootfsDir = try await effectiveRootfs(for: container)
        let fm = FileManager.default

        if req.toContainer {
            // host → container. Lexical confinement is enough on the write
            // side : the daemon never reads through a malicious symlink
            // because the destination doesn't exist yet (or we're replacing
            // it). We DO follow symlinks on the **source** because a regular
            // user is allowed to copy files they own from anywhere on the
            // host into a container they control.
            let src = URL(fileURLWithPath: req.hostPath)
            let dst = try PathConfinement.confine(req.containerPath, to: rootfsDir)
            let parent = dst.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        } else {
            // container → host. The container rootfs is attacker-controlled
            // (image author + running processes can plant arbitrary
            // symlinks). Use the read flavour that walks symlinks and
            // refuses any final target escaping the confined root.
            let src = try PathConfinement.confineRead(req.containerPath, to: rootfsDir)
            let dst = URL(fileURLWithPath: req.hostPath)
            let parent = dst.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
    }

    // MARK: - archive (Docker's /containers/{id}/archive)

    /// Resolve a container-relative path to a confined host URL inside that
    /// container's rootfs.
    ///
    /// `forWriting` picks the confinement flavour: the read side walks
    /// symlinks and refuses any target escaping the root, because a container
    /// rootfs is attacker-controlled (the image author and any process in it
    /// can plant symlinks). The write side is lexical — the destination
    /// doesn't exist yet, or we're replacing it.
    func archiveTarget(containerID: String, path: String, forWriting: Bool) async throws -> URL {
        guard let container = await state.container(id: containerID) else {
            throw CockerError.containerNotFound(containerID)
        }
        let rootfs = try await effectiveRootfs(for: container)
        return forWriting
            ? try PathConfinement.confine(path, to: rootfs)
            : try PathConfinement.confineRead(path, to: rootfs)
    }

    // MARK: - diff

    func diff(containerID: String) async throws -> DiffResponse {
        guard let container = await state.container(id: containerID) else {
            throw CockerError.containerNotFound(containerID)
        }
        let containerRoot = try await effectiveRootfs(for: container)
        // Every container writes into an APFS-clonefile copy of its image
        // rootfs, so a real diff is just a comparison of the two trees.
        // This used to enumerate the container rootfs and mark *everything*
        // A or C, capped at 200 entries — the output looked like a diff and
        // was nothing of the sort, which is worse than not offering it,
        // because tooling trusts it.
        let image = try await images.find(container.image)
        let imageRoot = await images.store.rootfsDirectory(for: image)
        guard FileManager.default.fileExists(atPath: imageRoot.path),
              imageRoot.path != containerRoot.path else {
            // No baseline to compare against (the image rootfs is gone, or
            // the container never got its own clone). Report nothing rather
            // than inventing changes.
            return DiffResponse(entries: [])
        }
        return DiffResponse(entries: Self.compareTrees(base: imageRoot, overlay: containerRoot))
    }

    /// Docker-shaped diff between an image rootfs and a container's copy of
    /// it: `A` added, `C` changed, `D` deleted, paths absolute and sorted.
    static func compareTrees(base: URL, overlay: URL) -> [DiffEntry] {
        let baseEntries = fileIndex(of: base)
        let overlayEntries = fileIndex(of: overlay)

        var entries: [DiffEntry] = []
        for (path, overlayStat) in overlayEntries {
            guard let baseStat = baseEntries[path] else {
                entries.append(DiffEntry(kind: "A", path: path))
                continue
            }
            if overlayStat != baseStat {
                entries.append(DiffEntry(kind: "C", path: path))
            }
        }
        for path in baseEntries.keys where overlayEntries[path] == nil {
            entries.append(DiffEntry(kind: "D", path: path))
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Relative path → a cheap identity (size + mtime, or a marker for
    /// directories and symlinks). Content hashing every file would be
    /// correct but unusably slow on a real image.
    private static func fileIndex(of root: URL) -> [String: String] {
        var index: [String: String] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.producesRelativePathURLs]) else { return index }

        let rootPath = root.standardizedFileURL.path
        while let any = walker.nextObject() {
            guard let url = any as? URL else { continue }
            var relative = url.standardizedFileURL.path
            if relative.hasPrefix(rootPath) { relative = String(relative.dropFirst(rootPath.count)) }
            guard !relative.isEmpty else { continue }
            if !relative.hasPrefix("/") { relative = "/" + relative }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                index[relative] = "l:" + ((try? FileManager.default
                    .destinationOfSymbolicLink(atPath: url.path)) ?? "")
            } else if values?.isDirectory == true {
                // Directories carry no identity of their own — a directory is
                // only "changed" because of what's inside it, and those
                // children are reported individually.
                index[relative] = "d"
            } else {
                let size = values?.fileSize ?? 0
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                index[relative] = "f:\(size):\(mtime)"
            }
        }
        return index
    }

    // MARK: - save (image → tar)

    /// Stage `manifest.json` + `rootfs/` into a temp tree and tar it.
    /// Returns the URL of the produced tarball — CALLER OWNS the file and
    /// must delete it after streaming/copying its content. Returning a URL
    /// instead of Data keeps multi-GB images out of daemon memory.
    func saveImageToTar(reference: String) async throws -> URL {
        let img = try await images.find(reference)
        let rootfsDir = await images.store.rootfsDirectory(for: img)

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let manifestData = try encoder.encode(img)
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        if FileManager.default.fileExists(atPath: rootfsDir.path) {
            // clonefile on APFS : instant, falls back to a copy elsewhere.
            try FileManager.default.copyItem(at: rootfsDir,
                                             to: staging.appendingPathComponent("rootfs"))
        }

        let tarURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-save-\(UUID().uuidString).tar")
        try await Self.runTar(["-c", "-f", tarURL.path, "-C", staging.path, "."])
        return tarURL
    }

    // MARK: - load (tar → image)

    /// Import a `cocker save` tarball already on local disk. Accepts both
    /// the new shape (manifest.json + rootfs/) and the legacy flat shape.
    func loadImageFromTar(at tarPath: URL) async throws -> String {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try await Self.runTar(["-x", "-f", tarPath.path, "-C", tmpDir.path])

        let manifestURL = tmpDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let img = try? JSONDecoder().decode(ImageInfo.self, from: data) else {
            return "Loaded image archive (manifest not found — use `cocker images` to verify)"
        }
        let destRootfs = await images.store.rootfsDirectory(for: img)
        if !FileManager.default.fileExists(atPath: destRootfs.path) {
            try FileManager.default.createDirectory(at: destRootfs.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let bundled = tmpDir.appendingPathComponent("rootfs")
            if FileManager.default.fileExists(atPath: bundled.path) {
                try FileManager.default.copyItem(at: bundled, to: destRootfs)
            } else {
                try FileManager.default.createDirectory(at: destRootfs,
                                                         withIntermediateDirectories: true)
                // Legacy flat shape : every entry except the manifest.
                if let files = try? FileManager.default.contentsOfDirectory(
                    at: tmpDir, includingPropertiesForKeys: nil) {
                    for f in files where !["manifest.json", "image.tar"]
                                            .contains(f.lastPathComponent) {
                        try? FileManager.default.copyItem(
                            at: f, to: destRootfs.appendingPathComponent(f.lastPathComponent))
                    }
                }
            }
        }
        try await images.storeBuiltImage(img)
        return "Loaded image: \(img.repository):\(img.tag)"
    }

    // MARK: - export (container → rootfs tar)

    /// Export a container's filesystem. Uses `effectiveRootfs`, i.e. the
    /// container's OVERLAY — the pre-fix code exported the image's shared
    /// rootfs and silently dropped every change the container had made
    /// (the same class of bug `commit` was already fixed for).
    func exportContainer(_ containerID: String) async throws -> Data {
        let tarURL = try await exportContainerToTar(containerID)
        defer { try? FileManager.default.removeItem(at: tarURL) }
        return try Data(contentsOf: tarURL)
    }

    /// File-backed export used by IPC v2. The legacy `exportContainer`
    /// wrapper above still materializes Data for stdout/old clients, but
    /// normal `cocker export -o file.tar` never buffers the archive.
    func exportContainerToTar(_ containerID: String) async throws -> URL {
        guard let container = await state.container(id: containerID) else {
            throw CockerError.containerNotFound(containerID)
        }
        let rootfsDir = try await effectiveRootfs(for: container)
        guard FileManager.default.fileExists(atPath: rootfsDir.path) else {
            throw CockerError.imageNotFound("\(container.image) (rootfs not available)")
        }
        let tarURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-export-\(UUID().uuidString).tar")
        try await Self.runTar(["-c", "-f", tarURL.path,
                               "-C", rootfsDir.path, "."])
        return tarURL
    }

    // MARK: - commit (container → image)

    func commitContainer(_ req: CommitRequest) async throws -> ImageInfo {
        guard let container = await state.container(id: req.containerID) else {
            throw CockerError.containerNotFound(req.containerID)
        }
        let img = try await images.find(container.image)
        // Commit MUST snapshot the container's OVERLAY rootfs, not the
        // image's shared base — otherwise every container modification is
        // silently lost.
        let rootfsDir = try await effectiveRootfs(for: container)
        guard FileManager.default.fileExists(atPath: rootfsDir.path) else {
            throw CockerError.imageNotFound("\(container.image) (rootfs not available)")
        }
        return try await images.commit(
            fromRootfs: rootfsDir,
            tag: req.tag,
            baseImage: img,
            author: req.author,
            message: req.message
        )
    }

    // MARK: - image prune

    func imagePrune(all: Bool = false) async throws -> PruneResponse {
        let allImages = await images.list()
        let allContainers = await state.allContainers(includeAll: true)

        // Containers whose image must be protected. Default prune protects
        // images referenced by ANY container (running or stopped) ; `--all`
        // narrows that to images a *running* container depends on — a
        // running VM already cloned its rootfs, but yanking the source
        // image would break commit/restart, so we keep those.
        let holders = all ? allContainers.filter { $0.status == .running } : allContainers

        // Resolve each holder's stored image string to a concrete image ID :
        // a container records what the user typed (`alpine:3.19`) while the
        // image is stored normalized (`library/alpine:3.19`). Raw string
        // comparison never matched.
        var protectedIDs = Set<String>()
        for c in holders {
            if let img = try? await images.find(c.image) {
                protectedIDs.insert(img.id)
            }
        }

        var deleted: [String] = []
        var reclaimed: UInt64 = 0
        for img in allImages where !protectedIDs.contains(img.id) {
            reclaimed += img.size
            try? await images.remove(img.reference, force: all)
            deleted.append(img.reference)
        }
        return PruneResponse(containersDeleted: [], imagesDeleted: deleted,
                             volumesDeleted: [], spaceReclaimed: reclaimed)
    }

    // MARK: - image history

    /// `docker history`, one entry per stored layer.
    ///
    /// cocker does not keep per-instruction build metadata, and this used to
    /// paper over that with three fabrications: timestamps staggered a
    /// minute apart, a `createdBy` reading `/bin/sh -c layer 3`, and a size
    /// of `img.size / layers.count` — equal-sized layers, which no image
    /// has. The comment called it "approximative"; the output did not.
    ///
    /// Sizes are now the real blob on disk. For the metadata cocker doesn't
    /// have, `<missing>` is docker's own marker for a layer whose build
    /// record is absent — an answer the reader can act on, unlike a
    /// plausible command that was never run.
    func imageHistory(_ reference: String) async throws -> [ImageHistoryEntry] {
        let img = try await images.find(reference)
        let fm = FileManager.default
        var entries: [ImageHistoryEntry] = []
        for (i, layer) in img.layers.enumerated() {
            let blob = await images.store.blobPath(for: layer)
            let onDisk = (try? fm.attributesOfItem(atPath: blob.path)[.size] as? UInt64) ?? nil
            entries.append(ImageHistoryEntry(
                id: String(layer.prefix(19)),
                // One timestamp, the image's. The stagger implied cocker
                // knew when each layer was built. It doesn't.
                createdAt: img.createdAt,
                createdBy: i == 0
                    ? "/bin/sh -c #(nop) FROM \(img.repository):\(img.tag)"
                    : "<missing>",
                size: onDisk ?? 0,
                comment: ""
            ))
        }
        if entries.isEmpty {
            entries.append(ImageHistoryEntry(
                id: String(img.id.prefix(19)),
                createdAt: img.createdAt,
                createdBy: "/bin/sh -c #(nop) ADD \(img.repository):\(img.tag)",
                size: img.size,
                comment: ""
            ))
        }
        return entries
    }

    // MARK: - system df

    func systemDf() async throws -> SystemDfResponse {
        let allContainers = await state.allContainers(includeAll: true)
        let runningContainers = allContainers.filter { $0.status == .running }
        let allImages = await images.list()
        let allVolumes = await volumes.list()
        let usedImages = Set(allContainers.map { $0.image })

        let totalImageSize = allImages.reduce(UInt64(0)) { $0 + $1.size }
        let unusedImageSize = allImages
            .filter { !usedImages.contains($0.reference) && !usedImages.contains($0.id) }
            .reduce(UInt64(0)) { $0 + $1.size }

        // Container and volume sizes.
        //
        // These used to list ONE directory level and add up `.fileSizeKey`.
        // That key on a directory is not the size of its contents, so a
        // container rootfs tree and any nested volume contributed roughly
        // zero — `system df` reported `Containers 1  0 B` next to a running
        // container. The container walk also pointed at images/rootfs, the
        // image store, rather than containers/<id>/rootfs.
        //
        // Allocated size rather than logical: container rootfs directories
        // are APFS clonefile copies of the image, so the logical sum would
        // count bytes that share blocks with the image and report disk that
        // freeing the container would not give back.
        let fm = FileManager.default
        func allocatedSize(of directory: URL) -> UInt64 {
            guard let e = fm.enumerator(at: directory,
                                        includingPropertiesForKeys: [.totalFileAllocatedSizeKey,
                                                                     .isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else { return 0 }
            var total: UInt64 = 0
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey,
                                                               .isRegularFileKey]),
                      v.isRegularFile == true else { continue }
                total += UInt64(v.totalFileAllocatedSize ?? 0)
            }
            return total
        }

        // Per container, so "reclaimable" can be a sum of the stopped ones
        // rather than a proportional guess.
        var sizeByContainer: [String: UInt64] = [:]
        for c in allContainers {
            let dir = await images.store.containerRootfsDirectory(containerID: c.id)
            sizeByContainer[c.id] = allocatedSize(of: dir)
        }
        let containerSize = sizeByContainer.values.reduce(0, &+)

        var totalVolSize: UInt64 = 0
        for vol in allVolumes {
            totalVolSize += allocatedSize(of: URL(fileURLWithPath: vol.mountpoint))
        }

        let stoppedContainers = allContainers.filter { $0.status == .stopped || $0.status == .dead }
        let entries: [SystemDfResponse.DfEntry] = [
            SystemDfResponse.DfEntry(type: "Images", total: allImages.count, active: usedImages.count, size: totalImageSize, reclaimable: unusedImageSize),
            SystemDfResponse.DfEntry(type: "Containers", total: allContainers.count, active: runningContainers.count, size: containerSize, // Was `containerSize / count * stoppedCount` — a proportional
            // split invented from a total, not a measurement of anything.
            reclaimable: stoppedContainers.reduce(UInt64(0)) { $0 &+ (sizeByContainer[$1.id] ?? 0) }),
            SystemDfResponse.DfEntry(type: "Volumes", total: allVolumes.count, active: allVolumes.count, size: totalVolSize, reclaimable: 0),
        ]
        return SystemDfResponse(entries: entries)
    }

    // MARK: - compose ls

    func composeProjects() async -> ComposeLsResponse {
        let allContainers = await state.allContainers(includeAll: true)
        var projects: [String: (containers: [Container], configFile: String)] = [:]

        for c in allContainers {
            guard let proj = c.labels["com.cocker.project"] else { continue }
            var entry = projects[proj] ?? (containers: [], configFile: "")
            entry.containers.append(c)
            projects[proj] = entry
        }

        let infos = projects.map { (name, entry) -> ComposeLsResponse.ProjectInfo in
            let running = entry.containers.filter { $0.status == .running }.count
            let total = entry.containers.count
            let status = running == total && total > 0 ? "running(\(running))" : "partially running(\(running)/\(total))"
            return ComposeLsResponse.ProjectInfo(
                name: name,
                status: status,
                configFiles: "cocker-compose.yml",
                servicesCount: entry.containers.count
            )
        }.sorted { $0.name < $1.name }

        return ComposeLsResponse(projects: infos)
    }

    // MARK: - update (resources)

    func updateResources(_ req: UpdateRequest) async throws {
        guard let _ = await state.container(id: req.containerID) else {
            throw CockerError.containerNotFound(req.containerID)
        }
        try await state.updateContainer(id: req.containerID) { c in
            if let cpus = req.cpus { c.cpuCount = cpus }
            if let mem = req.memoryMB { c.memoryMB = mem }
        }
    }

    // MARK: - tar helper

    /// Run /usr/bin/tar without blocking the actor : `waitUntilExit()` on
    /// the calling thread would park a cooperative-pool thread for the
    /// whole archive duration. The termination handler resumes a
    /// continuation instead.
    private static func runTar(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    cont.resume(throwing: CockerError.internalError(
                        "tar exited \(p.terminationStatus): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
