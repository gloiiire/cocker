import Testing
import Foundation
@testable import CockerCLI
@testable import CockerCore

// Covers the pure, deterministic parts of the shared interactive-footer
// primitive (Sources/CockerCLI/UX/InteractiveFooter.swift): the footer-line
// builder and the URL scraper. The raw-mode / key-task / termios glue is
// terminal-bound and exercised manually, not here.

@Suite("footerLines — builder")
struct FooterLinesTests {
    @Test func detachOnlyHintForViewers() {
        // Pure viewers (logs/events) started nothing → `d` (detach) only.
        let lines = footerLines(detach: true)
        #expect(lines.count == 1)
        #expect(lines[0].contains("detach"))
        #expect(!lines[0].contains("quit"))
    }

    @Test func detachAndQuitHintForStartCommands() {
        let lines = footerLines(detach: true, quit: true)
        #expect(lines.count == 1)
        #expect(lines[0].contains("detach"))
        #expect(lines[0].contains("quit"))
    }

    @Test func noHintWhenNeitherKey() {
        #expect(footerLines().isEmpty)
    }

    @Test func headerAndStatusAndServicesRendered() {
        let lines = footerLines(
            header: ["HEAD"],
            services: [(name: "api", url: "http://localhost:8000"),
                       (name: "web_1", url: "http://localhost:3000")],
            status: ["STAT"],
            detach: true, quit: true)
        // header + 2 service rows + status + hint
        #expect(lines.count == 5)
        #expect(lines[0] == "HEAD")
        #expect(lines[1].contains("api"))
        #expect(lines[1].contains("http://localhost:8000"))
        #expect(lines[2].contains("web_1"))
        #expect(lines[2].contains("http://localhost:3000"))
        #expect(lines[3] == "STAT")
        #expect(lines[4].contains("quit"))
    }

    @Test func serviceNamesPaddedToLongest() {
        let lines = footerLines(
            services: [(name: "a", url: "u1"), (name: "longname", url: "u2")],
            detach: true)
        // Both service rows should align the URL at the same column: the
        // short name is padded to the longest name's width.
        let row1 = lines[0]
        let row2 = lines[1]
        #expect(row1.range(of: "u1")!.lowerBound == row2.range(of: "u2")!.lowerBound)
    }
}

@Suite("ServiceURLs — scraper")
struct ServiceURLsTests {
    @Test func scrapesStartedLine() {
        let u = ServiceURLs()
        u.capture(fromStdout: " Container memoire_m2_api_1 Started (id: 68b4647532b6)  -> http://localhost:8000\n")
        let s = u.snapshot()
        #expect(s.count == 1)
        #expect(s[0].name == "memoire_m2_api_1")
        #expect(s[0].url == "http://localhost:8000")
    }

    @Test func ignoresNonStartedLines() {
        let u = ServiceURLs()
        u.capture(fromStdout: "Step 4/11 : COPY x .\n")
        u.capture(fromStdout: " ---> Created layer sha256:abc (1 KB)\n")
        #expect(u.snapshot().isEmpty)
    }

    @Test func buffersAcrossChunkBoundaries() {
        let u = ServiceURLs()
        // The " -> URL" arrives split across two stdout chunks.
        u.capture(fromStdout: " Container web_1 Started (id: aa)  -> http://localh")
        #expect(u.snapshot().isEmpty)  // no newline yet → not parsed
        u.capture(fromStdout: "ost:3000\n")
        let s = u.snapshot()
        #expect(s.count == 1)
        #expect(s[0].url == "http://localhost:3000")
    }

    @Test func lastWriteWinsPerServiceKeepingOrder() {
        let u = ServiceURLs()
        u.capture(fromStdout: " Container a Started (id: 1)  -> http://localhost:1\n")
        u.capture(fromStdout: " Container b Started (id: 2)  -> http://localhost:2\n")
        u.capture(fromStdout: " Container a Started (id: 3)  -> http://localhost:9\n")
        let s = u.snapshot()
        #expect(s.map { $0.name } == ["a", "b"])   // insertion order preserved
        #expect(s[0].url == "http://localhost:9")  // updated in place
    }

    @Test func initFromExplicitPairsAndAdd() {
        let u = ServiceURLs(pairs: [(name: "x", url: "http://localhost:5")])
        u.add(name: "y", url: "http://localhost:6")
        u.add(name: "x", url: "http://localhost:7")  // overwrite, keep order
        let s = u.snapshot()
        #expect(s.map { $0.name } == ["x", "y"])
        #expect(s[0].url == "http://localhost:7")
    }
}

@Suite("InteractiveFooter / RawMode — non-TTY paths")
struct InteractiveFooterNonTTYTests {
    // In the test process stdin/stdout are not a terminal, so RawMode.enter()
    // is a no-op and InteractiveFooter.animated is false. These calls must be
    // safe (no raw-mode side effects, no stdin blocking) and cover the guard
    // branches.
    @Test func rawModeIsNoOpOffTTY() {
        let r = RawMode()
        r.enter()    // isatty == 0 → no-op
        r.restore()  // not active → no-op
    }

    @Test func footerLifecycleOffTTYDoesNotBlock() {
        let f = InteractiveFooter()
        // The gate we actually care about runs in CI (no PTY) where animated
        // is false; guard so a local TTY run doesn't put the terminal in raw
        // mode or spawn a stdin reader.
        if !f.animated {
            f.start(footer: { footerLines(detach: true, quit: true) })
            f.clear()
            f.refresh()
            f.restore()
        }
    }

    /// Off-TTY the streaming view must be a plain pass-through, so
    /// `logs -f | grep` keeps working.
    @Test func streamingViewOffTTYWritesStraightThrough() {
        let f = InteractiveFooter()
        if !f.animated {
            let view = StreamingLogView(footer: f)
            view.emit(StreamEvent(stream: .stdout, data: "line\n"))
            view.emitLine("event")
            view.finish()
        }
    }

    /// A continuous viewer must print no key hint when there is no keyboard.
    /// Switching `logs -f` from armStreaming (silent off-TTY) to start()
    /// (which prints the footer once) put "press d detach" at the top of
    /// `cocker logs -f > file`, right in the middle of piped output.
    /// `plainFallback: false` is what keeps a pipe clean.
    ///
    /// Asserted on the pure rule rather than on captured stdout: the suite
    /// runs in parallel, so redirecting the process-wide fd steals output
    /// from whichever test happens to run alongside.
    @Test func continuousViewerPrintsNoHintOffTTY() {
        let hint = footerLines(detach: true)
        #expect(!hint.isEmpty, "the footer must be non-empty for this test to mean anything")
        #expect(InteractiveFooter.plainOutput(footer: hint, plainFallback: false).isEmpty,
                "a piped viewer must emit no footer")
    }

    /// The one-shot summary keeps its plain fallback: `compose up` off-TTY
    /// still reports the URLs it just started.
    @Test func oneShotSummaryStillPrintsOffTTY() {
        let summary = ["   service   http://localhost:8080"]
        #expect(InteractiveFooter.plainOutput(footer: summary, plainFallback: true) == summary)
    }
}
