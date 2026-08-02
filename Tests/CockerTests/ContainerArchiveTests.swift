import Foundation
import Testing
import CockerCore
@testable import CockerDaemon

/// `/containers/{id}/archive` was 501 even though the engine could already
/// copy files — only the tar framing was missing. That gap stopped Dev
/// Containers from injecting the VS Code server, Testcontainers from calling
/// `copyFileToContainer`, and `docker cp` from working at all.
@Suite("Container archive (docker cp)")
struct ContainerArchiveTests {

    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Round trip

    @Test func packsAndUnpacksAFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("hello.txt")
        try "bonjour".write(to: source, atomically: true, encoding: .utf8)

        let tarball = try ContainerArchive.pack(source)
        #expect(!tarball.isEmpty)

        let destination = root.appendingPathComponent("out")
        try ContainerArchive.unpack(tarball, into: destination)
        let landed = destination.appendingPathComponent("hello.txt")
        #expect(try String(contentsOf: landed, encoding: .utf8) == "bonjour")
    }

    /// Docker's contract: the archive's single top-level entry is the
    /// *basename* of the requested path, so the client can unpack it
    /// anywhere. Packing the absolute path instead would land the whole
    /// directory chain in the destination.
    @Test func topLevelEntryIsTheBasename() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("a/b/payload")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "x".write(to: nested.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let destination = root.appendingPathComponent("out")
        try ContainerArchive.unpack(try ContainerArchive.pack(nested), into: destination)
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("payload/f.txt").path))
    }

    @Test func roundTripsADirectoryTree() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try "one".write(to: tree.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: tree.appendingPathComponent("sub/two.txt"), atomically: true, encoding: .utf8)

        let destination = root.appendingPathComponent("out")
        try ContainerArchive.unpack(try ContainerArchive.pack(tree), into: destination)
        #expect(try String(contentsOf: destination.appendingPathComponent("tree/sub/two.txt"),
                           encoding: .utf8) == "two")
    }

    @Test func packingAMissingPathFails() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try ContainerArchive.pack(root.appendingPathComponent("nope"))
        }
    }

    /// A body that isn't a tar has to fail rather than quietly writing
    /// nothing and reporting success.
    @Test func unpackingGarbageFails() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try ContainerArchive.unpack(Data("not a tar archive at all".utf8),
                                        into: root.appendingPathComponent("out"))
        }
    }

    // MARK: - PathStat header

    @Test func statDescribesAFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try "abcd".write(to: file, atomically: true, encoding: .utf8)

        let stat = try #require(ContainerArchive.stat(of: file))
        #expect(stat.name == "f.txt")
        #expect(stat.size == 4)
        // Not a directory: Go's os.ModeDir bit must be clear.
        #expect(stat.mode & (1 << 31) == 0)
    }

    /// Clients test the directory bit to decide whether to unpack into the
    /// target or over it, so it has to be set the way Go sets it.
    @Test func statSetsTheDirectoryBit() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let stat = try #require(ContainerArchive.stat(of: root))
        #expect(stat.mode & (1 << 31) != 0)
    }

    @Test func statOfAMissingPathIsNil() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ContainerArchive.stat(of: root.appendingPathComponent("nope")) == nil)
    }

    /// The header is base64 JSON — clients decode it directly.
    @Test func headerIsDecodableBase64JSON() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        let header = try #require(ContainerArchive.statHeader(for: file))
        let decoded = try #require(Data(base64Encoded: header))
        let json = try #require(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        #expect(json["name"] as? String == "f.txt")
        #expect(json["size"] as? Int == 2)
        #expect(json["mtime"] != nil)
    }
}
