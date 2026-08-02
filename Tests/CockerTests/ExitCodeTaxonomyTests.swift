import Foundation
import Testing
import ArgumentParser
import CockerCore
@testable import CockerCLI

/// `docs/UX-CHARTER.md` and `CockerError.exitCode` document a taxonomy —
/// 127 no-such-object, 126 found-but-not-runnable, 125 cocker-itself-failed.
/// The top-level handler honours it for errors that propagate, but most
/// commands caught the error to print the charter §6 failure block and then
/// threw `ExitCode.failure`, flattening every one of them to 1. A script
/// branching on the exit code — the stated reason the taxonomy exists —
/// couldn't tell "no such container" from "the daemon is down".
@Suite("Exit code taxonomy")
struct ExitCodeTaxonomyTests {

    @Test func theDocumentedCodesAreWhatTheySay() {
        #expect(CockerError.containerNotFound("x").exitCode == 127)
        #expect(CockerError.imageNotFound("x").exitCode == 127)
        #expect(CockerError.volumeNotFound("x").exitCode == 127)
        #expect(CockerError.permissionDenied("x").exitCode == 126)
        #expect(CockerError.notImplemented("x").exitCode == 126)
        #expect(CockerError.daemonNotRunning.exitCode == 125)
        #expect(CockerError.vmStartFailed("x").exitCode == 125)
        // Anything without a defined meaning stays a plain failure.
        #expect(CockerError.invalidComposeFile("x").exitCode == 1)
    }

    // MARK: - The accumulator

    @Test func noFailureMeansNothingToThrow() throws {
        let failures = FailureCode()
        #expect(!failures.hasFailure)
        #expect(failures.exitCode == nil)
        #expect(throws: Never.self) { try failures.throwIfFailed() }
    }

    @Test func aSingleFailureKeepsItsCode() {
        let failures = FailureCode()
        failures.record(.containerNotFound("web"))
        #expect(failures.hasFailure)
        #expect(failures.exitCode?.rawValue == 127)
    }

    @Test func agreeingFailuresKeepTheirSharedCode() {
        let failures = FailureCode()
        failures.record(.containerNotFound("a"))
        failures.record(.imageNotFound("b"))   // also 127
        #expect(failures.exitCode?.rawValue == 127)
    }

    /// A mixed batch has no single honest answer, so it reports a plain
    /// failure rather than picking one arbitrarily.
    @Test func aMixedBatchFallsBackToOne() {
        let failures = FailureCode()
        failures.record(.containerNotFound("a"))  // 127
        failures.record(.daemonNotRunning)        // 125
        #expect(failures.exitCode?.rawValue == 1)
    }

    @Test func throwIfFailedThrowsTheAccumulatedCode() {
        let failures = FailureCode()
        failures.record(.permissionDenied("x"))
        do {
            try failures.throwIfFailed()
            Issue.record("expected a throw")
        } catch let code as ExitCode {
            #expect(code.rawValue == 126)
        } catch {
            Issue.record("expected ExitCode, got \(error)")
        }
    }
}
