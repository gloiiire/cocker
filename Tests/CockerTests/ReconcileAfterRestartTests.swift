import Testing
import Foundation
@testable import CockerCore
@testable import CockerDaemon

// reconcileAfterRestart is the path that runs at cockerd boot ; we verify
// the contract it enforces against the persisted state.json :
//   1. running / paused → stopped with finishedAt + exitCode=-1
//   2. healthFailingStreak reset (the loop that incremented it died)
//   3. healthStatus preserved as-is (Docker freezes last known status)

@Suite("StateStore.reconcileAfterRestart — daemon-bounce hygiene")
struct ReconcileAfterRestartTests {
    /// Build a fresh StateStore against a unique temp dir and seed it
    /// with one container in a given configuration.
    private func make(status: ContainerStatus,
                      healthStatus: HealthStatus = .none,
                      failingStreak: Int = 0,
                      withHealthcheck: Bool = false) async throws -> (URL, StateStore, Container) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try StateStore(rootDir: tmp)
        let c = Container(
            id: "abcdef012345",
            name: "t",
            image: "alpine",
            command: ["sleep","60"],
            status: status,
            healthStatus: healthStatus,
            healthcheck: withHealthcheck
                ? Healthcheck(test: ["CMD-SHELL", "true"], interval: 1, timeout: 1, retries: 1)
                : nil,
            healthFailingStreak: failingStreak
        )
        try await store.store(container: c)
        return (tmp, store, c)
    }

    @Test func runningContainerBecomesStopped() async throws {
        let (tmp, store, c) = try await make(status: .running)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await store.reconcileAfterRestart()
        let after = await store.container(id: c.id)
        #expect(after?.status == .stopped)
        #expect(after?.finishedAt != nil)
        #expect(after?.exitCode == -1)
    }

    @Test func pausedContainerAlsoBecomesStopped() async throws {
        let (tmp, store, c) = try await make(status: .paused)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await store.reconcileAfterRestart()
        #expect(await store.container(id: c.id)?.status == .stopped)
    }

    @Test func stoppedContainerLeftAlone() async throws {
        let (tmp, store, _) = try await make(status: .stopped, healthStatus: .healthy)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await store.reconcileAfterRestart()
        // healthStatus on an already-stopped container must not be churned
        // by reconcile — we only touch records that were running or paused.
        #expect(await store.container(id: "abcdef012345")?.healthStatus == .healthy)
    }

    @Test func failingStreakResetButHealthStatusPreserved() async throws {
        let (tmp, store, c) = try await make(
            status: .running,
            healthStatus: .healthy,
            failingStreak: 7,
            withHealthcheck: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await store.reconcileAfterRestart()
        let after = await store.container(id: c.id)
        // Streak reset : the old loop that incremented it is dead.
        #expect(after?.healthFailingStreak == 0)
        // Status frozen at last value : Docker shows the last probed
        // status on a stopped container. We restored "healthy", not
        // "starting".
        #expect(after?.healthStatus == .healthy)
    }
}
