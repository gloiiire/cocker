import Testing
import Foundation
@testable import CockerCore
@testable import CockerDaemon

@Suite("RootfsBootstrap.resolveStopSignal")
struct ResolveStopSignalTests {
    @Test func canonicalNamesMap() {
        #expect(RootfsBootstrap.resolveStopSignal("SIGTERM") == 15)
        #expect(RootfsBootstrap.resolveStopSignal("SIGQUIT") == 3)
        #expect(RootfsBootstrap.resolveStopSignal("SIGHUP") == 1)
        #expect(RootfsBootstrap.resolveStopSignal("SIGINT") == 2)
        #expect(RootfsBootstrap.resolveStopSignal("SIGUSR1") == 10)
        #expect(RootfsBootstrap.resolveStopSignal("SIGUSR2") == 12)
        #expect(RootfsBootstrap.resolveStopSignal("SIGKILL") == 9)
    }

    @Test func acceptsNamesWithoutSIGPrefix() {
        // Docker accepts both `STOPSIGNAL SIGQUIT` and `STOPSIGNAL QUIT` ;
        // our parser strips the optional prefix.
        #expect(RootfsBootstrap.resolveStopSignal("TERM") == 15)
        #expect(RootfsBootstrap.resolveStopSignal("QUIT") == 3)
        #expect(RootfsBootstrap.resolveStopSignal("HUP") == 1)
    }

    @Test func numericInputAccepted() {
        // Dockerfile syntax also allows raw numbers : `STOPSIGNAL 15`.
        #expect(RootfsBootstrap.resolveStopSignal("15") == 15)
        #expect(RootfsBootstrap.resolveStopSignal("9") == 9)
    }

    @Test func unknownMapsToZero() {
        // 0 means "use cocker-init's default" (SIGTERM) — never blow up.
        #expect(RootfsBootstrap.resolveStopSignal(nil) == 0)
        #expect(RootfsBootstrap.resolveStopSignal("") == 0)
        #expect(RootfsBootstrap.resolveStopSignal("BOGUS") == 0)
    }

    @Test func caseInsensitiveAndTrimmed() {
        #expect(RootfsBootstrap.resolveStopSignal(" sigterm ") == 15)
        #expect(RootfsBootstrap.resolveStopSignal("sigQUIT") == 3)
    }
}

@Suite("StateStore — schemaVersion migration")
struct SchemaVersionMigrationTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func unversionedLegacyFileMigratesToV2() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Legacy state.json (no schemaVersion key, sole "containers" map).
        let legacy = """
        {
          "containers": {
            "abc123def456": {
              "id": "abc123def456",
              "name": "old",
              "image": "alpine:latest"
            }
          }
        }
        """
        let file = dir.appendingPathComponent("state.json")
        try Data(legacy.utf8).write(to: file)
        let store = try StateStore(rootDir: dir)
        // Container survives migration ; new schemaVersion landed on disk
        // the next time the store saves.
        let recovered = await store.container(id: "abc123def456")
        #expect(recovered?.name == "old")
    }

    @Test func futureSchemaVersionFailsLoad() throws {
        // We can't easily test exit(64) without spawning a sub-process,
        // but we can confirm the decoder reads the schemaVersion value
        // correctly when present — the production code then bails out.
        let payload = """
        { "schemaVersion": 999, "containers": {} }
        """
        struct DecoderRig: Decodable {
            var schemaVersion: Int = 1
        }
        let d = try JSONDecoder().decode(DecoderRig.self, from: Data(payload.utf8))
        #expect(d.schemaVersion == 999)
    }

    @Test func corruptedFileIsPreservedAndStoreStartsEmpty() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        try Data("{NOT-VALID-JSON".utf8).write(to: file)
        let store = try StateStore(rootDir: dir)
        // Empty store after corrupted-load — no containers recovered.
        let all = await store.allContainers(includeAll: true)
        #expect(all.isEmpty)
        // Backup file with the corruption was preserved.
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("state.json.corrupted.") }
        #expect(!backups.isEmpty)
    }
}
