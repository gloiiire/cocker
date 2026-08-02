import Testing
import Foundation
@testable import CockerCore
@testable import CockerDaemon

/// `volume rm --force` skipped the in-use check entirely, so it unlinked the
/// backing `data.img` out from under a live VM that still held the fd. The
/// container kept writing into a deleted inode and the data was simply gone
/// when it stopped — no error anywhere.
///
/// Docker refuses this case regardless of `--force`; its force flag only
/// relaxes the stopped-container and missing-volume cases.
@Suite("Volume removal safety")
struct VolumeRemovalSafetyTests {

    private func harness() throws -> (VolumeManager, StateStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-volrm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try StateStore(rootDir: root)
        return (VolumeManager(store: store, rootDir: root), store, root)
    }

    private func container(name: String, status: ContainerStatus, uses volume: String) -> Container {
        var c = Container(name: name, image: "alpine", command: [], status: status)
        c.volumes = [VolumeMount(source: volume, destination: "/data")]
        return c
    }

    @Test func removesAnUnusedVolume() async throws {
        let (mgr, _, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let vol = try await mgr.create(request: VolumeCreateRequest(name: "spare"))
        try await mgr.remove("spare")
        #expect(!FileManager.default.fileExists(atPath: vol.mountpoint))
    }

    @Test func refusesAVolumeHeldByARunningContainer() async throws {
        let (mgr, store, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await mgr.create(request: VolumeCreateRequest(name: "pgdata"))
        try await store.store(container: container(name: "db", status: .running, uses: "pgdata"))

        await #expect(throws: CockerError.self) { try await mgr.remove("pgdata") }
    }

    /// The regression that mattered: `--force` must not turn the refusal above
    /// into a deletion.
    @Test func forceDoesNotOverrideARunningContainer() async throws {
        let (mgr, store, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let vol = try await mgr.create(request: VolumeCreateRequest(name: "pgdata"))
        try await store.store(container: container(name: "db", status: .running, uses: "pgdata"))

        await #expect(throws: CockerError.self) { try await mgr.remove("pgdata", force: true) }
        // ...and the image is still there, which is the whole point.
        #expect(FileManager.default.fileExists(atPath: vol.mountpoint))
        #expect(await store.volume(id: "pgdata") != nil)
    }

    @Test func forceDoesNotOverrideAPausedContainer() async throws {
        let (mgr, store, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let vol = try await mgr.create(request: VolumeCreateRequest(name: "cache"))
        try await store.store(container: container(name: "redis", status: .paused, uses: "cache"))

        await #expect(throws: CockerError.self) { try await mgr.remove("cache", force: true) }
        #expect(FileManager.default.fileExists(atPath: vol.mountpoint))
    }

    /// A stopped container still owns its volume by default — that's Docker's
    /// rule, and it's what keeps `compose down` from dropping your database.
    @Test func refusesAStoppedContainersVolumeWithoutForce() async throws {
        let (mgr, store, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await mgr.create(request: VolumeCreateRequest(name: "pgdata"))
        try await store.store(container: container(name: "db", status: .stopped, uses: "pgdata"))

        await #expect(throws: CockerError.self) { try await mgr.remove("pgdata") }
    }

    /// ...but `--force` is a real escape hatch there, which is the case it
    /// exists for.
    @Test func forceRemovesAStoppedContainersVolume() async throws {
        let (mgr, store, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let vol = try await mgr.create(request: VolumeCreateRequest(name: "pgdata"))
        try await store.store(container: container(name: "db", status: .stopped, uses: "pgdata"))

        try await mgr.remove("pgdata", force: true)
        #expect(!FileManager.default.fileExists(atPath: vol.mountpoint))
        #expect(await store.volume(id: "pgdata") == nil)
    }

    /// The IPC layer decoded `force` and threw it away, so `-f` never reached
    /// the engine at all.
    @Test func removeRequestCarriesForce() throws {
        let request = try IPCRequest(type: .volumeRm,
                                     payload: ContainerIDRequest(id: "pgdata", force: true))
        let decoded = try JSONDecoder().decode(ContainerIDRequest.self, from: request.payload)
        #expect(decoded.force == true)
    }
}
