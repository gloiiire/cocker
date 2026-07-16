import Foundation
import CockerCore
#if canImport(Darwin)
import Darwin
#endif

/// Host-side creation + ext4 formatting of a sparse disk image.
///
/// macOS has no native mkfs.ext4, so we shell out to the user's
/// brew-installed e2fsprogs (`brew install e2fsprogs`). Used by the
/// image-build overlay upper (PRO-73) — where a `RUN` step's writes land
/// on a native ext4 filesystem instead of Apple virtiofs, whose host-side
/// process (running as the non-root macOS user) returns EACCES for
/// create-with-mode-000 (exactly dpkg's unpack pattern). The named-volume
/// path in VolumeManager does the same mke2fs dance independently.
enum Ext4Image {
    /// Brew e2fsprogs `mke2fs` locations, most-preferred first. Kept in
    /// sync with the list VolumeManager probes.
    static let mke2fsCandidates = [
        "/opt/homebrew/opt/e2fsprogs/sbin/mke2fs",
        "/opt/homebrew/sbin/mke2fs",
        "/usr/local/opt/e2fsprogs/sbin/mke2fs",
        "/usr/local/sbin/mke2fs",
    ]

    /// First mke2fs found on disk, or nil if e2fsprogs isn't installed.
    static func mke2fsPath() -> String? {
        mke2fsCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Create a sparse `size`-byte file at `url` and format it ext4.
    ///
    /// Sparse (ftruncate) so an oversized image costs only the bytes
    /// actually written. Throws if e2fsprogs is missing or mke2fs fails —
    /// the caller (build path) surfaces a clear "brew install e2fsprogs"
    /// hint. cocker-init also carries an in-guest mkfs fallback for images
    /// that bundle e2fsprogs, but formatting host-side keeps the common
    /// case fast and self-contained.
    static func createFormatted(at url: URL, size: UInt64) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw CockerError.requestFailed(
                "create ext4 image \(url.path): \(String(cString: strerror(errno)))")
        }
        let rc = ftruncate(fd, off_t(size))
        close(fd)
        guard rc == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw CockerError.requestFailed(
                "ftruncate ext4 image: \(String(cString: strerror(errno)))")
        }

        guard let mke2fs = mke2fsPath() else {
            try? FileManager.default.removeItem(at: url)
            throw CockerError.requestFailed(
                "mke2fs not found — run `brew install e2fsprogs` to build images " +
                "(the build rootfs upper is a native ext4 disk image, PRO-73)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mke2fs)
        proc.arguments = ["-t", "ext4", "-F", "-q", url.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw CockerError.requestFailed(
                "mke2fs failed (exit \(proc.terminationStatus)) on \(url.path)")
        }
    }
}
