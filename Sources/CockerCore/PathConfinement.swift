import Foundation

/// Helpers that keep a daemon-controlled file operation inside a known root
/// directory. The two main attack surfaces these guard are :
///
///   1. **`cocker cp`** — `req.containerPath` arrives from a CLI client that
///      can be invoked by anyone with access to the daemon socket. A user
///      asking to copy `mycontainer:../../Users/victim/.ssh/id_rsa` would
///      otherwise see the daemon dutifully follow the path out of the
///      container rootfs and into the host's home directory.
///   2. **`seedFromImageIfFresh`** — `mount.destination` is read from the
///      OCI image config of whatever image the user pulled. A poisoned
///      image can declare a volume on `/../../../etc/passwd` and have the
///      daemon `cp -Rp` the image contents over those paths.
///
/// Both bugs come from `URL.appendingPathComponent` doing zero lexical
/// validation — it happily produces `<root>/../<somewhere-else>`. We resolve
/// the supplied path against the root, refuse any `..` that pops above it,
/// and (in the read flavour) also walk symlinks to make sure they don't
/// point outside the root.
public enum PathConfinement {

    /// Strictly lexical confinement : refuse paths that escape `root`
    /// through `..` traversal. Use this when writing — we don't want
    /// to require the destination to exist yet, but we do want to ensure
    /// the *resolved* destination lives below `root`. Symlinks inside
    /// `root` are not followed here ; if the caller cares about symlinks
    /// (e.g. when reading) it should use `confineRead` instead.
    public static func confine(_ rawPath: String, to root: URL) throws -> URL {
        let cleaned = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        var components: [String] = []
        for part in cleaned.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(part)
            if s == "." { continue }
            if s == ".." {
                guard !components.isEmpty else {
                    throw CockerError.permissionDenied(
                        "path escapes confined root via `..`: \(rawPath)")
                }
                components.removeLast()
                continue
            }
            // Reject embedded NUL — POSIX filenames forbid it and Foundation
            // truncates at the NUL so an attacker could otherwise smuggle in
            // "/etc\0/../../escape".
            if s.contains("\0") {
                throw CockerError.permissionDenied(
                    "path contains NUL byte: \(rawPath)")
            }
            components.append(s)
        }
        if components.isEmpty { return root }
        return root.appendingPathComponent(components.joined(separator: "/"))
    }

    /// Read-side confinement : on top of the lexical guard, resolve any
    /// symlinks on the result and verify the final target is still inside
    /// `root`. Without this an attacker who controls the container rootfs
    /// could plant a symlink (`/etc/sneaky → /Users/victim/.ssh/id_rsa`)
    /// and exfiltrate host files through `cocker cp`.
    public static func confineRead(_ rawPath: String, to root: URL) throws -> URL {
        let lexical = try confine(rawPath, to: root)
        let realResolved = lexical.resolvingSymlinksInPath().standardizedFileURL
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        let realPath = realResolved.path
        let rootPath = rootResolved.path
        if realPath == rootPath { return realResolved }
        // Tail slash discipline : `<root>` must be a strict prefix of the
        // resolved path AND the next byte must be the path separator,
        // otherwise `<rootfoo>/bar` would slip through when root is `<root>`.
        guard realPath.hasPrefix(rootPath + "/") else {
            throw CockerError.permissionDenied(
                "path resolves outside confined root via symlinks: \(rawPath)")
        }
        return realResolved
    }
}
