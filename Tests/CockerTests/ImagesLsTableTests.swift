import XCTest
@testable import CockerCLI

// Snapshot tests for `cocker images` charter §5 migration (PRO-31).

final class ImagesLsTableTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
    }

    private func table(rows: [UX.Table.Row]) -> UX.Table {
        UX.Table(
            columns: [
                .init("REPOSITORY", maxWidth: 40),
                .init("TAG", maxWidth: 20),
                .init("IMAGE ID", maxWidth: 12),
                .init("CREATED"),
                .init("SIZE", align: .right),
            ],
            rows: rows,
            emptyMessage: "no images — run `cocker pull <ref>` to fetch one or `cocker build` to build one"
        )
    }

    func testEmptyShowsCharterHint() {
        let out = table(rows: []).render()
        XCTAssertTrue(out.contains("no images"))
        XCTAssertTrue(out.contains("cocker pull"))
        XCTAssertTrue(out.contains("cocker build"))
        XCTAssertFalse(out.contains("REPOSITORY"), "empty state must not print the header")
    }

    func testPopulatedHasHeaderAndRows() {
        let rows: [UX.Table.Row] = [
            .init([
                .init("nginx"),
                .init("1.27"),
                .init("abc123def456", color: .accent),
                .init("3 hours ago", color: .dim),
                .init("142.0 MB", color: .dim),
            ]),
            .init([
                .init("postgres"),
                .init("16"),
                .init("fa9b21c4ee01", color: .accent),
                .init("2 days ago", color: .dim),
                .init("380.5 MB", color: .dim),
            ]),
        ]
        let out = table(rows: rows).render()
        XCTAssertTrue(out.contains("REPOSITORY"))
        XCTAssertTrue(out.contains("IMAGE ID"))
        XCTAssertTrue(out.contains("nginx"))
        XCTAssertTrue(out.contains("postgres"))
        XCTAssertTrue(out.contains("abc123def456"))
        XCTAssertEqual(out.split(separator: "\n").count, 3)
    }
}
