import Foundation
import Testing
@testable import CockerCLI

/// `--attach` is easy to get backwards. In Docker it RESTRICTS the set of
/// services whose logs are streamed — attaching is already the default for
/// a foreground `up`. Implementing it as "enable streaming for these" would
/// look right in a one-service demo and be wrong everywhere else.
@Suite("compose up --attach selection")
struct AttachSelectionTests {

    private let all = ["api", "web", "db"]

    // MARK: - Restriction

    @Test func noFlagsAttachesEverything() {
        #expect(AttachSelection.resolve(all: all, attach: [], noAttach: [])
            == ["api", "web", "db"])
    }

    @Test func attachRestrictsToTheNamedServices() {
        #expect(AttachSelection.resolve(all: all, attach: ["web"], noAttach: [])
            == ["web"])
    }

    @Test func attachAcceptsSeveralServices() {
        #expect(AttachSelection.resolve(all: all, attach: ["db", "api"], noAttach: [])
            == ["api", "db"], "order must follow the project, not the flags")
    }

    // MARK: - Exclusion

    @Test func noAttachRemovesFromTheFullSet() {
        #expect(AttachSelection.resolve(all: all, attach: [], noAttach: ["db"])
            == ["api", "web"])
    }

    @Test func noAttachAppliesAfterAttach() {
        #expect(AttachSelection.resolve(all: all,
                                        attach: ["api", "web"],
                                        noAttach: ["web"])
            == ["api"])
    }

    /// Excluding everything is legal but pointless — the caller warns
    /// rather than streaming an empty view forever.
    @Test func excludingEverythingYieldsNothing() {
        #expect(AttachSelection.resolve(all: all, attach: [], noAttach: all)
            .isEmpty)
    }

    /// A service named in both is excluded : `--no-attach` is applied last,
    /// so the more specific "don't show me this" wins.
    @Test func noAttachWinsOverAttachForTheSameService() {
        #expect(AttachSelection.resolve(all: all,
                                        attach: ["web"],
                                        noAttach: ["web"])
            .isEmpty)
    }

    // MARK: - Ordering and duplicates

    /// Output ordering must come from the project so successive runs
    /// interleave logs the same way.
    @Test func orderFollowsTheProjectNotTheFlags() {
        #expect(AttachSelection.resolve(all: ["a", "b", "c"],
                                        attach: ["c", "a"],
                                        noAttach: [])
            == ["a", "c"])
    }

    @Test func repeatedFlagValuesDoNotDuplicateServices() {
        #expect(AttachSelection.resolve(all: all,
                                        attach: ["web", "web"],
                                        noAttach: [])
            == ["web"])
    }

    // MARK: - Unknown names

    /// A typo must be reported. Silently streaming nothing is the worst
    /// outcome: it looks like the service produces no output.
    @Test func unknownAttachTargetIsReported() {
        #expect(AttachSelection.unknownServices(all: all,
                                                attach: ["wbe"],
                                                noAttach: [])
            == ["wbe"])
    }

    @Test func unknownNoAttachTargetIsReported() {
        #expect(AttachSelection.unknownServices(all: all,
                                                attach: [],
                                                noAttach: ["cache"])
            == ["cache"])
    }

    @Test func knownServicesReportNothing() {
        #expect(AttachSelection.unknownServices(all: all,
                                                attach: ["api"],
                                                noAttach: ["db"])
            .isEmpty)
    }

    @Test func unknownNamesAreDeduplicated() {
        #expect(AttachSelection.unknownServices(all: all,
                                                attach: ["nope", "nope"],
                                                noAttach: ["nope"])
            == ["nope"])
    }

    // MARK: - Through the real parser

    @Test func shortFlagIsAcceptedAndRepeatable() throws {
        let cmd = try ComposeUpCommand.parse(["-a", "web", "-a", "api"])
        #expect(cmd.attach == ["web", "api"])
    }

    @Test func longFlagIsAccepted() throws {
        let cmd = try ComposeUpCommand.parse(["--attach", "web"])
        #expect(cmd.attach == ["web"])
    }

    @Test func noAttachFlagIsAccepted() throws {
        let cmd = try ComposeUpCommand.parse(["--no-attach", "db"])
        #expect(cmd.noAttach == ["db"])
    }

    @Test func defaultsAreEmptySoBehaviourIsUnchanged() throws {
        let cmd = try ComposeUpCommand.parse([])
        #expect(cmd.attach.isEmpty)
        #expect(cmd.noAttach.isEmpty)
    }

    /// `-d` streams nothing, so combining it with `--attach` is a mistake
    /// worth reporting rather than silently ignoring.
    @Test func detachWithAttachIsRejected() async throws {
        var cmd = try ComposeUpCommand.parse(["-d", "-a", "web"])
        await #expect(throws: (any Error).self) { try await cmd.run() }
    }
}

/// `cocker start -a` declared the flag and never read it : it parsed
/// cleanly and streamed nothing, which is worse than not offering it.
@Suite("start --attach")
struct StartAttachTests {

    @Test func shortFlagIsAccepted() throws {
        let cmd = try StartCommand.parse(["-a", "web"])
        #expect(cmd.attach)
        #expect(cmd.containers == ["web"])
    }

    @Test func longFlagIsAccepted() throws {
        #expect(try StartCommand.parse(["--attach", "web"]).attach)
    }

    @Test func defaultsToNotAttaching() throws {
        #expect(try !StartCommand.parse(["web"]).attach)
    }

    /// Several containers still start fine without `-a` ; only the
    /// attached form is restricted.
    @Test func severalContainersAreFineWithoutAttach() throws {
        let cmd = try StartCommand.parse(["a", "b", "c"])
        #expect(cmd.containers.count == 3)
        #expect(!cmd.attach)
    }

    /// Two unlabelled streams interleaved in one terminal is unreadable,
    /// so the combination is refused rather than half-working.
    @Test func attachWithSeveralContainersIsRejected() async throws {
        var cmd = try StartCommand.parse(["-a", "a", "b"])
        await #expect(throws: (any Error).self) { try await cmd.run() }
    }
}
