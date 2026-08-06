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

    @Test func runDisclosesItsInertFlags() {
        let text = help(RunCommand.self)
        for flag in ["--read-only", "--dns", "--dns-search", "--add-host", "--tmpfs"] {
            // The flag is still offered — removing it would break scripts.
            #expect(text.contains(flag), "\(flag) disappeared from run --help")
        }
        // One disclosure per inert flag. Counting rather than substring-matching
        // each line keeps this honest if the wording changes.
        let disclosures = text.components(separatedBy: "Not honoured").count - 1
        #expect(disclosures >= 5,
                "run --help discloses \(disclosures) inert flags, expected at least 5")
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
