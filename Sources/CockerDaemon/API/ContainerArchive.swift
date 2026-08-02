import Foundation
import CockerCore

/// Docker's `/containers/{id}/archive` endpoints, which move a tar stream in
/// or out of a container's filesystem.
///
/// These were 501 even though the engine has always been able to copy files —
/// only the tar framing was missing. That gap is what stopped Dev Containers
/// from injecting the VS Code server, Testcontainers from calling
/// `copyFileToContainer`, and `docker cp` from working at all.
///
/// Framing goes through the host's `tar`. Re-implementing the format in
/// Swift would buy nothing: bsdtar ships with macOS, the build path already
/// depends on tar in the guest, and a hand-rolled writer is a long tail of
/// sparse-file, hardlink and long-name bugs waiting to corrupt someone's data.
enum ContainerArchive {

    /// `PathStat`, base64-JSON in the `X-Docker-Container-Path-Stat` header.
    /// Clients read it to decide whether the target is a directory before
    /// deciding how to unpack.
    struct PathStat: Encodable {
        let name: String
        let size: Int64
        let mode: UInt32
        let mtime: String
        let linkTarget: String

        enum CodingKeys: String, CodingKey {
            case name, size, mode, mtime, linkTarget
        }
        // Docker capitalises these on the wire.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: RawKey.self)
            try c.encode(name, forKey: RawKey(stringValue: "name")!)
            try c.encode(size, forKey: RawKey(stringValue: "size")!)
            try c.encode(mode, forKey: RawKey(stringValue: "mode")!)
            try c.encode(mtime, forKey: RawKey(stringValue: "mtime")!)
            try c.encode(linkTarget, forKey: RawKey(stringValue: "linkTarget")!)
        }
        struct RawKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }
    }

    static func stat(of url: URL) -> PathStat? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        // Docker sets Go's os.ModeDir bit (1<<31) for directories; clients
        // test it to decide whether to unpack into or over the target.
        var mode = UInt32((attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644)
        if isDir { mode |= 1 << 31 }
        return PathStat(
            name: url.lastPathComponent,
            size: Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0),
            mode: mode,
            mtime: rfc3339Nano((attrs[.modificationDate] as? Date) ?? Date()),
            linkTarget: (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
        )
    }

    static func statHeader(for url: URL) -> String? {
        guard let stat = stat(of: url),
              let json = try? JSONEncoder().encode(stat) else { return nil }
        return json.base64EncodedString()
    }

    /// Tar `url` the way Docker does: the archive's single top-level entry is
    /// the basename of the requested path, so the client can unpack it
    /// wherever it likes.
    static func pack(_ url: URL) throws -> Data {
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        return try runTar(["-cf", "-", "-C", parent, name], captureStdout: true) ?? Data()
    }

    /// Extract `tarball` into `directory`, creating it if needed.
    static func unpack(_ tarball: Data, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-archive-\(UUID().uuidString).tar")
        try tarball.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try runTar(["-xf", scratch.path, "-C", directory.path], captureStdout: false)
    }

    private static func runTar(_ arguments: [String], captureStdout: Bool) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        let outPipe = captureStdout ? Pipe() : nil
        if let outPipe { process.standardOutput = outPipe }

        try process.run()
        // Read before waiting: a large archive fills the pipe buffer and the
        // child blocks forever if we wait first.
        let out = outPipe.map { $0.fileHandleForReading.readDataToEndOfFile() }
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw CockerError.requestFailed("tar failed: \(message)")
        }
        return out
    }
}
