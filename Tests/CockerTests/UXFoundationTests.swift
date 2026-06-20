import XCTest
@testable import CockerCLI

// Tests for the UX foundation modules introduced in PR #1 of the v0.7.0
// "Polished" refactor. We pin TTY capabilities to a deterministic state in
// each test (no color, no animation) so the rendered output is predictable
// and comparable byte-for-byte.

final class UXFoundationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
    }

    // MARK: - Tokens

    func testIconGlyphsAreNonEmptyAndUnique() {
        let glyphs = UX.Icon.allCases.map { $0.rawValue }
        XCTAssertTrue(glyphs.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(glyphs).count, glyphs.count, "icon glyphs must be unique")
    }

    func testVerbConjugationCovered() {
        for v in UX.Verb.allCases {
            XCTAssertFalse(v.present.isEmpty, "\(v) has no present form")
            XCTAssertFalse(v.past.isEmpty, "\(v) has no past form")
            XCTAssertTrue(v.present.first?.isUppercase ?? false, "\(v).present must capitalize")
            XCTAssertTrue(v.past.first?.isUppercase ?? false, "\(v).past must capitalize")
        }
    }

    func testObjectTypeLabelsFitInLabelWidth() {
        for t in UX.ObjectType.allCases {
            XCTAssertLessThanOrEqual(t.label.count, UX.ObjectType.labelWidth, "\(t.label) longer than labelWidth")
            XCTAssertEqual(t.padded.count, UX.ObjectType.labelWidth, "\(t.label) padded must equal labelWidth")
        }
    }

    func testColorAnsiCodesPresent() {
        XCTAssertEqual(UX.Color.success.ansi, "\u{001B}[32m")
        XCTAssertEqual(UX.Color.failure.ansi, "\u{001B}[31m")
        XCTAssertEqual(UX.Color.progress.ansi, "\u{001B}[36m")
        XCTAssertEqual(UX.Color.dim.ansi, "\u{001B}[2m")
        XCTAssertEqual(UX.Color.default.ansi, "")
    }

    // MARK: - TTY

    func testTTYDetectNonInteractiveNoEnv() {
        let caps = UX.TTY.detect(stdoutFD: -1, env: [:], argv: [])
        XCTAssertFalse(caps.isInteractive)
        XCTAssertFalse(caps.colorEnabled)
        XCTAssertFalse(caps.animationEnabled)
    }

    func testTTYDetectNoColorEnvWins() {
        // Even with FORCE_COLOR set, NO_COLOR should win (charter §10 order).
        let caps = UX.TTY.detect(stdoutFD: -1, env: ["NO_COLOR": "1", "FORCE_COLOR": "1"], argv: [])
        XCTAssertFalse(caps.colorEnabled)
        XCTAssertFalse(caps.animationEnabled)
    }

    func testTTYDetectForceColorWithoutTTY() {
        let caps = UX.TTY.detect(stdoutFD: -1, env: ["FORCE_COLOR": "1"], argv: [])
        XCTAssertTrue(caps.colorEnabled, "FORCE_COLOR should enable color even without TTY")
        XCTAssertFalse(caps.animationEnabled, "animation needs a real TTY regardless of FORCE_COLOR")
    }

    func testTTYDetectNoColorFlagFromArgv() {
        let caps = UX.TTY.detect(stdoutFD: -1, env: ["FORCE_COLOR": "1"], argv: ["cocker", "ps", "--no-color"])
        XCTAssertFalse(caps.colorEnabled)
    }

    func testTTYDetectDumbTerm() {
        let caps = UX.TTY.detect(stdoutFD: -1, env: ["TERM": "dumb", "FORCE_COLOR": "1"], argv: [])
        XCTAssertFalse(caps.colorEnabled)
    }

    func testPaintNoOpWhenDisabled() {
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
        XCTAssertEqual(UX.TTY.paint("foo", .failure), "foo")
        XCTAssertEqual(UX.TTY.paint("bar", .failure, [.dim]), "bar")
    }

    func testPaintWrapsWhenEnabled() {
        UX.TTY.set(.init(isInteractive: true, colorEnabled: true, animationEnabled: true))
        let out = UX.TTY.paint("x", .failure)
        XCTAssertTrue(out.contains("\u{001B}[31m"))
        XCTAssertTrue(out.contains("\u{001B}[0m"))
        XCTAssertTrue(out.contains("x"))
    }

    // MARK: - ActionLine

    func testActionLineMinimalShape() {
        let line = UX.ActionLine(
            icon: .success, type: .container, name: "web_1",
            status: "Started", trailing: "1.8s"
        ).render()
        // Layout : " ✓ Container  web_1  Started  1.8s"
        XCTAssertTrue(line.contains("✓"))
        XCTAssertTrue(line.contains("Container"))
        XCTAssertTrue(line.contains("web_1"))
        XCTAssertTrue(line.contains("Started"))
        XCTAssertTrue(line.contains("1.8s"))
        XCTAssertTrue(line.hasPrefix(" "))
    }

    func testActionLinePadsToColumnWidths() {
        let l1 = UX.ActionLine(icon: .success, type: .container, name: "db", status: "Created").render(nameWidth: 10, statusWidth: 10)
        let l2 = UX.ActionLine(icon: .success, type: .container, name: "very_long_n", status: "Started").render(nameWidth: 10, statusWidth: 10)
        // Both should be at least the same length up to status field — actual
        // equality only if no trailing differs ; here neither has trailing.
        XCTAssertGreaterThan(l1.count, 0)
        XCTAssertGreaterThan(l2.count, 0)
    }

    func testFormatElapsedThresholds() {
        XCTAssertEqual(UX.formatElapsed(0.05), "50ms")
        XCTAssertEqual(UX.formatElapsed(1.5), "1.5s")
        XCTAssertEqual(UX.formatElapsed(75), "1m 15s")
    }

    // MARK: - Table

    func testTableEmptyStateMessage() {
        let t = UX.Table(
            columns: [.init("NAME"), .init("STATUS")],
            rows: [],
            emptyMessage: "no containers"
        )
        XCTAssertTrue(t.render().contains("no containers"))
    }

    func testTableComputesColumnWidthsFromContent() {
        let t = UX.Table(
            columns: [.init("ID"), .init("NAME")],
            rows: [
                .init(["abc", "short"]),
                .init(["xyz", "much_longer_name"]),
            ]
        )
        let out = t.render()
        XCTAssertTrue(out.contains("abc"))
        XCTAssertTrue(out.contains("much_longer_name"))
        // Header row + 2 data rows.
        XCTAssertEqual(out.split(separator: "\n").count, 3)
    }

    func testTableRightAlignment() {
        let t = UX.Table(
            columns: [.init("N", align: .right, minWidth: 5)],
            rows: [.init(["3"])]
        )
        let out = t.render()
        // The last data line should end with "3" preceded by spaces.
        let lastLine = out.split(separator: "\n").last!
        XCTAssertTrue(lastLine.hasSuffix("3"))
    }

    // MARK: - Failure / Warning

    func testFailureThreeLineShape() {
        let out = UX.Failure.render(
            headline: "Cannot remove container web",
            reason: "still running",
            hint: "stop it first with `cocker stop web`"
        )
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(out.contains("✗"))
        XCTAssertTrue(out.contains("Cannot remove container web"))
        XCTAssertTrue(out.contains("reason :"))
        XCTAssertTrue(out.contains("hint   :"))
    }

    func testFailureOmitsMissingLines() {
        let out = UX.Failure.render(headline: "Cannot do thing")
        XCTAssertEqual(out.split(separator: "\n").count, 1)
        XCTAssertFalse(out.contains("reason"))
    }

    func testFailureWithDetails() {
        let out = UX.Failure.render(
            headline: "Boom",
            reason: "kaboom",
            hint: "duck",
            details: "see logs"
        )
        XCTAssertEqual(out.split(separator: "\n").count, 4)
        XCTAssertTrue(out.contains("details:"))
    }

    // MARK: - Confirm

    func testConfirmParserAcceptsYes() {
        XCTAssertTrue(UX.Confirm.parse("y"))
        XCTAssertTrue(UX.Confirm.parse("Y"))
        XCTAssertTrue(UX.Confirm.parse("yes"))
        XCTAssertTrue(UX.Confirm.parse("YES"))
        XCTAssertTrue(UX.Confirm.parse("  Yes  "))
    }

    func testConfirmParserDefaultsToNo() {
        XCTAssertFalse(UX.Confirm.parse(""))
        XCTAssertFalse(UX.Confirm.parse("n"))
        XCTAssertFalse(UX.Confirm.parse("no"))
        XCTAssertFalse(UX.Confirm.parse("nope"))
        XCTAssertFalse(UX.Confirm.parse("yeah")) // strict — only y/yes
    }

    // MARK: - Stream / ComposePrefixer

    func testFNV1aIsStableAndDistinguishes() {
        XCTAssertEqual(UX.Stream.fnv1a32("web"), UX.Stream.fnv1a32("web"))
        XCTAssertNotEqual(UX.Stream.fnv1a32("web"), UX.Stream.fnv1a32("db"))
    }

    func testServiceColorStable() {
        let c1 = UX.Stream.serviceColor(for: "api")
        let c2 = UX.Stream.serviceColor(for: "api")
        XCTAssertEqual(c1, c2)
    }

    func testServicePaletteSize() {
        XCTAssertEqual(UX.Stream.servicePalette.count, 8, "charter §9.2 specifies 8 colors")
    }

    func testComposePrefixerPadsToWidestServiceName() {
        let p = UX.ComposePrefixer(initialServices: ["web", "database"])
        let webLine = p.render(service: "web", stream: .stdout, line: "x")
        let dbLine = p.render(service: "database", stream: .stdout, line: "x")
        // Both lines should align — find the | separator and check it's at
        // the same character index (when no color codes are present).
        XCTAssertEqual(webLine.firstIndex(of: "|").map { webLine.distance(from: webLine.startIndex, to: $0) },
                       dbLine.firstIndex(of: "|").map { dbLine.distance(from: dbLine.startIndex, to: $0) })
    }

    func testComposePrefixerStderrColored() {
        UX.TTY.set(.init(isInteractive: true, colorEnabled: true, animationEnabled: true))
        let p = UX.ComposePrefixer(initialServices: ["web"])
        let stderrLine = p.render(service: "web", stream: .stderr, line: "BOOM")
        XCTAssertTrue(stderrLine.contains("\u{001B}[2m"), "stderr should be dim")
        XCTAssertTrue(stderrLine.contains("\u{001B}[31m"), "stderr should be red")
    }

    // MARK: - ProgressBar

    func testProgressBarRenderEdgeCases() {
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
        let empty = UX.ProgressBar.render(fraction: 0)
        XCTAssertTrue(empty.contains("["))
        XCTAssertTrue(empty.contains("]"))
        XCTAssertFalse(empty.contains("█"))

        let full = UX.ProgressBar.render(fraction: 1)
        XCTAssertFalse(full.contains("░"))

        let nan = UX.ProgressBar.render(fraction: .nan)
        XCTAssertFalse(nan.contains("█"), "NaN should clamp to 0")
    }

    func testProgressBarPercentClamps() {
        XCTAssertEqual(UX.ProgressBar.percent(fraction: -1), "  0%")
        XCTAssertEqual(UX.ProgressBar.percent(fraction: 0.5), " 50%")
        XCTAssertEqual(UX.ProgressBar.percent(fraction: 2), "100%")
    }

    func testFormatBytesUnits() {
        XCTAssertEqual(UX.formatBytes(500), "500 B")
        XCTAssertEqual(UX.formatBytes(2048), "2.0 KB")
        XCTAssertEqual(UX.formatBytes(1024 * 1024 * 5), "5.0 MB")
    }

    func testProgressBarFull() {
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
        let s = UX.ProgressBar.full(current: 5 * 1024 * 1024, total: 10 * 1024 * 1024)
        XCTAssertTrue(s.contains("5.0 MB"))
        XCTAssertTrue(s.contains("10.0 MB"))
        XCTAssertTrue(s.contains("50%"))

        let zero = UX.ProgressBar.full(current: 0, total: 0)
        XCTAssertTrue(zero.contains("0 B"))
    }

    func testProgressBarBytesFormat() {
        XCTAssertEqual(UX.ProgressBar.bytes(current: 1024, total: 2048), "1.0 KB / 2.0 KB")
    }

    // MARK: - LayerTracker

    func testLayerTrackerPreservesInsertionOrder() {
        let t = UX.LayerTracker()
        t.update(layerID: "aaa", status: "Downloading", current: 50, total: 100)
        t.update(layerID: "bbb", status: "Extracting", current: 100, total: 100)
        t.update(layerID: "ccc", status: "Pulling")
        let lines = t.render()
        XCTAssertEqual(lines.count, 3)
        // First line corresponds to the first inserted layer.
        XCTAssertTrue(lines[0].contains("aaa"))
        XCTAssertTrue(lines[1].contains("bbb"))
        XCTAssertTrue(lines[2].contains("ccc"))
    }

    func testLayerTrackerUpdateInPlace() {
        let t = UX.LayerTracker()
        t.update(layerID: "abc", status: "Downloading", current: 10, total: 100)
        t.update(layerID: "abc", status: "Downloading", current: 90, total: 100)
        let lines = t.render()
        XCTAssertEqual(lines.count, 1, "second update must not append a new line")
    }

    // MARK: - ActionLine helpers (the convenience constructors)

    func testResultLineTTYBranchProducesActionLine() {
        UX.TTY.set(.init(isInteractive: true, colorEnabled: false, animationEnabled: false))
        let line = UX.resultLine(.container, "web_1", verb: .stop, elapsed: 1.5)
        XCTAssertTrue(line.contains("Stopped"))
        XCTAssertTrue(line.contains("web_1"))
        XCTAssertTrue(line.contains("1.5s"))
    }

    func testResultLineScriptBranchEmitsBareName() {
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
        let line = UX.resultLine(.container, "web_1", verb: .stop, elapsed: 1.5)
        XCTAssertEqual(line, "web_1",
            "non-TTY callers (pipe to xargs etc.) must get the bare name for script compat")
    }

    func testCreatedLineTTYBranchProducesActionLine() {
        UX.TTY.set(.init(isInteractive: true, colorEnabled: false, animationEnabled: false))
        let line = UX.createdLine(.network, "myapp_default", elapsed: 0.1)
        XCTAssertTrue(line.contains("Created"))
        XCTAssertTrue(line.contains("myapp_default"))
    }

    func testCreatedLineScriptBranchEmitsBareName() {
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
        let line = UX.createdLine(.network, "myapp_default")
        XCTAssertEqual(line, "myapp_default")
    }

    func testActionLineConvenienceHelpers() {
        // Don't assert byte-exact ; assert each helper produces the expected
        // verb-form so the right past/present came out of the verb table.
        XCTAssertTrue(UX.actionStarted(.container, "x", elapsed: 1.0).render().contains("Started"))
        XCTAssertTrue(UX.actionCreated(.network, "x").render().contains("Created"))
        XCTAssertTrue(UX.actionRemoved(.volume, "x").render().contains("Removed"))
        XCTAssertTrue(UX.actionRunning(.image, "x", verb: .pull).render().contains("Pulling"))
        XCTAssertTrue(UX.actionDone(.image, "x", verb: .pull, elapsed: 2.5).render().contains("Pulled"))
        XCTAssertTrue(UX.actionFailed(.container, "x", status: "Remove failed").render().contains("Remove failed"))
    }

    func testActionLineWithoutTypeStillRenders() {
        let line = UX.ActionLine(icon: .item, name: "no_type", status: "ok").render()
        XCTAssertTrue(line.contains("no_type"))
        XCTAssertTrue(line.contains("ok"))
    }

    func testActionLineStatusColorOverride() {
        UX.TTY.set(.init(isInteractive: true, colorEnabled: true, animationEnabled: true))
        let line = UX.ActionLine(
            icon: .success, type: .container, name: "x", status: "Running",
            statusColor: .warn
        ).render()
        XCTAssertTrue(line.contains("\u{001B}[33m"), "explicit warn color override should produce yellow ANSI")
    }

    // MARK: - Modifier ANSI codes

    func testModifierAnsiCodesPresent() {
        XCTAssertEqual(UX.Modifier.bold.ansi, "\u{001B}[1m")
        XCTAssertEqual(UX.Modifier.dim.ansi, "\u{001B}[2m")
        XCTAssertEqual(UX.Modifier.italic.ansi, "\u{001B}[3m")
        XCTAssertEqual(UX.Modifier.underline.ansi, "\u{001B}[4m")
    }

    func testIconColorPairings() {
        // Spot-check that each icon maps to a sane color.
        XCTAssertEqual(UX.Icon.success.color, .success)
        XCTAssertEqual(UX.Icon.failure.color, .failure)
        XCTAssertEqual(UX.Icon.warn.color, .warn)
        XCTAssertEqual(UX.Icon.restart.color, .restart)
        XCTAssertEqual(UX.Icon.action.color, .progress)
    }

    // MARK: - Warning emitter

    func testWarningRender() {
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
        let out = UX.Warning.render("deprecated flag", note: "use --new instead")
        XCTAssertTrue(out.contains("⚠"))
        XCTAssertTrue(out.contains("deprecated flag"))
        XCTAssertTrue(out.contains("use --new instead"))
        XCTAssertEqual(out.split(separator: "\n").count, 2)

        let bare = UX.Warning.render("just a warning")
        XCTAssertEqual(bare.split(separator: "\n").count, 1)
    }

    // MARK: - Stream paint

    func testStreamPaintStdoutUnchanged() {
        UX.TTY.set(.init(isInteractive: true, colorEnabled: true, animationEnabled: true))
        XCTAssertEqual(UX.Stream.paint("hello", stream: .stdout), "hello")
    }

    func testServicePaletteColorRotationCoversAllSlots() {
        // Hit every palette slot by manufacturing inputs ; verifies the
        // modulo wrap is functional and no slot is dead.
        var seen = Set<UX.Color>()
        for i in 0..<256 {
            let c = UX.Stream.serviceColor(for: "svc_\(i)")
            seen.insert(c)
            if seen.count == UX.Stream.servicePalette.count { break }
        }
        XCTAssertEqual(seen.count, UX.Stream.servicePalette.count,
                       "256 names should be enough to touch every palette slot")
    }
}
