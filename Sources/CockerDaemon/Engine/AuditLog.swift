import Foundation
import CockerCore

/// **A1 — extracted from ContainerEngine**.
///
/// Append-only audit trail at `~/.cocker/audit.log`. One JSON line per
/// container/network/volume lifecycle event so downstream tooling
/// (jq, vector, fluent-bit) can ingest it without parsing.
///
/// Reasons this lives in its own file :
///   * Single responsibility — formatting + rotation + perms enforcement
///     are orthogonal to container orchestration.
///   * Independently testable — no actor isolation, no engine references.
///   * Encapsulates the **B19 fix** : LogRotator recreates the active
///     log path at the umask default, so we re-apply 0o600 on every
///     write to keep the audit-trail readable by the daemon owner only.
public enum AuditLog {
    /// `~/.cocker/audit.log`. Hardcoded path so the audit destination
    /// is predictable for SOC tools that tail it.
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cocker/audit.log")
    }

    /// Rotation threshold (10 MB) — keeps the active file under a size
    /// where most editors / tail tools stay snappy.
    public static let rotationThreshold = 10 * 1024 * 1024

    /// Rotated file generations to retain.
    public static let retainedGenerations = 5

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public struct Entry: Codable, Sendable {
        public let ts: String
        public let user: String
        public let type: String
        public let action: String
        public let id: String
    }

    public static func write(type: String, action: String, id: String) {
        let path = defaultURL
        let user = ProcessInfo.processInfo.environment["USER"] ?? "?"
        let entry: [String: String] = [
            "ts":     isoFormatter.string(from: Date()),
            "user":   user,
            "type":   type,
            "action": action,
            "id":     id,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = (String(data: data, encoding: .utf8).map { $0 + "\n" })?
                            .data(using: .utf8)
        else { return }
        let parent = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path.path, contents: line,
                attributes: [.posixPermissions: 0o600])
        }
        // **B19 fix** : LogRotator.rotate() recreates the active log at
        // umask-default mode (often 0o644) ; re-assert 0o600 here so the
        // window where another user could read freshly-rotated audit
        // entries is zero.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: path.path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int, size > rotationThreshold {
            try? LogRotator.rotate(file: path, keep: retainedGenerations)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                     ofItemAtPath: path.path)
        }
    }
}
