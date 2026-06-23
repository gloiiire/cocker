import XCTest
import CockerCore
@testable import CockerCLI

// Tests for `cocker ps` charter §5 migration (PRO-32) — both the STATUS
// text (no ANSI) and the per-state color mapping.

final class PSStatusTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
    }

    private func make(
        status: ContainerStatus,
        exitCode: Int32? = nil,
        startedAt: Date? = nil,
        healthcheck: Healthcheck? = nil,
        healthStatus: HealthStatus = .none
    ) -> Container {
        var c = Container(
            name: "test",
            image: "nginx:1.27",
            command: [],
            status: status,
            healthStatus: healthStatus,
            healthcheck: healthcheck
        )
        c.exitCode = exitCode
        c.startedAt = startedAt
        return c
    }

    // MARK: - Color mapping per charter §5

    func testColorRunning_success() {
        XCTAssertEqual(PSCommand.statusColor(make(status: .running, startedAt: Date())), .success)
    }

    func testColorStoppedCleanExit_dim() {
        XCTAssertEqual(PSCommand.statusColor(make(status: .stopped, exitCode: 0)), .dim)
    }

    func testColorStoppedNonZero_failure() {
        XCTAssertEqual(PSCommand.statusColor(make(status: .stopped, exitCode: 137)), .failure)
    }

    func testColorStoppedUnknownExit_failure() {
        // nil exit code → treat as failure (host crashed mid-run)
        XCTAssertEqual(PSCommand.statusColor(make(status: .stopped, exitCode: nil)), .failure)
    }

    func testColorCreated_dim() {
        XCTAssertEqual(PSCommand.statusColor(make(status: .created)), .dim)
    }

    func testColorPaused_warn() {
        XCTAssertEqual(PSCommand.statusColor(make(status: .paused)), .warn)
    }

    func testColorRestarting_warn() {
        XCTAssertEqual(PSCommand.statusColor(make(status: .restarting)), .warn)
    }

    func testColorDead_failure() {
        XCTAssertEqual(PSCommand.statusColor(make(status: .dead)), .failure)
    }

    // MARK: - Health overrides on running containers

    func testColorRunningUnhealthy_warn() {
        let c = make(
            status: .running,
            startedAt: Date(),
            healthcheck: Healthcheck(test: ["CMD", "true"]),
            healthStatus: .unhealthy
        )
        XCTAssertEqual(PSCommand.statusColor(c), .warn)
    }

    func testColorRunningHealthy_success() {
        let c = make(
            status: .running,
            startedAt: Date(),
            healthcheck: Healthcheck(test: ["CMD", "true"]),
            healthStatus: .healthy
        )
        XCTAssertEqual(PSCommand.statusColor(c), .success)
    }

    func testColorRunningHealthStarting_warn() {
        let c = make(
            status: .running,
            startedAt: Date(),
            healthcheck: Healthcheck(test: ["CMD", "true"]),
            healthStatus: .starting
        )
        XCTAssertEqual(PSCommand.statusColor(c), .warn)
    }

    // MARK: - STATUS text (no ANSI baked in)

    func testTextNoAnsiCodes() {
        // Ensure none of the branches still bake ANSI escape codes into the
        // status string — UX.Table cell coloring is the only path for color.
        let states: [(ContainerStatus, Int32?)] = [
            (.running, nil), (.stopped, 0), (.stopped, 1), (.created, nil),
            (.paused, nil), (.restarting, nil), (.dead, nil),
        ]
        for (status, exit) in states {
            let txt = PSCommand.statusText(make(status: status, exitCode: exit, startedAt: Date()))
            XCTAssertFalse(txt.contains("\u{001B}"), "statusText(\(status)) leaked ANSI: \(txt)")
        }
    }

    func testTextStoppedIncludesExitCode() {
        XCTAssertEqual(PSCommand.statusText(make(status: .stopped, exitCode: 137)), "Exited (137)")
        XCTAssertEqual(PSCommand.statusText(make(status: .stopped, exitCode: 0)), "Exited (0)")
    }

    func testTextRunningWithHealthSuffix() {
        let c = make(
            status: .running,
            startedAt: Date(),
            healthcheck: Healthcheck(test: ["CMD", "true"]),
            healthStatus: .unhealthy
        )
        XCTAssertTrue(PSCommand.statusText(c).contains("(unhealthy)"))
    }

    func testTextRunningWithoutHealthcheckOmitsSuffix() {
        let c = make(status: .running, startedAt: Date())
        let txt = PSCommand.statusText(c)
        XCTAssertTrue(txt.hasPrefix("Up "))
        XCTAssertFalse(txt.contains("healthy"))
    }

    // MARK: - Empty state shape

    func testEmptyTableShowsCharterHint() {
        let table = UX.Table(
            columns: [.init("CONTAINER ID")],
            rows: [],
            emptyMessage: "no containers — run `cocker run <image>` to create one"
        )
        let out = table.render()
        XCTAssertTrue(out.contains("no containers"))
        XCTAssertFalse(out.contains("CONTAINER ID"), "empty state must not print the header")
    }
}
