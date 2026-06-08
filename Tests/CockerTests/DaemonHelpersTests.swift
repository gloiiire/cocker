import Testing
import Foundation
import Darwin
@testable import CockerCore

@Suite("PIDFile — read")
struct PIDFileReadTests {
    private func mkTmp(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-pidtest-\(UUID().uuidString).pid")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func readsBareInteger() throws {
        let f = try mkTmp("12345")
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(PIDFile.read(f) == 12345)
    }

    @Test func tolerantToTrailingNewline() throws {
        let f = try mkTmp("4242\n")
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(PIDFile.read(f) == 4242)
    }

    @Test func tolerantToWhitespace() throws {
        let f = try mkTmp("  789 \n")
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(PIDFile.read(f) == 789)
    }

    @Test func nilOnMissingFile() {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-missing-\(UUID().uuidString).pid")
        #expect(PIDFile.read(f) == nil)
    }

    @Test func nilOnGarbage() throws {
        let f = try mkTmp("not a number")
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(PIDFile.read(f) == nil)
    }

    @Test func nilOnEmpty() throws {
        let f = try mkTmp("")
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(PIDFile.read(f) == nil)
    }

    @Test func nilOnZero() throws {
        let f = try mkTmp("0")
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(PIDFile.read(f) == nil)
    }

    @Test func nilOnNegative() throws {
        let f = try mkTmp("-5")
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(PIDFile.read(f) == nil)
    }
}

@Suite("PIDFile — write")
struct PIDFileWriteTests {
    @Test func writeAndReadBack() throws {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-write-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: f) }
        try PIDFile.write(31337, to: f)
        #expect(PIDFile.read(f) == 31337)
    }

    @Test func writeSelfPersistsCurrentPID() throws {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-writeself-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: f) }
        try PIDFile.writeSelf(to: f)
        #expect(PIDFile.read(f) == getpid())
    }

    @Test func overwritesExisting() throws {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-over-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: f) }
        try PIDFile.write(1, to: f)
        try PIDFile.write(2, to: f)
        #expect(PIDFile.read(f) == 2)
    }
}

@Suite("PIDFile — clear")
struct PIDFileClearTests {
    @Test func removesExistingFile() throws {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-clear-\(UUID().uuidString).pid")
        try PIDFile.write(99, to: f)
        #expect(FileManager.default.fileExists(atPath: f.path))
        PIDFile.clear(f)
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }

    @Test func clearOnMissingFileIsNoOp() {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-clear-missing-\(UUID().uuidString).pid")
        // Should not crash.
        PIDFile.clear(f)
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }
}

@Suite("PIDFile — isAlive")
struct PIDFileIsAliveTests {
    @Test func selfPIDIsAlive() {
        #expect(PIDFile.isAlive(getpid()) == true)
    }

    @Test func parentPIDIsAlive() {
        // Whatever spawned the test runner is alive (otherwise we'd be a
        // zombie reaped by init).
        let parent = getppid()
        if parent > 0 {
            #expect(PIDFile.isAlive(parent) == true)
        }
    }

    @Test func unlikelyPIDIsDead() {
        // PIDs are 16-bit on macOS by default ; 999999 is well outside the
        // range. Test the dead path.
        #expect(PIDFile.isAlive(999_999) == false)
    }

    @Test func zeroIsNotAlive() {
        #expect(PIDFile.isAlive(0) == false)
    }

    @Test func negativeIsNotAlive() {
        #expect(PIDFile.isAlive(-1) == false)
    }
}

@Suite("PIDFile — liveFromFile convenience")
struct PIDFileLiveFromFileTests {
    @Test func returnsLivePIDWhenAlive() throws {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-live-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: f) }
        try PIDFile.write(getpid(), to: f)
        #expect(PIDFile.liveFromFile(f) == getpid())
    }

    @Test func nilWhenFileMissing() {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-live-missing-\(UUID().uuidString).pid")
        #expect(PIDFile.liveFromFile(f) == nil)
    }

    @Test func nilWhenPIDIsDead() throws {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-live-dead-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: f) }
        try PIDFile.write(999_999, to: f)
        #expect(PIDFile.liveFromFile(f) == nil)
    }
}

// MARK: - BinaryResolver

@Suite("BinaryResolver — explicit path takes precedence")
struct BinaryResolverExplicitTests {
    /// Build a temp directory tree with executable shims so the resolver
    /// can find them. Returns the root URL to clean up afterwards.
    private func mkExe(at url: URL) throws {
        try "#!/bin/sh\necho ok".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    @Test func explicitWinsWhenExecutable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-binres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let exe = tmp.appendingPathComponent("cockerd")
        try mkExe(at: exe)

        let found = BinaryResolver.find(name: "cockerd",
                                        explicit: exe.path,
                                        siblingTo: nil,
                                        prefixes: [],
                                        path: "")
        #expect(found == exe.path)
    }

    @Test func explicitFalseyFallsThrough() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-binres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Explicit points at a non-existent path → we fall through to PATH.
        let pathDir = tmp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
        let candidate = pathDir.appendingPathComponent("cockerd")
        try mkExe(at: candidate)

        let found = BinaryResolver.find(name: "cockerd",
                                        explicit: "/does/not/exist",
                                        siblingTo: nil,
                                        prefixes: [],
                                        path: pathDir.path)
        #expect(found == candidate.path)
    }
}

@Suite("BinaryResolver — sibling lookup")
struct BinaryResolverSiblingTests {
    @Test func findsCockerdNextToCocker() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-binres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Pretend cocker lives at tmp/cocker, cockerd lives at tmp/cockerd.
        let cocker  = tmp.appendingPathComponent("cocker")
        let cockerd = tmp.appendingPathComponent("cockerd")
        for u in [cocker, cockerd] {
            try "#!/bin/sh\nexit 0".write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: u.path
            )
        }

        let found = BinaryResolver.find(name: "cockerd",
                                        explicit: nil,
                                        siblingTo: cocker.path,
                                        prefixes: [],
                                        path: "")
        #expect(found == cockerd.path)
    }
}

@Suite("BinaryResolver — PATH lookup")
struct BinaryResolverPATHTests {
    @Test func walksPathSegmentsInOrder() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-binres-\(UUID().uuidString)")
        let firstDir  = tmp.appendingPathComponent("first")
        let secondDir = tmp.appendingPathComponent("second")
        for d in [tmp, firstDir, secondDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Only the SECOND dir has cockerd.
        let cockerd = secondDir.appendingPathComponent("cockerd")
        try "#!/bin/sh".write(to: cockerd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: cockerd.path
        )

        let found = BinaryResolver.find(
            name: "cockerd",
            explicit: nil,
            siblingTo: nil,
            prefixes: [],
            path: "\(firstDir.path):\(secondDir.path)"
        )
        #expect(found == cockerd.path)
    }

    @Test func returnsNilWhenAbsent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-binres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let found = BinaryResolver.find(
            name: "definitely-not-a-real-binary-xyz",
            explicit: nil,
            siblingTo: nil,
            prefixes: [],
            path: tmp.path
        )
        #expect(found == nil)
    }

    @Test func standardPrefixesAreDocker() {
        // The constant must include Apple Silicon Homebrew first then Intel.
        #expect(BinaryResolver.standardPrefixes.first == "/opt/homebrew/bin")
        #expect(BinaryResolver.standardPrefixes.contains("/usr/local/bin"))
    }
}

@Suite("BinaryResolver — non-executable files are ignored")
struct BinaryResolverIsExecutableTests {
    @Test func chmodForFileMustHaveXBit() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-binres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let f = tmp.appendingPathComponent("cockerd")
        // Create the file WITHOUT executable bits.
        try "#!/bin/sh".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: f.path
        )

        let found = BinaryResolver.find(name: "cockerd",
                                        explicit: f.path,
                                        siblingTo: nil,
                                        prefixes: [],
                                        path: "")
        #expect(found == nil)
    }
}
