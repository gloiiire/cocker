import Foundation
import ArgumentParser
import CockerCore

/// Remembers why a command failed, so the process exit code keeps the meaning
/// the failure had.
///
/// `docs/UX-CHARTER.md` and `CockerError.exitCode` document a taxonomy —
/// 127 no-such-object, 126 found-but-not-runnable, 125 cocker-itself-failed —
/// and `CockerCLI`'s top-level handler honours it for errors that propagate.
/// But most commands catch the error to print the charter §6 failure block,
/// then `throw ExitCode.failure`, flattening every one of them to 1. A script
/// branching on the exit code — which is the stated reason the taxonomy
/// exists — could not tell "no such container" from "the daemon is down".
///
/// Multi-target commands keep Docker's behaviour of reporting one status for
/// the whole invocation: the first failure's code wins when every failure
/// agrees, and a mixed batch falls back to 1 because no single code describes
/// it honestly.
final class FailureCode {
    private var code: Int32?
    private var mixed = false

    var hasFailure: Bool { code != nil }

    func record(_ error: CockerError) {
        let incoming = error.exitCode
        guard let existing = code else { code = incoming; return }
        if existing != incoming { mixed = true }
    }

    /// Nothing to throw when every target succeeded.
    var exitCode: ExitCode? {
        guard let code else { return nil }
        return ExitCode(mixed ? 1 : code)
    }

    /// `try failures.throwIfFailed()` at the end of a loop.
    func throwIfFailed() throws {
        if let exitCode { throw exitCode }
    }
}
