import Foundation
import Testing
import ArgumentParser
@testable import CockerCLI

/// 1.0 commitment #1: "a flag that can't be honoured says so instead of being
/// ignored." Fourteen flags were breaking it — declared, listed in `--help`,
/// accepted, and read by nobody. Two measured before the fix:
///
///     $ cocker run --rm --read-only alpine sh -c 'touch /x && echo written'
///     written                                   ← root was writable
///     $ cocker run --rm --dns 1.1.1.1 alpine cat /etc/resolv.conf
///     nameserver 127.0.0.1                      ← never arrived
///
/// These lock the `--help` half of the contract. The runtime warning half
/// goes to stderr and is exercised by hand in the PR; what matters here is
/// that nobody quietly deletes the disclosure while the flag stays inert.
@Suite("Flags that are not honoured say so in --help")
struct IgnoredFlagHelpTests {

    private func help<C: ParsableCommand>(_ type: C.Type) -> String {
        C.helpMessage(columns: 200)
    }

    /// These five were the original disclosures. They are now implemented —
    /// read-only root, tmpfs mounts, extra /etc/hosts entries and DNS all
    /// reach the guest through the v7 spec — so the guarantee inverts: they
    /// must still be offered, and must NOT claim to be inert.
    ///
    /// Asserting the absence matters as much as the presence did. Leaving a
    /// "Not honoured" on a flag that works is the same defect pointed the
    /// other way, and it is the easy one to forget.
    @Test func runNoLongerDisclosesTheFlagsItNowHonours() {
        let text = help(RunCommand.self)
        for flag in ["--read-only", "--dns", "--dns-search", "--add-host", "--tmpfs"] {
            #expect(text.contains(flag), "\(flag) disappeared from run --help")
        }
        #expect(!text.contains("Not honoured"),
                "run --help still calls a flag inert after it was implemented")
    }

    @Test func pullDisclosesPlatform() {
        let text = help(PullCommand.self)
        #expect(text.contains("--platform"))
        #expect(text.contains("Not honoured"))
    }

    @Test func logsDisclosesSince() {
        let text = help(LogsCommand.self)
        #expect(text.contains("--since"))
        #expect(text.contains("Not honoured"))
    }

    @Test func rmiDisclosesForce() {
        let text = help(RmiCommand.self)
        #expect(text.contains("--force"))
        #expect(text.contains("Not honoured"))
    }
}
