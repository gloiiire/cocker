import Foundation
import CockerCore
#if canImport(Darwin)
import Darwin
#endif

actor VolumeManager {
    private let store: StateStore
    private let volumesRoot: URL

    /// Default sparse image size for new volumes (8 GiB). Sparse on APFS —
    /// only the actually-written bytes consume disk space. Large enough for
    /// a typical postgres / mysql dev workload ; users with bigger needs
    /// can grow the image after the fact with `truncate -s N data.img`.
    private static let defaultImgSize: UInt64 = 8 * 1024 * 1024 * 1024

    init(store: StateStore, rootDir: URL) {
        self.store = store
        self.volumesRoot = rootDir.appendingPathComponent("volumes")
        try? FileManager.default.createDirectory(at: volumesRoot, withIntermediateDirectories: true)
    }

    // MARK: - CRUD

    func create(request: VolumeCreateRequest) async throws -> VolumeInfo {
        // Security barrier : every entry point that creates a volume — CLI,
        // Docker API, Compose, and anonymous auto-creation via
        // `resolveSource` — funnels through here, so validating the name in
        // this one place confines the daemon's `mkdir` / `mke2fs` / write
        // below `volumesRoot` no matter who asked. A name containing `..`
        // or `/` is rejected before it can ever reach `appendingPathComponent`.
        try ResourceName.validate(request.name, kind: "volume")

        if await store.volume(id: request.name) != nil {
            throw CockerError.volumeAlreadyExists(request.name)
        }

        // Block-storage layout : <root>/volumes/<name>/data.img is a sparse
        // ext4 disk image attached to the VM as a virtio block device. The
        // guest formats + mounts it on first attach (cocker-init handles
        // mkfs.ext4 if no filesystem is present). Chown / chmod work
        // natively inside a real Linux fs, unlike Apple's virtiofs which
        // returns EPERM for guest-side metadata changes (broke postgres,
        // mysql, every database that chowns its data dir at startup).
        let volDir = volumesRoot.appendingPathComponent(request.name)
        try FileManager.default.createDirectory(at: volDir, withIntermediateDirectories: true)
        let imgURL = volDir.appendingPathComponent("data.img")
        // 0600 : the image holds the container's raw filesystem (database
        // files, secrets). `open()`'s mode argument IS masked by umask, so
        // fchmod after a successful open guarantees owner-only regardless of
        // the daemon's umask.
        let fd = open(imgURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw CockerError.requestFailed("create volume \(request.name): \(String(cString: strerror(errno)))")
        }
        _ = fchmod(fd, 0o600)
        let rc = ftruncate(fd, off_t(Self.defaultImgSize))
        close(fd)
        guard rc == 0 else {
            try? FileManager.default.removeItem(at: imgURL)
            throw CockerError.requestFailed("ftruncate volume image: \(String(cString: strerror(errno)))")
        }

        // Format the sparse file as ext4 host-side using the user's
        // brew-installed e2fsprogs (`brew install e2fsprogs`). Running it
        // here means the volume is mountable immediately at attach time —
        // no need to ship a static mke2fs in cocker-init's initrd or to
        // hope the user's container image bundles e2fsprogs. If mke2fs
        // isn't on disk we leave the .img unformatted and log a hint ;
        // cocker-init will then try the in-image mke2fs as a fallback.
        let mkfsCandidates = [
            "/opt/homebrew/opt/e2fsprogs/sbin/mke2fs",
            "/opt/homebrew/sbin/mke2fs",
            "/usr/local/opt/e2fsprogs/sbin/mke2fs",
            "/usr/local/sbin/mke2fs",
        ]
        if let mke2fs = mkfsCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: mke2fs)
            proc.arguments = ["-t", "ext4", "-F", "-q", imgURL.path]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                try? FileManager.default.removeItem(at: imgURL)
                throw CockerError.requestFailed(
                    "mke2fs failed (exit \(proc.terminationStatus)) on \(imgURL.path)"
                )
            }
        } else {
            fputs(
                "[volumes] warning: mke2fs not found on host (brew install e2fsprogs) — " +
                "volume \(request.name) will be formatted on first container attach " +
                "if its image bundles mkfs.ext4 (Alpine: apk add e2fsprogs)\n",
                stderr
            )
        }

        let volume = VolumeInfo(
            name: request.name,
            mountpoint: imgURL.path,
            driver: request.driver,
            labels: request.labels
        )

        try await store.store(volume: volume)
        return volume
    }

    func get(_ name: String) async throws -> VolumeInfo {
        guard let vol = await store.volume(id: name) else {
            throw CockerError.volumeNotFound(name)
        }
        return vol
    }

    func list() async -> [VolumeInfo] {
        await store.allVolumes()
    }

    func remove(_ name: String, force: Bool = false) async throws {
        let vol = try await get(name)

        // Check if in use by a container
        let containers = await store.allContainers(includeAll: true)
        let inUse = containers.contains { c in
            c.volumes.contains { $0.source == name }
        }

        if inUse && !force {
            throw CockerError.volumeInUse(name)
        }

        // Delete data directory
        try? FileManager.default.removeItem(atPath: vol.mountpoint)
        let volDir = volumesRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: volDir)

        try await store.removeVolume(id: vol.id)
    }

    func pruneUnused() async throws -> (names: [String], bytes: UInt64) {
        let removed = try await store.pruneUnusedVolumes()
        var totalBytes: UInt64 = 0

        for name in removed {
            let volDir = volumesRoot.appendingPathComponent(name)
            totalBytes += directorySize(at: volDir)
            try? FileManager.default.removeItem(at: volDir)
        }

        return (removed, totalBytes)
    }

    // MARK: - Resolve mount source

    func resolveSource(_ mount: VolumeMount) async throws -> String {
        if mount.source.hasPrefix("/") {
            // Absolute path bind mount
            return mount.source
        }
        // Named volume
        if await store.volume(id: mount.source) == nil {
            // Auto-create anonymous volume
            _ = try await create(request: VolumeCreateRequest(name: mount.source))
        }
        let vol = try await get(mount.source)
        return vol.mountpoint
    }

    private func directorySize(at url: URL) -> UInt64 {
        var total: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
            }
        }
        return total
    }
}
