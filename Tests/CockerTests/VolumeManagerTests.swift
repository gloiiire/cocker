import Testing
import Foundation
@testable import CockerCore
@testable import CockerDaemon

// VolumeManager talks to disk and to StateStore. Each test gets its own
// tmpdir root so they can run in parallel without stepping on shared state.

private func makeManager() throws -> (VolumeManager, StateStore, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cocker-vol-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try StateStore(rootDir: root)
    let mgr = VolumeManager(store: store, rootDir: root)
    return (mgr, store, root)
}

@Suite("VolumeManager — create")
struct VolumeManagerCreateTests {
    @Test func createsVolumeAndPersistsToStore() async throws {
        let (mgr, store, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let vol = try await mgr.create(request: VolumeCreateRequest(name: "data"))
        #expect(vol.name == "data")
        #expect(vol.driver == "local")
        // 0.5.13 switched named volumes from a `_data` virtiofs dir to a
        // sparse `data.img` ext4 block device — fixes chown EPERM /
        // lost+found / FUSE inode bugs that broke postgres, mysql, redis
        // on Apple virtiofsd. VolumeManager.mountpoint now points at the
        // image file itself ; VMRuntime attaches it as a virtio block
        // device and the guest mounts it on the destination path.
        #expect(vol.mountpoint.hasSuffix("/data/data.img"))
        #expect(FileManager.default.fileExists(atPath: vol.mountpoint))
        // Persisted in StateStore
        let stored = await store.volume(id: "data")
        #expect(stored != nil)
    }

    @Test func rejectsDuplicateName() async throws {
        let (mgr, _, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await mgr.create(request: VolumeCreateRequest(name: "dup"))
        await #expect(throws: CockerError.self) {
            _ = try await mgr.create(request: VolumeCreateRequest(name: "dup"))
        }
    }

    @Test func carriesLabels() async throws {
        let (mgr, _, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let vol = try await mgr.create(request:
            VolumeCreateRequest(name: "tagged", driver: "local",
                                labels: ["env": "test", "owner": "alice"]))
        #expect(vol.labels["env"] == "test")
        #expect(vol.labels["owner"] == "alice")
    }
}

@Suite("VolumeManager — get / list")
struct VolumeManagerGetListTests {
    @Test func getReturnsVolume() async throws {
        let (mgr, _, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await mgr.create(request: VolumeCreateRequest(name: "x"))
        let v = try await mgr.get("x")
        #expect(v.name == "x")
    }

    @Test func getThrowsForMissingVolume() async throws {
        let (mgr, _, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: CockerError.self) {
            _ = try await mgr.get("missing")
        }
    }

    @Test func listReturnsAllVolumesSortedByName() async throws {
        let (mgr, _, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["zeta", "alpha", "beta"] {
            _ = try await mgr.create(request: VolumeCreateRequest(name: name))
        }
        let list = await mgr.list()
        #expect(list.map(\.name) == ["alpha", "beta", "zeta"])
    }
}

@Suite("VolumeManager — remove")
struct VolumeManagerRemoveTests {
    @Test func removesVolumeAndOnDiskData() async throws {
        let (mgr, store, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let vol = try await mgr.create(request: VolumeCreateRequest(name: "trash"))
        let mp = vol.mountpoint
        try await mgr.remove("trash")

        #expect(await store.volume(id: "trash") == nil)
        #expect(!FileManager.default.fileExists(atPath: mp))
    }

    @Test func refusesWhenVolumeIsInUse() async throws {
        let (mgr, store, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await mgr.create(request: VolumeCreateRequest(name: "busy"))
        // Attach the volume to a hypothetical container record.
        let c = Container(name: "user", image: "alpine", command: ["sh"],
                          volumes: [VolumeMount(source: "busy", destination: "/data")])
        try await store.store(container: c)

        await #expect(throws: CockerError.self) {
            try await mgr.remove("busy")
        }
    }

    @Test func forceOverridesInUseGuard() async throws {
        let (mgr, store, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await mgr.create(request: VolumeCreateRequest(name: "force-me"))
        try await store.store(container: Container(
            name: "x", image: "alpine", command: ["sh"],
            volumes: [VolumeMount(source: "force-me", destination: "/data")]))

        try await mgr.remove("force-me", force: true)
        #expect(await store.volume(id: "force-me") == nil)
    }
}

@Suite("VolumeManager — resolveSource")
struct VolumeManagerResolveSourceTests {
    @Test func absolutePathPassthrough() async throws {
        let (mgr, _, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let mount = VolumeMount(source: "/etc/hosts", destination: "/x")
        let resolved = try await mgr.resolveSource(mount)
        #expect(resolved == "/etc/hosts")
    }

    @Test func namedVolumeReturnsMountpoint() async throws {
        let (mgr, _, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let vol = try await mgr.create(request: VolumeCreateRequest(name: "shared"))
        let mount = VolumeMount(source: "shared", destination: "/data")
        let resolved = try await mgr.resolveSource(mount)
        #expect(resolved == vol.mountpoint)
    }

    @Test func autoCreatesAnonymousNamedVolume() async throws {
        let (mgr, store, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let mount = VolumeMount(source: "anon", destination: "/data")
        let resolved = try await mgr.resolveSource(mount)
        // Anonymous lookup auto-creates the named volume on demand.
        #expect(await store.volume(id: "anon") != nil)
        #expect(FileManager.default.fileExists(atPath: resolved))
    }
}

@Suite("VolumeManager — prune")
struct VolumeManagerPruneTests {
    @Test func prunesAllWhenNoContainersReference() async throws {
        let (mgr, _, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["a", "b", "c"] {
            _ = try await mgr.create(request: VolumeCreateRequest(name: name))
        }
        let (removed, _) = try await mgr.pruneUnused()
        #expect(Set(removed) == Set(["a", "b", "c"]))
    }

    @Test func keepsVolumesReferencedByContainer() async throws {
        let (mgr, store, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await mgr.create(request: VolumeCreateRequest(name: "used"))
        _ = try await mgr.create(request: VolumeCreateRequest(name: "unused"))
        try await store.store(container: Container(
            name: "ref", image: "alpine", command: ["sh"],
            volumes: [VolumeMount(source: "used", destination: "/d")]))

        let (removed, _) = try await mgr.pruneUnused()
        #expect(removed == ["unused"])
    }
}
