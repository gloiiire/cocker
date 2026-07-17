import Testing
import Foundation
@testable import CockerCore
@testable import CockerCLI

// PRO-76 — the error-UX contract: CockerError's §6 presentation split,
// the Docker-style exit-code map, and the streaming FailFlag latch.
@Suite("CockerError presentation (§6 what/why/hint)")
struct CockerErrorPresentationTests {
    @Test func daemonDownSplitsIntoReasonAndHint() {
        let p = CockerError.daemonNotRunning.presentation
        #expect(p.headline == "Cannot connect to cockerd")
        #expect(p.reason == "the daemon isn't running")
        #expect(p.hint == "start it with `cockerd`")
    }

    @Test func setupErrorsHintAtCockerdSetup() {
        #expect(CockerError.kernelNotFound("/x").presentation.hint == "run `cockerd setup`")
        #expect(CockerError.initrdNotFound("/x").presentation.hint == "run `cockerd setup`")
    }

    @Test func buildFailedLiftsMessageIntoReason() {
        let p = CockerError.buildFailed("RUN foo exited 1").presentation
        #expect(p.headline == "Build failed")
        #expect(p.reason == "RUN foo exited 1")
        #expect(p.hint == nil)
    }

    @Test func imagePullAndPermissionAndSpecs() {
        #expect(CockerError.imagePullFailed("alpine", "no route").presentation.headline == "Failed to pull alpine")
        #expect(CockerError.imagePullFailed("alpine", "no route").presentation.reason == "no route")
        #expect(CockerError.permissionDenied("/etc").presentation.headline == "Permission denied")
        #expect(CockerError.invalidPortMapping("80").presentation.hint == "expected `host:container`")
        #expect(CockerError.invalidVolumeSpec("a").presentation.hint == "expected `source:dest[:ro]`")
    }

    @Test func daemonMessageSplitsOnLeadingFailedPrefix() {
        // "Build failed: …" → headline / reason
        let split = CockerError.daemon("Build failed: RUN pip exited 1").presentation
        #expect(split.headline == "Build failed")
        #expect(split.reason == "RUN pip exited 1")
        // A message that doesn't end in "failed" before the colon stays whole.
        let whole = CockerError.daemon("something: else here").presentation
        #expect(whole.headline == "something: else here")
        #expect(whole.reason == nil)
        // No colon at all → verbatim headline.
        let bare = CockerError.daemon("plain message").presentation
        #expect(bare.headline == "plain message")
    }

    @Test func defaultFallsBackToDescription() {
        let p = CockerError.containerNotFound("web").presentation
        #expect(p.headline == "No such container: web")
        #expect(p.reason == nil)
        #expect(p.hint == nil)
    }
}

@Suite("CockerError exit codes (Docker 125/126/127)")
struct CockerErrorExitCodeTests {
    @Test func noSuchObjectIs127() {
        #expect(CockerError.containerNotFound("a").exitCode == 127)
        #expect(CockerError.imageNotFound("a").exitCode == 127)
        #expect(CockerError.networkNotFound("a").exitCode == 127)
        #expect(CockerError.volumeNotFound("a").exitCode == 127)
        #expect(CockerError.manifestNotFound("a").exitCode == 127)
        #expect(CockerError.dockerfileNotFound("a").exitCode == 127)
    }

    @Test func notRunnableIs126() {
        #expect(CockerError.permissionDenied("x").exitCode == 126)
    }

    @Test func cockerItselfIs125() {
        #expect(CockerError.daemonNotRunning.exitCode == 125)
        #expect(CockerError.connectionFailed("x").exitCode == 125)
        #expect(CockerError.kernelNotFound("x").exitCode == 125)
        #expect(CockerError.vmStartFailed("x").exitCode == 125)
        #expect(CockerError.vmCommunicationFailed("x").exitCode == 125)
    }

    @Test func everythingElseIs1() {
        #expect(CockerError.buildFailed("x").exitCode == 1)
        #expect(CockerError.daemon("x").exitCode == 1)
        #expect(CockerError.diskFull.exitCode == 1)
        #expect(CockerError.internalError("x").exitCode == 1)
    }

    @Test func daemonCaseDescriptionHasNoPrefix() {
        // The whole point of `.daemon` — no "Request failed:" wrapper.
        #expect(CockerError.daemon("Build failed: X").description == "Build failed: X")
    }
}

@Suite("UX.FailFlag — streaming failure latch")
struct FailFlagTests {
    @Test func startsUntripped() {
        #expect(UX.FailFlag().tripped == false)
    }

    @Test func tripSetsIt() {
        let f = UX.FailFlag()
        f.trip()
        #expect(f.tripped == true)
    }

    @Test func throwIfTrippedThrowsOnlyWhenTripped() throws {
        let clean = UX.FailFlag()
        // Not tripped → no throw.
        try clean.throwIfTripped()

        let dirty = UX.FailFlag()
        dirty.trip()
        var threw = false
        do { try dirty.throwIfTripped() } catch { threw = true }
        #expect(threw)
    }
}
