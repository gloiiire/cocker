import Foundation
import Crypto
import CockerCore

/// Identity of the environment that executes `RUN` steps.
///
/// A cached build layer records the filesystem changes a `RUN` produced
/// *under one specific runtime*. When that runtime changes, the same
/// command can legitimately produce a different layer, so replaying the
/// old one silently ships a wrong image.
///
/// The bug this guards against was real : up to 0.7.13.13 `cocker-init`
/// mounted a tmpfs over `/run`, so `RUN mkdir -p /run/nginx` captured an
/// empty layer. 0.7.13.14 fixed the mount, but every machine that had
/// already built the step kept replaying the empty layer from cache and
/// nginx still failed with `open() "/run/nginx/nginx.pid" failed`. The
/// only escape was a manual `--no-cache`, which nobody can be expected
/// to guess.
///
/// The fingerprint therefore folds in everything that decides what a
/// `RUN` observes and yields :
///   - the initrd (`cocker-init`), i.e. the guest-side runtime ;
///   - the kernel it boots ;
///   - the build strategy (ext4-overlay vs the legacy host-diff path) ;
///   - `epoch`, a manual lever for host-side capture changes.
///
/// It is stored inside each cache entry rather than mixed into the cache
/// key, so a stale entry can be recognised *and deleted* on lookup
/// instead of being orphaned on disk forever.
enum BuildRuntimeFingerprint {
    /// Bump when the host-side layer capture or replay changes shape
    /// (whiteout handling, opaque dirs, tar flags, ...) in a way that
    /// makes previously captured layers non-replayable. Guest-side
    /// changes are already covered by the initrd digest.
    static let epoch = 1

    /// Fold the epoch and every component into one hash. Pure and order
    /// sensitive, so it is directly unit-testable without any VM.
    static func compute(components: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("cocker-build-runtime-v\(epoch)\n".utf8))
        for component in components {
            hasher.update(data: Data((component + "\n").utf8))
        }
        return hasher.finalize().hexString
    }

    /// Content digest of a file that defines runtime behaviour.
    ///
    /// Unreadable is reported as a distinct marker rather than as an
    /// empty string : "the file is missing" and "the file is empty" must
    /// not collapse onto the same fingerprint.
    static func fileDigest(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "unreadable:" + url.lastPathComponent
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    /// Cheap identity used to decide whether a memoised digest is still
    /// valid : a file whose size and mtime are unchanged has not been
    /// rewritten by `brew upgrade`.
    struct FileStamp: Equatable {
        let size: Int
        let modified: TimeInterval

        init?(_ url: URL) {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]),
                let size = values.fileSize,
                let modified = values.contentModificationDate
            else { return nil }
            self.size = size
            self.modified = modified.timeIntervalSince1970
        }
    }

    /// Memoised digests, so a fingerprint costs one stat per file per
    /// build step instead of re-hashing a 14 MB kernel every time.
    /// Symlinks are resolved first : `~/.cocker/kernel/initrd.img` points
    /// into the Homebrew prefix, and that is the file `brew upgrade`
    /// actually replaces.
    private struct MemoKey: Hashable { let path: String }
    private nonisolated(unsafe) static var memo: [MemoKey: (stamp: FileStamp, digest: String)] = [:]
    private static let memoLock = NSLock()

    static func cachedFileDigest(_ url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath()
        let key = MemoKey(path: resolved.path)
        guard let stamp = FileStamp(resolved) else {
            return "unreadable:" + url.lastPathComponent
        }
        memoLock.lock()
        if let hit = memo[key], hit.stamp == stamp {
            memoLock.unlock()
            return hit.digest
        }
        memoLock.unlock()

        let digest = fileDigest(resolved)

        memoLock.lock()
        memo[key] = (stamp, digest)
        memoLock.unlock()
        return digest
    }

    /// Fingerprint for a build backed by `kernel` + `initrd`.
    static func forRuntime(kernel: URL, initrd: URL, legacyBuildPath: Bool) -> String {
        compute(components: [
            "initrd:" + cachedFileDigest(initrd),
            "kernel:" + cachedFileDigest(kernel),
            "path:" + (legacyBuildPath ? "legacy-host-diff" : "ext4-overlay"),
        ])
    }
}
