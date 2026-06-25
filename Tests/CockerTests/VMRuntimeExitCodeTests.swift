import XCTest
@testable import CockerDaemon

// PRO-52 — regression tests for the build-VM exit-code synthesis.
// Before this fix, a hung RUN that hit the 600 s timeout came back as
// exitCode = 0, the build "succeeded", and the resulting image was
// silently broken because the snapshotted layer only contained whatever
// the VM had managed to write before the kill.

final class VMRuntimeExitCodeTests: XCTestCase {

    // MARK: - Happy path: cocker-init wrote a marker, we trust it.

    func testParsedMarkerWinsRegardlessOfTimeout() {
        XCTAssertEqual(VMRuntime.synthesizeExitCode(parsed: 0,  timedOut: false), 0)
        XCTAssertEqual(VMRuntime.synthesizeExitCode(parsed: 1,  timedOut: false), 1)
        XCTAssertEqual(VMRuntime.synthesizeExitCode(parsed: 137, timedOut: false), 137)

        // Even if the host clock racing with cocker-init makes us think
        // we timed out — if cocker-init managed to print the marker
        // before VZ flipped to stopped, that's the authoritative answer.
        XCTAssertEqual(VMRuntime.synthesizeExitCode(parsed: 0, timedOut: true), 0,
            "an explicit marker overrides the timeout fallback")
    }

    // MARK: - Pre-PR-52 regression: no marker + timeout used to return 0.

    func testTimeoutWithoutMarkerReturns124() {
        XCTAssertEqual(VMRuntime.synthesizeExitCode(parsed: nil, timedOut: true), 124,
            "a force-stop on timeout must surface as 124 (GNU timeout convention), NOT 0")
    }

    // MARK: - VM died for unknown reasons (kernel oops, cocker-init crash).

    func testMissingMarkerWithoutTimeoutReturns125() {
        XCTAssertEqual(VMRuntime.synthesizeExitCode(parsed: nil, timedOut: false), 125,
            "no marker AND no timeout = abnormal VM exit, must surface as non-zero")
    }

    // MARK: - Boundary: synth never returns 0 when there's no marker.

    func testSynthAlwaysFailsWhenMarkerMissing() {
        for timedOut in [true, false] {
            let code = VMRuntime.synthesizeExitCode(parsed: nil, timedOut: timedOut)
            XCTAssertNotEqual(code, 0,
                "missing marker (timedOut=\(timedOut)) must NEVER paint as success")
        }
    }
}
