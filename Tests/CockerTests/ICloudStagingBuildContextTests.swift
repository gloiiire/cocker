import XCTest
@testable import CockerCLI

// PRO-41 regression : the iCloud staging step must auto-include every
// service's `build.context:` so a sibling `.dockerignore` rule that
// excludes that directory (e.g. root `.dockerignore` listing `frontend/`)
// doesn't silently strip the service's Dockerfile from the staged copy.

final class ICloudStagingBuildContextTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-staging-bctx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, _ content: String = "x") throws -> String {
        let url = tempDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func mkdir(_ relPath: String) throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(relPath), withIntermediateDirectories: true)
    }

    // MARK: - Long form: build: { context: ... }

    func testLongFormContextDetected() throws {
        try mkdir("frontend")
        try mkdir("backend")
        _ = try write("frontend/Dockerfile")
        _ = try write("backend/Dockerfile")
        let compose = try write("docker-compose.yml", """
        services:
          backend:
            build:
              context: ./backend
              dockerfile: Dockerfile
          frontend:
            build:
              context: ./frontend
              dockerfile: Dockerfile
        """)

        let ctxs = Set(ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path))
        XCTAssertEqual(ctxs, ["backend", "frontend"])
    }

    // MARK: - Short form: build: ./dir

    func testShortFormContextDetected() throws {
        try mkdir("api")
        let compose = try write("docker-compose.yml", """
        services:
          api:
            build: ./api
        """)
        let ctxs = ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path)
        XCTAssertEqual(ctxs, ["api"])
    }

    func testShortFormWithoutDotSlash() throws {
        try mkdir("worker")
        let compose = try write("docker-compose.yml", """
        services:
          worker:
            build: worker
        """)
        let ctxs = ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path)
        XCTAssertEqual(ctxs, ["worker"])
    }

    // MARK: - Filtering / safety

    func testNonExistentContextIsFiltered() throws {
        // build.context references a directory that's not on disk —
        // we shouldn't emit a `+` rule for it (no point protecting a
        // path that doesn't exist; rsync would just no-op anyway).
        let compose = try write("docker-compose.yml", """
        services:
          ghost:
            build: ./missing
        """)
        XCTAssertEqual(ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path), [])
    }

    func testAbsolutePathIsRejected() throws {
        try mkdir("real")
        let compose = try write("docker-compose.yml", """
        services:
          bad:
            build: /absolute/path
          good:
            build: ./real
        """)
        let ctxs = ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path)
        XCTAssertEqual(ctxs, ["real"])
    }

    func testParentEscapeRejected() throws {
        try mkdir("ok")
        let compose = try write("docker-compose.yml", """
        services:
          escape:
            build: ../sibling
          ok:
            build: ./ok
        """)
        let ctxs = ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path)
        XCTAssertEqual(ctxs, ["ok"])
    }

    func testRootContextIsIgnored() throws {
        // `build: .` = project root. Nothing to "protect" since the root
        // is the staging target itself. Returning it would emit `+ /`
        // which is meaningless to rsync.
        let compose = try write("docker-compose.yml", """
        services:
          monolith:
            build: .
        """)
        XCTAssertEqual(ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path), [])
    }

    func testQuotedContext() throws {
        try mkdir("api")
        let compose = try write("docker-compose.yml", """
        services:
          api:
            build: "./api"
        """)
        XCTAssertEqual(ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path), ["api"])
    }

    func testServiceWithoutBuildIgnored() throws {
        try mkdir("api")
        let compose = try write("docker-compose.yml", """
        services:
          db:
            image: postgres:16
          api:
            build: ./api
        """)
        XCTAssertEqual(ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path), ["api"])
    }

    func testTrailingSlashStripped() throws {
        try mkdir("svc")
        let compose = try write("docker-compose.yml", """
        services:
          svc:
            build: ./svc/
        """)
        XCTAssertEqual(ICloudStaging.collectBuildContextPaths(
            composePath: compose, projectDir: tempDir.path), ["svc"])
    }

    func testMissingComposeFileReturnsEmpty() {
        XCTAssertEqual(ICloudStaging.collectBuildContextPaths(
            composePath: tempDir.appendingPathComponent("nope.yml").path,
            projectDir: tempDir.path), [])
    }
}
