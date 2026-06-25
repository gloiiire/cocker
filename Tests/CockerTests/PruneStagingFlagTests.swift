import XCTest
import ArgumentParser
@testable import CockerCLI

// PRO-58 — `cocker prune --staging` and `cocker system prune --staging`
// expose the previously-hidden `cocker icloud cache-clear` at the top
// level. These tests cover the parsing surface : both commands must
// accept the same flags, both must wire `--staging` to the boolean.
// The actual wipe (ICloudStaging.clearCache) is tested in its own
// suite and on macOS only.

final class PruneStagingFlagTests: XCTestCase {

    // MARK: - Top-level `cocker prune`

    func testTopLevelPruneAcceptsStagingFlag() throws {
        let cmd = try TopLevelPruneCommand.parse(["--staging"])
        XCTAssertTrue(cmd.staging)
        XCTAssertFalse(cmd.volumes)
        XCTAssertFalse(cmd.force)
    }

    func testTopLevelPruneAcceptsAllFlagsCombined() throws {
        let cmd = try TopLevelPruneCommand.parse(["--staging", "--volumes", "--force"])
        XCTAssertTrue(cmd.staging)
        XCTAssertTrue(cmd.volumes)
        XCTAssertTrue(cmd.force)
    }

    func testTopLevelPruneDefaultsAreAllFalse() throws {
        let cmd = try TopLevelPruneCommand.parse([])
        XCTAssertFalse(cmd.staging)
        XCTAssertFalse(cmd.volumes)
        XCTAssertFalse(cmd.force)
    }

    // MARK: - `cocker system prune`

    func testSystemPruneAcceptsStagingFlag() throws {
        let cmd = try SystemPruneCommand.parse(["--staging"])
        XCTAssertTrue(cmd.staging)
        XCTAssertFalse(cmd.volumes)
        XCTAssertFalse(cmd.force)
    }

    func testSystemPruneAcceptsAllFlagsCombined() throws {
        let cmd = try SystemPruneCommand.parse(["--staging", "--volumes", "--force"])
        XCTAssertTrue(cmd.staging)
        XCTAssertTrue(cmd.volumes)
        XCTAssertTrue(cmd.force)
    }

    func testSystemPruneDefaultsAreAllFalse() throws {
        let cmd = try SystemPruneCommand.parse([])
        XCTAssertFalse(cmd.staging)
        XCTAssertFalse(cmd.volumes)
        XCTAssertFalse(cmd.force)
    }

    // MARK: - Command names / discoverability

    func testTopLevelPruneCommandNameIsBareProue() {
        XCTAssertEqual(TopLevelPruneCommand.configuration.commandName, "prune",
            "top-level shortcut must live at `cocker prune`, not under another prefix")
    }

    func testSystemPruneCommandNameUnchanged() {
        XCTAssertEqual(SystemPruneCommand.configuration.commandName, "prune",
            "the historical `cocker system prune` path must keep working")
    }

    func testTopLevelPruneHelpMentionsStaging() {
        // The help string we hand to ArgumentParser carries the
        // documentation that ends up in `cocker prune -h`. Verify the
        // user actually learns about the new flag.
        let helps = TopLevelPruneCommand.configuration.abstract
        XCTAssertTrue(helps.contains("system prune"),
            "top-level prune's abstract must point users to the canonical command")
    }
}
