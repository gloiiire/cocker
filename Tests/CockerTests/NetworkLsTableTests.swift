import XCTest
@testable import CockerCLI

// Snapshot tests for `cocker network ls` charter §5 migration (PRO-30).

final class NetworkLsTableTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
    }

    private func table(rows: [UX.Table.Row]) -> UX.Table {
        UX.Table(
            columns: [
                .init("NETWORK ID", maxWidth: 12),
                .init("NAME", maxWidth: 30),
                .init("DRIVER"),
                .init("SCOPE"),
                .init("SUBNET"),
            ],
            rows: rows,
            emptyMessage: "no networks — run `cocker network create <name>` to add one"
        )
    }

    func testEmptyShowsCharterHint() {
        let out = table(rows: []).render()
        XCTAssertTrue(out.contains("no networks"))
        XCTAssertTrue(out.contains("cocker network create"))
        XCTAssertFalse(out.contains("NETWORK ID"), "empty state must not print the header")
    }

    func testPopulatedHasHeaderAndRows() {
        let rows: [UX.Table.Row] = [
            .init([
                .init("abc123def456", color: .accent),
                .init("bridge"),
                .init("bridge", color: .dim),
                .init("local", color: .dim),
                .init("172.20.0.0/16", color: .dim),
            ]),
            .init([
                .init("fa9b21c4ee01", color: .accent),
                .init("myapp_default"),
                .init("bridge", color: .dim),
                .init("local", color: .dim),
                .init("172.21.0.0/16", color: .dim),
            ]),
        ]
        let out = table(rows: rows).render()
        XCTAssertTrue(out.contains("NETWORK ID"))
        XCTAssertTrue(out.contains("NAME"))
        XCTAssertTrue(out.contains("abc123def456"))
        XCTAssertTrue(out.contains("myapp_default"))
        XCTAssertTrue(out.contains("172.20.0.0/16"))
        XCTAssertEqual(out.split(separator: "\n").count, 3)
    }
}
