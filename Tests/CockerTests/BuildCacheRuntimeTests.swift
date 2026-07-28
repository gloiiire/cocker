import Foundation
import Testing
@testable import CockerDaemon

/// The `/run` regression had a second life : 0.7.13.14 fixed `cocker-init`,
/// but machines that had already built `RUN mkdir -p /run/nginx` kept
/// replaying the empty layer captured by the old runtime, so nginx still
/// failed until someone thought of `--no-cache`. A build layer is only
/// replayable under the runtime that produced it.
@Suite("Build cache runtime fingerprint")
struct BuildCacheRuntimeFingerprintTests {

    // MARK: - Fingerprint identity

    @Test func differentInitrdYieldsDifferentFingerprint() {
        let before = BuildRuntimeFingerprint.compute(
            components: ["initrd:old-cocker-init", "kernel:k", "path:ext4-overlay"])
        let after = BuildRuntimeFingerprint.compute(
            components: ["initrd:new-cocker-init", "kernel:k", "path:ext4-overlay"])
        #expect(before != after)
    }

    @Test func differentKernelYieldsDifferentFingerprint() {
        let a = BuildRuntimeFingerprint.compute(
            components: ["initrd:i", "kernel:6.12.28", "path:ext4-overlay"])
        let b = BuildRuntimeFingerprint.compute(
            components: ["initrd:i", "kernel:6.13.0", "path:ext4-overlay"])
        #expect(a != b)
    }

    @Test func buildStrategyIsPartOfTheFingerprint() {
        let overlay = BuildRuntimeFingerprint.compute(
            components: ["initrd:i", "kernel:k", "path:ext4-overlay"])
        let legacy = BuildRuntimeFingerprint.compute(
            components: ["initrd:i", "kernel:k", "path:legacy-host-diff"])
        #expect(overlay != legacy)
    }

    @Test func sameComponentsAreStable() {
        let components = ["initrd:i", "kernel:k", "path:ext4-overlay"]
        #expect(BuildRuntimeFingerprint.compute(components: components)
            == BuildRuntimeFingerprint.compute(components: components))
    }

    /// Order matters : swapping two component values must not collide,
    /// otherwise a kernel upgrade could be masked by an initrd downgrade.
    @Test func componentOrderIsSignificant() {
        #expect(BuildRuntimeFingerprint.compute(components: ["a", "b"])
            != BuildRuntimeFingerprint.compute(components: ["b", "a"]))
    }

    /// A missing initrd must not fingerprint like an empty one, or a
    /// broken install would silently share the cache of a valid one.
    @Test func missingFileIsDistinctFromEmptyFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let empty = dir.appendingPathComponent("empty.img")
        try Data().write(to: empty)
        let absent = dir.appendingPathComponent("absent.img")

        #expect(BuildRuntimeFingerprint.fileDigest(empty)
            != BuildRuntimeFingerprint.fileDigest(absent))
    }

    /// Rewriting the initrd (what `brew upgrade` does) must change the
    /// digest even when the memoisation cache is warm.
    @Test func rewrittenFileInvalidatesTheMemoisedDigest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let initrd = dir.appendingPathComponent("initrd.img")
        try Data("cocker-init 0.7.13.13".utf8).write(to: initrd)
        let before = BuildRuntimeFingerprint.cachedFileDigest(initrd)
        #expect(before == BuildRuntimeFingerprint.cachedFileDigest(initrd))

        // Different length → the size stamp alone already differs, but the
        // mtime is also pushed forward so the check holds on filesystems
        // with coarse timestamps.
        try Data("cocker-init 0.7.13.14 — /run tmpfs removed".utf8).write(to: initrd)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: initrd.path)

        #expect(BuildRuntimeFingerprint.cachedFileDigest(initrd) != before)
    }

    /// The symlink chain `~/.cocker/kernel/initrd.img → <brew>/share/...`
    /// is what `brew upgrade` replaces. Following it is what makes the
    /// upgrade observable at all.
    @Test func symlinkResolvesToTheTargetContent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("shipped-initrd.img")
        try Data("payload".utf8).write(to: target)
        let link = dir.appendingPathComponent("initrd.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(BuildRuntimeFingerprint.cachedFileDigest(link)
            == BuildRuntimeFingerprint.cachedFileDigest(target))
    }

    // MARK: - Cache behaviour

    /// The actual regression : a layer stored by one runtime must not be
    /// served to another, and a hit under the same runtime must still work
    /// (otherwise the fix would just disable caching).
    @Test func lookupRejectsEntriesFromAnotherRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // A blob must exist for the entry to be considered live.
        let blobs = root.appendingPathComponent("images/blobs/sha256")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let digest = "sha256:" + String(repeating: "a", count: 64)
        try Data("layer".utf8).write(
            to: blobs.appendingPathComponent(String(digest.dropFirst("sha256:".count))))

        let key = "step-key"
        let oldRuntime = BuildRuntimeFingerprint.compute(components: ["initrd:0.7.13.13"])
        let newRuntime = BuildRuntimeFingerprint.compute(components: ["initrd:0.7.13.14"])

        try await BuildCache.store(
            key: key,
            layer: DockerfileBuilder.CreatedLayer(digest: digest, size: 5),
            runtime: oldRuntime,
            root: root)

        // Same runtime → the cache must still be useful.
        #expect(try await BuildCache.lookup(key: key, runtime: oldRuntime, root: root) != nil)

        // Upgraded runtime → the stale layer must not be replayed.
        #expect(try await BuildCache.lookup(key: key, runtime: newRuntime, root: root) == nil)

        // ...and the dead pointer is cleaned up rather than left behind.
        let entryURL = root.appendingPathComponent("build-cache/\(key).json")
        #expect(!FileManager.default.fileExists(atPath: entryURL.path))
    }

    /// Entries written before 0.7.13.15 carry no runtime field. They were
    /// produced by the very runtime that had the `/run` bug, so they must
    /// be discarded rather than trusted.
    @Test func lookupRejectsLegacyEntriesWithoutRuntimeField() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let blobs = root.appendingPathComponent("images/blobs/sha256")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let digest = "sha256:" + String(repeating: "b", count: 64)
        try Data("layer".utf8).write(
            to: blobs.appendingPathComponent(String(digest.dropFirst("sha256:".count))))

        let cacheDir = root.appendingPathComponent("build-cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // Exact on-disk shape produced by <= 0.7.13.14.
        try Data(#"{"digest":"\#(digest)","size":5}"#.utf8)
            .write(to: cacheDir.appendingPathComponent("legacy.json"))

        let runtime = BuildRuntimeFingerprint.compute(components: ["initrd:current"])
        #expect(try await BuildCache.lookup(key: "legacy", runtime: runtime, root: root) == nil)
    }

    /// A freshly stored entry must be readable back under the same
    /// runtime, including after a round-trip through JSON.
    @Test func storedEntryCarriesItsRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let blobs = root.appendingPathComponent("images/blobs/sha256")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let digest = "sha256:" + String(repeating: "c", count: 64)
        try Data("layer".utf8).write(
            to: blobs.appendingPathComponent(String(digest.dropFirst("sha256:".count))))

        let runtime = BuildRuntimeFingerprint.compute(components: ["initrd:x", "kernel:y"])
        try await BuildCache.store(
            key: "k",
            layer: DockerfileBuilder.CreatedLayer(digest: digest, size: 5),
            runtime: runtime,
            root: root)

        let raw = try Data(contentsOf: root.appendingPathComponent("build-cache/k.json"))
        let entry = try JSONDecoder().decode(BuildCache.CachedLayerEntry.self, from: raw)
        #expect(entry.runtime == runtime)
        #expect(entry.digest == digest)
    }
}
