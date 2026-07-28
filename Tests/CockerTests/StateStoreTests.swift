import Testing
import Foundation
@testable import CockerCore
@testable import CockerDaemon

// Isolated StateStore against a fresh tmp dir per test so file-state never
// leaks between cases. We exercise the actor by spinning a temp root.

@Suite("StateStore — containers")
struct StateStoreContainersTests {
    private func makeStore() async throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(rootDir: dir), dir)
    }

    private func sample(name: String = "alpha", id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()) -> Container {
        Container(id: id, name: name, image: "alpine", command: ["sh"])
    }

    @Test func emptyStoreHasNoContainers() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = await s.allContainers(includeAll: true)
        #expect(all.isEmpty)
    }

    @Test func storeAndRetrieveByID() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = sample(name: "alpha")
        try await s.store(container: c)
        let got = await s.container(id: c.id)
        #expect(got?.name == "alpha")
    }

    @Test func retrieveByPrefix() async throws {
        // **B3** : prefix-id match now requires at least 12 characters —
        // Docker's short-id minimum — so a 1- or 2-char lookup can't
        // collide with whichever UUID happens to start the same way.
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = sample(id: "abc123def456789")
        try await s.store(container: c)
        // Full 12-char canonical short id resolves to the container.
        let got = await s.container(id: "abc123def456")
        #expect(got != nil)
        // 6-char prefix is no longer accepted — caller must use the full
        // 12-char short id (or a unique container name).
        let short = await s.container(id: "abc123")
        #expect(short == nil)
    }

    @Test func retrieveByName() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await s.store(container: sample(name: "named"))
        let got = await s.container(id: "named")
        #expect(got?.name == "named")
    }

    @Test func nameExistsTrueAfterStore() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await s.store(container: sample(name: "tagged"))
        #expect(await s.nameExists("tagged"))
        #expect(!(await s.nameExists("never")))
    }

    @Test func updateModifiesPersistedField() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = sample()
        try await s.store(container: c)
        try await s.updateContainer(id: c.id) { c in
            c.status = .running
        }
        let got = await s.container(id: c.id)
        #expect(got?.status == .running)
    }

    @Test func updateMissingContainerThrows() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: CockerError.self) {
            try await s.updateContainer(id: "does-not-exist") { _ in }
        }
    }

    @Test func removeContainer() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = sample(name: "doomed")
        try await s.store(container: c)
        try await s.removeContainer(id: c.id)
        #expect(await s.container(id: c.id) == nil)
    }

    @Test func removeMissingContainerThrows() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: CockerError.self) {
            try await s.removeContainer(id: "nope")
        }
    }

    @Test func allContainersFilteringDefaults() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var running = sample(name: "r")
        running.status = .running
        var stopped = sample(name: "s")
        stopped.status = .stopped
        try await s.store(container: running)
        try await s.store(container: stopped)

        let running_only = await s.allContainers(includeAll: false)
        #expect(running_only.count == 1)
        #expect(running_only.first?.name == "r")

        let all = await s.allContainers(includeAll: true)
        #expect(all.count == 2)
    }

    @Test func generateNameProducesUniqueValues() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let n1 = await s.generateName()
        let n2 = await s.generateName()
        // n1 isn't stored, so n2 could be same in theory. Just verify shape :
        #expect(n1.contains("_"))
        #expect(n2.contains("_"))
    }

    @Test func generateNameSkipsExistingOnes() async throws {
        let (s, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = await s.generateName()
        try await s.store(container: sample(name: n))
        let n2 = await s.generateName()
        #expect(n != n2)
    }

    @Test func persistenceAcrossInstances() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let s = try StateStore(rootDir: dir)
            try await s.store(container: Container(id: "abcd1234", name: "persistent", image: "alpine", command: ["sh"]))
        }
        // Second instance — should read state.json
        let s2 = try StateStore(rootDir: dir)
        let got = await s2.container(id: "abcd1234")
        #expect(got?.name == "persistent")
    }

    @Test func coalescedUpdateIsDeferredThenFlushed() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = try StateStore(rootDir: dir)
        try await s.store(container: Container(id: "abcd1234abcd", name: "hc", image: "alpine", command: ["sh"]))

        // A `.coalesced` mutation must NOT hit disk synchronously…
        try await s.updateContainer(id: "abcd1234abcd", durability: .coalesced) { c in
            c.healthFailingStreak = 7
        }
        let onDiskBefore = try StateStore(rootDir: dir)
        let staleStreak = await onDiskBefore.container(id: "abcd1234abcd")?.healthFailingStreak
        #expect(staleStreak == 0, "coalesced write should be debounced, not synchronous")

        // …but it must be visible in memory immediately…
        let inMemory = await s.container(id: "abcd1234abcd")?.healthFailingStreak
        #expect(inMemory == 7)

        // …and flushPending() must force it to disk deterministically.
        await s.flushPending()
        let onDiskAfter = try StateStore(rootDir: dir)
        let flushed = await onDiskAfter.container(id: "abcd1234abcd")?.healthFailingStreak
        #expect(flushed == 7)
    }
}

@Suite("StateStore — networks")
struct StateStoreNetworksTests {
    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(rootDir: dir), dir)
    }

    @Test func storeAndRetrieveNetwork() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = NetworkInfo(name: "bridge", driver: .bridge, subnet: "172.17.0.0/16", gateway: "172.17.0.1")
        try await s.store(network: n)
        let got = await s.network(id: n.id)
        #expect(got?.name == "bridge")
    }

    @Test func retrieveByName() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = NetworkInfo(name: "named-net", driver: .bridge,
                            subnet: "10.0.0.0/16", gateway: "10.0.0.1")
        try await s.store(network: n)
        let got = await s.network(id: "named-net")
        #expect(got != nil)
    }

    @Test func removeNetwork() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = NetworkInfo(name: "doomed-net", driver: .bridge,
                            subnet: "10.0.0.0/16", gateway: "10.0.0.1")
        try await s.store(network: n)
        try await s.removeNetwork(id: n.id)
        #expect(await s.network(id: n.id) == nil)
    }

    @Test func removeMissingNetworkThrows() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: CockerError.self) {
            try await s.removeNetwork(id: "does-not-exist")
        }
    }

    @Test func allNetworksSortedByName() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await s.store(network: NetworkInfo(name: "zoo", driver: .bridge, subnet: "10.0.0.0/16", gateway: "10.0.0.1"))
        try await s.store(network: NetworkInfo(name: "alpha", driver: .bridge, subnet: "10.1.0.0/16", gateway: "10.1.0.1"))
        try await s.store(network: NetworkInfo(name: "mid", driver: .bridge, subnet: "10.2.0.0/16", gateway: "10.2.0.1"))
        let names = await s.allNetworks().map { $0.name }
        #expect(names == ["alpha", "mid", "zoo"])
    }
}

@Suite("StateStore — volumes")
struct StateStoreVolumesTests {
    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(rootDir: dir), dir)
    }

    @Test func storeRetrieveVolume() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = VolumeInfo(name: "data")
        try await s.store(volume: v)
        let got = await s.volume(id: v.id)
        #expect(got?.name == "data")
    }

    @Test func removeVolume() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = VolumeInfo(name: "doomed-vol")
        try await s.store(volume: v)
        try await s.removeVolume(id: v.id)
        #expect(await s.volume(id: v.id) == nil)
    }

    @Test func removeMissingVolumeThrows() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: CockerError.self) {
            try await s.removeVolume(id: "nope")
        }
    }
}

@Suite("StateStore — reconcileAfterRestart")
struct StateStoreReconcileTests {
    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(rootDir: dir), dir)
    }

    @Test func runningContainersBecomeStopped() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var c = Container(id: "abcd", name: "phantom", image: "alpine", command: ["sh"])
        c.status = .running
        try await s.store(container: c)

        try await s.reconcileAfterRestart()

        let got = await s.container(id: "abcd")
        #expect(got?.status == .stopped)
        #expect(got?.exitCode == -1)
        #expect(got?.finishedAt != nil)
    }

    @Test func pausedContainersBecomeStopped() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var c = Container(id: "eeee", name: "paused", image: "alpine", command: ["sh"])
        c.status = .paused
        try await s.store(container: c)

        try await s.reconcileAfterRestart()

        let got = await s.container(id: "eeee")
        #expect(got?.status == .stopped)
    }

    @Test func stoppedContainersUntouched() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var c = Container(id: "abcd1234", name: "already-stopped", image: "alpine", command: ["sh"])
        c.status = .stopped
        c.exitCode = 42  // some prior exit code we want preserved
        try await s.store(container: c)

        try await s.reconcileAfterRestart()

        let got = await s.container(id: "abcd1234")
        #expect(got?.exitCode == 42)
    }

    @Test func reconcileOnEmptyStateIsNoOp() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Just verify no crash.
        try await s.reconcileAfterRestart()
    }
}

@Suite("StateStore — prune")
struct StateStorePruneTests {
    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(rootDir: dir), dir)
    }

    @Test func pruneStoppedReturnsRemovedIDs() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var stopped = Container(id: "stop1", name: "stopped-1", image: "alpine", command: ["sh"])
        stopped.status = .stopped
        var dead = Container(id: "dead1", name: "dead-1", image: "alpine", command: ["sh"])
        dead.status = .dead
        var running = Container(id: "run1", name: "running-1", image: "alpine", command: ["sh"])
        running.status = .running

        try await s.store(container: stopped)
        try await s.store(container: dead)
        try await s.store(container: running)

        let removed = try await s.pruneStopped()
        #expect(removed.count == 2)
        #expect(removed.sorted() == ["dead1", "stop1"])

        let remaining = await s.allContainers(includeAll: true).map { $0.id }
        #expect(remaining == ["run1"])
    }

    @Test func pruneUnusedVolumes() async throws {
        let (s, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await s.store(volume: VolumeInfo(name: "used"))
        try await s.store(volume: VolumeInfo(name: "unused"))
        try await s.store(volume: VolumeInfo(name: "alsounused"))

        var c = Container(id: "cccc", name: "c", image: "alpine", command: ["sh"])
        c.volumes = [VolumeMount(source: "used", destination: "/data")]
        try await s.store(container: c)

        let removed = try await s.pruneUnusedVolumes()
        #expect(removed.sorted() == ["alsounused", "unused"])
    }
}
