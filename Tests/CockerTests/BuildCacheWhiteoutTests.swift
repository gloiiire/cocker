import Testing
import Foundation
@testable import CockerDaemon

// PRO-73 : the ext4-overlay build path and the build-cache replay both
// turn a layer's OCI `.wh.` entries into real deletions via
// BuildCache.whiteoutTargets. This locks the path math down so a cache
// HIT reconstructs the same rootfs a fresh `RUN rm …` produced.
@Suite("BuildCache OCI whiteout mapping")
struct BuildCacheWhiteoutTests {
    private let root = URL(fileURLWithPath: "/tmp/cocker-root")

    @Test func mapsNestedWhiteoutToMarkerAndTarget() {
        let pairs = BuildCache.whiteoutTargets(
            in: ["./var/lib/apt/lists/.wh.lock"], rootfs: root)
        #expect(pairs.count == 1)
        #expect(pairs[0].marker.path == "/tmp/cocker-root/var/lib/apt/lists/.wh.lock")
        #expect(pairs[0].target.path == "/tmp/cocker-root/var/lib/apt/lists/lock")
    }

    @Test func ignoresRegularEntries() {
        let pairs = BuildCache.whiteoutTargets(
            in: ["./usr/lib/aarch64-linux-gnu/libsndfile.so.1.0.37",
                 "./etc/hosts",
                 "var/log/"],
            rootfs: root)
        #expect(pairs.isEmpty)
    }

    @Test func handlesTopLevelAndNoDotSlashPrefix() {
        // Entries can arrive with or without the leading "./" depending on
        // how tar listed them.
        let pairs = BuildCache.whiteoutTargets(
            in: [".wh.toplevel", "etc/.wh.hosts"], rootfs: root)
        #expect(pairs.count == 2)
        #expect(pairs.contains { $0.target.path == "/tmp/cocker-root/toplevel" })
        #expect(pairs.contains { $0.target.path == "/tmp/cocker-root/etc/hosts" })
    }

    @Test func skipsOpaqueDirMarker() {
        // `.wh..wh..opq` is the overlay opaque-dir marker — not a plain
        // file deletion, handled separately, so it must not be mapped to a
        // bogus target named ".opq".
        let pairs = BuildCache.whiteoutTargets(
            in: ["./some/dir/.wh..wh..opq"], rootfs: root)
        #expect(pairs.isEmpty)
    }
}
