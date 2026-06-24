import XCTest
import CockerCore

// PRO-51 codec tests. The CLI sends `forceBuild: true` when the user
// passes `--build` ; the daemon must (a) round-trip it cleanly and
// (b) keep accepting payloads from older CLIs that don't send the
// field at all.

final class ComposeRequestForceBuildTests: XCTestCase {

    func testForceBuildRoundTrip() throws {
        let original = ComposeRequest(
            composePath: "/tmp/docker-compose.yml",
            projectName: "myapp",
            services: ["web", "db"],
            detach: true,
            forceBuild: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ComposeRequest.self, from: data)
        XCTAssertTrue(decoded.forceBuild, "forceBuild=true must survive encode/decode")
        XCTAssertEqual(decoded.composePath, original.composePath)
        XCTAssertEqual(decoded.projectName, original.projectName)
        XCTAssertEqual(decoded.services, original.services)
        XCTAssertEqual(decoded.detach, original.detach)
    }

    func testDefaultsToFalseInInit() {
        let r = ComposeRequest(composePath: "/x")
        XCTAssertFalse(r.forceBuild, "default initializer must leave forceBuild=false")
    }

    func testLegacyClientPayloadDecodesAsFalse() throws {
        // Simulate a pre-v0.7.10 CLI that doesn't know about forceBuild —
        // it sends a payload WITHOUT the field. The new daemon must accept
        // it and treat it as forceBuild=false.
        let legacyJSON = """
        {
          "composePath": "/tmp/docker-compose.yml",
          "projectName": "legacy",
          "services": [],
          "detach": false,
          "removeVolumes": false,
          "follow": false,
          "tail": 50
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ComposeRequest.self, from: legacyJSON)
        XCTAssertFalse(decoded.forceBuild, "missing field must default to false (legacy CLI compat)")
        XCTAssertEqual(decoded.projectName, "legacy")
    }

    func testEmptyPayloadStillDecodes() throws {
        // Minimal possible payload (just the required field). The decoder
        // tolerates missing optionals — same shape any old client could
        // send.
        let minimal = #"{"composePath":"/x"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ComposeRequest.self, from: minimal)
        XCTAssertFalse(decoded.forceBuild)
        XCTAssertFalse(decoded.detach)
        XCTAssertFalse(decoded.removeVolumes)
    }
}
