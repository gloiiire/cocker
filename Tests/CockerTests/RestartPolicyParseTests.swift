import Foundation
import Testing
@testable import CockerCore

/// `restart: on-failure:5` silently became "never restart".
///
/// Every call site was `RestartPolicy(rawValue: raw) ?? .no`. `on-failure:5`
/// is valid compose and valid docker, and there is no such rawValue — so it
/// fell through to `.no`. Measured: a compose service declaring
/// `restart: on-failure:5` came back from `cocker inspect` as
/// `"restartPolicy": "no"`.
///
/// The same `?? .no` swallowed typos: `--restart alwyas` produced a container
/// that never restarted, and said nothing. A restart policy that quietly
/// means "never" is the failure mode you discover during an outage.
@Suite("RestartPolicy — parsing")
struct RestartPolicyParseTests {

    @Test func theFourPlainPoliciesParse() throws {
        #expect(try RestartPolicy.parse("no").policy == .no)
        #expect(try RestartPolicy.parse("always").policy == .always)
        #expect(try RestartPolicy.parse("on-failure").policy == .onFailure)
        #expect(try RestartPolicy.parse("unless-stopped").policy == .unlessStopped)
    }

    @Test func aPlainPolicyCarriesNoCeiling() throws {
        #expect(try RestartPolicy.parse("on-failure").maxRetries == nil)
        #expect(try RestartPolicy.parse("always").maxRetries == nil)
    }

    /// The form that used to disable restarts entirely.
    @Test func onFailureTakesAMaximum() throws {
        let parsed = try RestartPolicy.parse("on-failure:5")
        #expect(parsed.policy == .onFailure)
        #expect(parsed.maxRetries == 5)
    }

    @Test func aZeroMaximumIsMeaningfulAndKept() throws {
        // `on-failure:0` means "on-failure, never actually retry". Distinct
        // from `no`, and the engine's `attempts < cap` handles it.
        let parsed = try RestartPolicy.parse("on-failure:0")
        #expect(parsed.policy == .onFailure)
        #expect(parsed.maxRetries == 0)
    }

    @Test func surroundingWhitespaceIsTolerated() throws {
        #expect(try RestartPolicy.parse("  always  ").policy == .always)
    }

    @Test func emptyMeansNo() throws {
        #expect(try RestartPolicy.parse("").policy == .no)
    }

    // MARK: - what must be refused rather than downgraded

    @Test func aTypoIsRefused() {
        #expect(throws: CockerError.self) { try RestartPolicy.parse("alwyas") }
        #expect(throws: CockerError.self) { try RestartPolicy.parse("on_failure") }
    }

    /// Only on-failure takes a count. `always:3` is not a docker form, and
    /// accepting it would imply a ceiling that nothing enforces.
    @Test func aCountOnAnyOtherPolicyIsRefused() {
        #expect(throws: CockerError.self) { try RestartPolicy.parse("always:3") }
        #expect(throws: CockerError.self) { try RestartPolicy.parse("unless-stopped:1") }
    }

    @Test func aNonNumericOrNegativeCountIsRefused() {
        #expect(throws: CockerError.self) { try RestartPolicy.parse("on-failure:many") }
        #expect(throws: CockerError.self) { try RestartPolicy.parse("on-failure:-1") }
        #expect(throws: CockerError.self) { try RestartPolicy.parse("on-failure:") }
    }

    /// The point of refusing: the caller has to see it. A hint that names
    /// the accepted forms is what turns the refusal into something fixable.
    @Test func theRefusalNamesTheAcceptedForms() {
        let p = CockerError.invalidRestartPolicy("alwyas").presentation
        #expect(p.headline.contains("alwyas"))
        #expect(p.hint?.contains("on-failure:<max>") == true)
    }

    /// Containers persisted before the ceiling existed must still decode,
    /// and must not claim a ceiling nobody set.
    @Test func stateWrittenBeforeTheCeilingStillDecodes() throws {
        let legacy = #"{"id":"abc123","name":"web","image":"alpine","restartPolicy":"on-failure"}"#
        let c = try JSONDecoder().decode(Container.self, from: Data(legacy.utf8))
        #expect(c.restartPolicy == .onFailure)
        #expect(c.restartMaxRetries == nil)
    }
}
