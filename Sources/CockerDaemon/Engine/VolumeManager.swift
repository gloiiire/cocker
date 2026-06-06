import Foundation
import CockerCore

actor VolumeManager {
    private let store: StateStore
    private let volumesRoot: URL

    init(store: StateStore, rootDir: URL) {
        self.store = store
        self.volumesRoot = rootDir.appendingPathComponent("volumes")
        try? FileManager.default.createDirectory(at: volumesRoot, withIntermediateDirectories: true)
    }

    // MARK: - CRUD

    func create(request: VolumeCreateRequest) async throws -> VolumeInfo {
        if await store.volume(id: request.name) != nil {
            throw CockerError.volumeAlreadyExists(request.name)
        }

        let mountpoint = volumesRoot.appendingPathComponent("\(request.name)/_data")
        try FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)

        let volume = VolumeInfo(
            name: request.name,
            mountpoint: mountpoint.path,
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
