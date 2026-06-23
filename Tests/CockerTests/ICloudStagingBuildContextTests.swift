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

    // MARK: - End-to-end rsync semantics (PRO-41 regression)

    /// Drives the actual filter rules through rsync to make sure the v2
    /// version of the fix — `+ /<ctx>` only, no `+ /<ctx>/**` — both
    /// (a) survives a sibling `.dockerignore` excluding the context dir,
    /// and (b) doesn't shadow descendant excludes like `node_modules`.
    /// Skipped if `/usr/bin/rsync` is unavailable (shouldn't happen on
    /// any macOS / Linux CI runner cocker targets, but harmless).
    func testRsyncRespectsBuildContextProtectionWithoutLeakingNodeModules() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync") else {
            throw XCTSkip("rsync not available on this machine")
        }
        // Source tree: a "real" project with one service whose context is
        // ./frontend, plus a root .dockerignore that would exclude the
        // entire frontend directory if cocker didn't intervene. And a
        // node_modules INSIDE frontend that MUST NOT leak into staging.
        try mkdir("frontend")
        try mkdir("frontend/node_modules/lodash")
        _ = try write("frontend/Dockerfile", "FROM node:20\n")
        _ = try write("frontend/package.json", "{}\n")
        _ = try write("frontend/node_modules/lodash/index.js", "// noise\n")
        _ = try write(".dockerignore", "frontend/\n**/node_modules/\n")

        // Simulate cocker's rules: + /frontend first, then the defaults
        // (which include `**/node_modules/`), then root .dockerignore
        // patterns. Matches what stageIfNeeded constructs.
        let filterFile = tempDir.appendingPathComponent("filter").path
        // rsync's --filter file requires every rule prefixed with `+ ` or
        // `- ` — same wrapping `stageIfNeeded` does at runtime.
        try [
            "+ /frontend",
            "- **/node_modules/",
            "- frontend/",
        ].joined(separator: "\n").write(toFile: filterFile, atomically: true, encoding: .utf8)

        let staging = tempDir.appendingPathComponent("_staged")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        proc.arguments = [
            "-a", "--delete",
            "--filter=. \(filterFile)",
            tempDir.path + "/", staging.path + "/",
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            XCTFail("rsync failed (\(proc.terminationStatus)): \(err)")
            return
        }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("frontend/Dockerfile").path),
                      "PR-41 fix: frontend/Dockerfile must survive the root `frontend/` exclude")
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("frontend/package.json").path),
                      "other top-level files in the build context must also survive")
        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("frontend/node_modules").path),
                       "node_modules inside the build context must STILL be excluded — the include rule should not be recursive")
    }
}
