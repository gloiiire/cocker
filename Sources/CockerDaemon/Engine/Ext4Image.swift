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

    /// Allocate a sparse `size`-byte file at `url` (ftruncate — costs only
    /// the bytes actually written on APFS). No filesystem yet.
    static func createSparse(at url: URL, size: UInt64) throws {
        // 0600 : same rationale as VolumeManager — the image is a raw
        // filesystem. open()'s mode is umask-masked, so fchmod pins it.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw CockerError.requestFailed(
                "create ext4 image \(url.path): \(String(cString: strerror(errno)))")
        }
        _ = fchmod(fd, 0o600)
        let rc = ftruncate(fd, off_t(size))
        close(fd)
        guard rc == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw CockerError.requestFailed(
                "ftruncate ext4 image: \(String(cString: strerror(errno)))")
        }
    }

    /// Format an existing image file ext4 with brew mke2fs. Throws if
    /// e2fsprogs isn't installed or mke2fs fails.
    static func format(at url: URL) throws {
        guard let mke2fs = mke2fsPath() else {
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
            throw CockerError.requestFailed(
                "mke2fs failed (exit \(proc.terminationStatus)) on \(url.path)")
        }
    }

    /// Create a sparse image and format it ext4 in one shot. Throws if
    /// e2fsprogs is missing — callers that can defer formatting to the
    /// guest (cocker-init's in-VM mkfs.ext4 fallback) should use
    /// createSparse + a guarded format() instead.
    static func createFormatted(at url: URL, size: UInt64) throws {
        try createSparse(at: url, size: size)
        do {
            try format(at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
