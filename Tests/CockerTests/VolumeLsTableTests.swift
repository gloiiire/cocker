import XCTest
@testable import CockerCLI

// Snapshot tests for `cocker volume ls` charter §5 migration (PRO-29).
// The command itself round-trips through the daemon, but the table shape
// is a pure function of the rows + columns — we exercise that directly.

final class VolumeLsTableTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
    }

    private func table(rows: [UX.Table.Row]) -> UX.Table {
        UX.Table(
            columns: [
                .init("DRIVER"),
                .init("VOLUME NAME"),
                .init("CREATED"),
                .init("MOUNTPOINT"),
            ],
            rows: rows,
            emptyMessage: "no volumes — run `cocker volume create <name>` to add one"
        )
    }

    func testEmptyShowsCharterHint() {
        let out = table(rows: []).render()
        XCTAssertTrue(out.contains("no volumes"),
                      "empty state must mention the entity (\"no volumes\") per charter §5")
        XCTAssertTrue(out.contains("cocker volume create"),
                      "empty state must point the user at the next-step command")
        // §5 mandates only a single dim italic line — no header.
        XCTAssertFalse(out.contains("DRIVER"),
                       "empty state must not print the header")
    }

    func testPopulatedHasHeaderAndRows() {
        let rows: [UX.Table.Row] = [
            .init([
                .init("local", color: .dim),
                .init("myapp_data"),
                .init("3 hours ago", color: .dim),
                .init("/var/lib/cocker/volumes/myapp_data", color: .dim),
            ]),
            .init([
                .init("local", color: .dim),
                .init("pgdata"),
                .init("2 days ago", color: .dim),
                .init("/var/lib/cocker/volumes/pgdata", color: .dim),
            ]),
        ]
        let out = table(rows: rows).render()
        XCTAssertTrue(out.contains("DRIVER"))
        XCTAssertTrue(out.contains("VOLUME NAME"))
        XCTAssertTrue(out.contains("myapp_data"))
        XCTAssertTrue(out.contains("pgdata"))
        XCTAssertTrue(out.contains("/var/lib/cocker/volumes/myapp_data"))
        // header + 2 data rows = 3 lines
        XCTAssertEqual(out.split(separator: "\n").count, 3)
    }
}
