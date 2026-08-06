import Foundation
import Testing
@testable import CockerCore
@testable import CockerDaemon

/// `network connect` printed "✓ Connected" and moved nothing.
///
/// It appended the caller's string to a JSON array and stopped. It never
/// touched `container.networkName` — the field `VMRuntime` reads to key the
/// container's L2 switch port at boot — and `L2Switch` drops frames between
/// ports on different networks. Measured on 1.1.0.1:
///
///     netA on probenet (10.42.0.13), netB on bridge
///     netB → netA                              isolated
///     cocker network connect probenet netB     exit 0, "✓ Connected"
///     netB → netA                              STILL isolated
///
/// `disconnect` was the mirror image: traffic kept flowing.
@Suite("network connect/disconnect move the container")
struct NetworkConnectMovesTests {

    private func freshStore() async throws -> StateStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-netmove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try StateStore(rootDir: dir)
    }

    private func makeContainer(_ name: String, status: ContainerStatus,
                               network: String?) -> Container {
        var c = Container(name: name, image: "alpine", command: ["sh"])
        c.status = status
        c.networkName = network
        return c
    }

    @Test func connectRewiresAStoppedContainer() async throws {
        let store = try await freshStore()
        let net = try await NetworkManager(store: store)
        _ = try await net.create(request: NetworkCreateRequest(name: "probenet"))

        let c = makeContainer("web", status: .stopped, network: "bridge")
        try await store.store(container: c)

        try await net.connect(containerID: "web", networkID: "probenet")

        // The field that actually decides the switch port.
        #expect(await store.container(id: c.id)?.networkName == "probenet")
    }

    /// The membership lists must not disagree about where a container is.
    @Test func connectLeavesThePreviousNetwork() async throws {
        let store = try await freshStore()
        let net = try await NetworkManager(store: store)
        _ = try await net.create(request: NetworkCreateRequest(name: "probenet"))

        let c = makeContainer("web", status: .stopped, network: "bridge")
        try await store.store(container: c)
        try await net.connect(containerID: "web", networkID: "bridge")
        try await net.connect(containerID: "web", networkID: "probenet")

        #expect(await store.network(id: "probenet")?.containers.contains(c.id) == true)
        #expect(await store.network(id: "bridge")?.containers.contains(c.id) == false)
    }

    /// Membership used to store whatever string the caller typed, so the same
    /// container appeared as an id (from `run --network`) and as a name (from
    /// `connect`) — `["ceb5d2a652e6", "netB"]`. `disconnect` by name then
    /// matched nothing, removed nothing, and reported success.
    @Test func membershipIsKeyedByCanonicalID() async throws {
        let store = try await freshStore()
        let net = try await NetworkManager(store: store)
        _ = try await net.create(request: NetworkCreateRequest(name: "probenet"))

        let c = makeContainer("web", status: .stopped, network: "bridge")
        try await store.store(container: c)

        // Connect by NAME, disconnect by ID: both have to refer to the same
        // membership entry.
        try await net.connect(containerID: "web", networkID: "probenet")
        let members = await store.network(id: "probenet")?.containers ?? []
        #expect(members == [c.id], "membership should hold the canonical id, got \(members)")

        try await net.disconnect(containerID: c.id, networkID: "probenet")
        #expect(await store.network(id: "probenet")?.containers.isEmpty == true)
    }

    @Test func disconnectReturnsAStoppedContainerToBridge() async throws {
        let store = try await freshStore()
        let net = try await NetworkManager(store: store)
        _ = try await net.create(request: NetworkCreateRequest(name: "probenet"))

        let c = makeContainer("web", status: .stopped, network: "probenet")
        try await store.store(container: c)

        try await net.disconnect(containerID: "web", networkID: "probenet")
        #expect(await store.container(id: c.id)?.networkName == "bridge")
    }

    /// The whole point: a running container cannot be re-keyed, so it must be
    /// refused instead of reported as moved.
    @Test func aRunningContainerIsRefusedNotPretended() async throws {
        let store = try await freshStore()
        let net = try await NetworkManager(store: store)
        _ = try await net.create(request: NetworkCreateRequest(name: "probenet"))

        let c = makeContainer("web", status: .running, network: "bridge")
        try await store.store(container: c)

        await #expect(throws: CockerError.self) {
            try await net.connect(containerID: "web", networkID: "probenet")
        }
        // And it did not half-apply.
        #expect(await store.container(id: c.id)?.networkName == "bridge")
    }

    /// `run --network foo` starts the container, so by the time membership is
    /// recorded it is already live — and the create path went through
    /// `try? connect`, which now refuses live containers and would swallow
    /// the refusal. Measured before this: `network inspect probenet` listed
    /// only the container added by `connect`, never the one started with
    /// `--network probenet`.
    @Test func creationRecordsMembershipEvenThoughTheContainerIsLive() async throws {
        let store = try await freshStore()
        let net = try await NetworkManager(store: store)
        _ = try await net.create(request: NetworkCreateRequest(name: "probenet"))

        let c = makeContainer("web", status: .running, network: "probenet")
        try await store.store(container: c)

        try await net.recordMembershipAtCreate(containerID: c.id, networkID: "probenet")
        #expect(await store.network(id: "probenet")?.containers == [c.id])
    }

    @Test func refusingARunningContainerIs126() {
        let error = CockerError.containerMustBeStopped("web", "change the network of")
        #expect(error.exitCode == 126)
    }

    @Test func pausedCountsAsLiveAndCreatedDoesNot() {
        #expect(ContainerStatus.running.isLive)
        #expect(ContainerStatus.paused.isLive)
        #expect(ContainerStatus.restarting.isLive)
        #expect(!ContainerStatus.created.isLive)
        #expect(!ContainerStatus.stopped.isLive)
        #expect(!ContainerStatus.dead.isLive)
    }
}
