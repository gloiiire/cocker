import Testing
import Foundation
@testable import CockerCore

@Suite("Log rotator")
struct LogRotatorTests {
    private func mkTmpFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-log-\(UUID().uuidString).log")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func shouldNotRotateBelowThreshold() throws {
        let f = try mkTmpFile(String(repeating: "x", count: 100))
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(LogRotator.shouldRotate(file: f, maxBytes: 1024) == false)
    }

    @Test func shouldRotateAboveThreshold() throws {
        let f = try mkTmpFile(String(repeating: "x", count: 2048))
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(LogRotator.shouldRotate(file: f, maxBytes: 1024) == true)
    }

    @Test func shouldNotRotateMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-missing-\(UUID().uuidString).log")
        #expect(LogRotator.shouldRotate(file: missing, maxBytes: 1) == false)
    }

    @Test func rotatePromotesCurrentToOne() throws {
        let f = try mkTmpFile("hello\n")
        defer {
            try? FileManager.default.removeItem(at: f)
            try? FileManager.default.removeItem(at: f.appendingPathExtension("1"))
        }

        try LogRotator.rotate(file: f, keep: 3)

        // Current is now empty
        let attrs = try FileManager.default.attributesOfItem(atPath: f.path)
        #expect((attrs[.size] as? NSNumber)?.intValue == 0)

        // .1 carries the old content
        let rotated = try String(contentsOf: f.appendingPathExtension("1"))
        #expect(rotated == "hello\n")
    }

    @Test func rotateShiftsAllNumberedCopies() throws {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-log-\(UUID().uuidString).log")
        try "current".write(to: f, atomically: true, encoding: .utf8)
        try "old1".write(to: f.appendingPathExtension("1"), atomically: true, encoding: .utf8)
        try "old2".write(to: f.appendingPathExtension("2"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: f)
            for i in 1...4 { try? FileManager.default.removeItem(at: f.appendingPathExtension("\(i)")) }
        }

        try LogRotator.rotate(file: f, keep: 4)

        #expect(try String(contentsOf: f.appendingPathExtension("1")) == "current")
        #expect(try String(contentsOf: f.appendingPathExtension("2")) == "old1")
        #expect(try String(contentsOf: f.appendingPathExtension("3")) == "old2")
        #expect(!FileManager.default.fileExists(atPath: f.appendingPathExtension("4").path))
    }

    @Test func rotateDropsOldestBeyondKeep() throws {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-log-\(UUID().uuidString).log")
        try "current".write(to: f, atomically: true, encoding: .utf8)
        try "old1".write(to: f.appendingPathExtension("1"), atomically: true, encoding: .utf8)
        try "old2".write(to: f.appendingPathExtension("2"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: f)
            for i in 1...3 { try? FileManager.default.removeItem(at: f.appendingPathExtension("\(i)")) }
        }

        try LogRotator.rotate(file: f, keep: 2)

        // .1 = current, .2 = old1, old2 dropped
        #expect(try String(contentsOf: f.appendingPathExtension("1")) == "current")
        #expect(try String(contentsOf: f.appendingPathExtension("2")) == "old1")
        #expect(!FileManager.default.fileExists(atPath: f.appendingPathExtension("3").path))
    }

    @Test func rotateWithKeepZeroIsNoOp() throws {
        let f = try mkTmpFile("hello")
        defer { try? FileManager.default.removeItem(at: f) }
        try LogRotator.rotate(file: f, keep: 0)
        // File still there, content unchanged.
        #expect(try String(contentsOf: f) == "hello")
    }
}
