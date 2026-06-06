import Foundation
import Crypto

// Local OCI image store — stores images in ~/.cocker/images/
// Layout:
//   ~/.cocker/images/<registry>/<repo>/<tag>/manifest.json
//   ~/.cocker/images/blobs/sha256/<digest>      (shared layer cache)
//   ~/.cocker/images/<registry>/<repo>/<tag>/rootfs/  (extracted)

public actor ImageStore {
    public let rootDir: URL
    private let blobDir: URL
    private let imagesIndexFile: URL
    private var index: [String: ImageInfo] = [:]  // "repo:tag" -> ImageInfo

    public init(rootDir: URL) throws {
        self.rootDir = rootDir
        self.blobDir = rootDir.appendingPathComponent("blobs/sha256")
        self.imagesIndexFile = rootDir.appendingPathComponent("images.json")
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("blobs/sha256"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("rootfs"), withIntermediateDirectories: true)
        // Load index synchronously during init (actor isolation is established after init)
        if let data = try? Data(contentsOf: rootDir.appendingPathComponent("images.json")),
           let loaded = try? JSONDecoder().decode([String: ImageInfo].self, from: data) {
            self.index = loaded
        }
    }

    // MARK: - Index management

    private func loadIndex() {
        guard let data = try? Data(contentsOf: imagesIndexFile),
              let loaded = try? JSONDecoder().decode([String: ImageInfo].self, from: data)
        else { return }
        index = loaded
    }

    private func saveIndex() throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: imagesIndexFile, options: .atomic)
    }

    // MARK: - Query

    public func list() -> [ImageInfo] {
        Array(index.values).sorted { $0.createdAt > $1.createdAt }
    }

    public func find(_ reference: String) -> ImageInfo? {
        // Exact match
        if let img = index[reference] { return img }
        // Try adding :latest if no tag
        if !reference.contains(":"), let img = index["\(reference):latest"] { return img }
        // Try with Docker Hub library/ prefix (alpine → library/alpine)
        let withLatest = reference.contains(":") ? reference : "\(reference):latest"
        if !withLatest.contains("/"), let img = index["library/\(withLatest)"] { return img }
        // Try by short ID
        return index.values.first { $0.id.hasPrefix(reference) }
    }

    public func exists(_ reference: String) -> Bool {
        find(reference) != nil
    }

    // MARK: - Store image metadata

    public func store(image: ImageInfo) throws {
        index["\(image.repository):\(image.tag)"] = image
        try saveIndex()
    }

    public func remove(_ reference: String) throws {
        guard let img = find(reference) else { throw CockerError.imageNotFound(reference) }
        let key = "\(img.repository):\(img.tag)"
        index.removeValue(forKey: key)

        // Remove rootfs if no other image uses same layers
        let rootfsDir = rootfsDirectory(for: img)
        try? FileManager.default.removeItem(at: rootfsDir)

        // GC unused blobs
        try gcBlobs()
        try saveIndex()
    }

    public func tag(source: String, target: String) throws {
        guard var img = find(source) else { throw CockerError.imageNotFound(source) }
        let ref = try ImageReference.parse(target)
        img.repository = ref.repository
        img.tag = ref.tag
        index["\(ref.repository):\(ref.tag)"] = img
        try saveIndex()
    }

    // MARK: - Blob operations

    public func blobPath(for digest: String) -> URL {
        let hash = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : digest
        return blobDir.appendingPathComponent(hash)
    }

    public func hasBlob(_ digest: String) -> Bool {
        FileManager.default.fileExists(atPath: blobPath(for: digest).path)
    }

    // MARK: - Rootfs operations

    public func rootfsDirectory(for image: ImageInfo) -> URL {
        rootDir.appendingPathComponent("rootfs/\(image.id.prefix(12))")
    }

    public func hasRootfs(for image: ImageInfo) -> Bool {
        FileManager.default.fileExists(atPath: rootfsDirectory(for: image).path)
    }

    /// Répertoire d'un container : son rootfs personnel cloné depuis l'image
    public func containerRootfsDirectory(containerID: String) -> URL {
        rootDir.appendingPathComponent("containers/\(containerID)/rootfs")
    }

    /// Clone le rootfs d'une image vers un dossier dédié au container via APFS
    /// `clonefile()` (copy-on-write natif macOS). Instantané, zéro coût disque
    /// jusqu'à modification. Garantit l'isolation : 2 containers de la même
    /// image n'écrivent plus dans le même rootfs partagé (bug critique du PoC).
    ///
    /// Fallback : si clonefile échoue (filesystem non-APFS, etc.), on retombe
    /// sur cp -R classique.
    public func cloneRootfs(for image: ImageInfo, containerID: String) throws -> URL {
        let source = rootfsDirectory(for: image)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CockerError.internalError("Source rootfs introuvable: \(source.path)")
        }

        let dest = containerRootfsDirectory(containerID: containerID)
        let destParent = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destParent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)

        // clonefile(3) — copy-on-write APFS, syscall direct via Darwin
        let result = source.path.withCString { src in
            dest.path.withCString { dst in
                Darwin.clonefile(src, dst, 0)
            }
        }
        if result == 0 { return dest }

        // Fallback : cp -R si clonefile échoue (rare : non-APFS, perms, etc.)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/cp")
        proc.arguments = ["-R", source.path, dest.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw CockerError.internalError("cp -R fallback échoué pour \(source.path) → \(dest.path)")
        }
        return dest
    }

    /// Supprime le rootfs d'un container (et son dossier parent).
    /// Utilisé au `rm` d'un container, ou à son cleanup automatique.
    public func removeContainerRootfs(containerID: String) throws {
        let containerDir = rootDir
            .appendingPathComponent("containers/\(containerID)")
        try? FileManager.default.removeItem(at: containerDir)
    }

    public func extractRootfs(
        for image: ImageInfo,
        layers: [OCIDescriptor],
        progress: ((String, Double) -> Void)? = nil
    ) async throws {
        let rootfsDir = rootfsDirectory(for: image)
        try FileManager.default.createDirectory(at: rootfsDir, withIntermediateDirectories: true)

        for (i, layer) in layers.enumerated() {
            progress?(layer.digest, Double(i) / Double(layers.count))
            let layerPath = blobPath(for: layer.digest)
            guard FileManager.default.fileExists(atPath: layerPath.path) else {
                throw CockerError.layerDownloadFailed(layer.digest, "Blob not found in cache")
            }
            try await extractLayer(at: layerPath, to: rootfsDir, isGzip: layer.isGzipLayer)
        }

        progress?("done", 1.0)
    }

    private func extractLayer(at source: URL, to destination: URL, isGzip: Bool) async throws {
        // Use tar to extract (handles whiteout files properly via --delete-before)
        // BSD tar (macOS) — overwrite est le défaut, pas besoin du flag
        var args = ["-x", "-f", source.path, "-C", destination.path]
        if isGzip { args.insert("-z", at: 0) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = args

        // Handle OCI whiteout files (.wh. prefix)
        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown"
            // tar exits non-zero for whiteout files sometimes; only fail on serious errors
            if !errMsg.contains("Ignoring unknown extended header") {
                throw CockerError.buildFailed("Layer extraction failed: \(errMsg)")
            }
        }

        // Process OCI whiteout files
        try processWhiteouts(in: destination)
    }

    private func processWhiteouts(in directory: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return }

        var whiteouts: [(URL, String)] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".wh.") {
                let target = name == ".wh..wh..opq"
                    ? url.deletingLastPathComponent()
                    : url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst(4)))
                whiteouts.append((url, target.path))
            }
        }

        for (whiteout, targetPath) in whiteouts {
            try? fm.removeItem(atPath: targetPath)
            try? fm.removeItem(at: whiteout)
        }
    }

    // MARK: - Blob GC

    private func gcBlobs() throws {
        let allDigests = Set(index.values.flatMap { $0.layers })
        let fm = FileManager.default
        guard let blobFiles = try? fm.contentsOfDirectory(at: blobDir, includingPropertiesForKeys: nil) else { return }

        for blob in blobFiles {
            let digest = "sha256:\(blob.lastPathComponent)"
            if !allDigests.contains(digest) {
                try? fm.removeItem(at: blob)
            }
        }
    }
}
