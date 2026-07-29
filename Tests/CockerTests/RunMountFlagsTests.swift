import Foundation
import Testing
@testable import CockerDaemon

/// Three build bugs found while migrating a real project to `uv`.
///
///  1. `RUN --mount=type=cache,...` went straight to /bin/sh, which tried
///     to execute the flag as a program. Every modern Python/Rust/Node
///     Dockerfile uses this syntax.
///  2. A `COPY` whose source is missing only warned, and the build still
///     exited 0 — so CI saw a success and the image failed at runtime.
///  3. The failure diagnostic reached the terminal before the step list
///     it explains (stdout buffered, stderr not).
@Suite("BuildKit mount flags")
struct RunMountFlagsTests {

    // MARK: - Stripping

    @Test func cacheMountIsStrippedAndCommandSurvives() {
        let p = RunMountFlags.parse("--mount=type=cache,target=/root/.cache uv sync --locked")
        #expect(p.command == "uv sync --locked")
        #expect(p.ignoredTypes == ["cache"])
        #expect(p.unsupportedTypes.isEmpty)
    }

    @Test func multipleMountsAreAllStripped() {
        let p = RunMountFlags.parse(
            "--mount=type=cache,target=/a --mount=type=cache,target=/b make build")
        #expect(p.command == "make build")
        #expect(p.ignoredTypes == ["cache", "cache"])
    }

    @Test func tmpfsMountIsSafeToDrop() {
        let p = RunMountFlags.parse("--mount=type=tmpfs,target=/tmp/x ./configure")
        #expect(p.command == "./configure")
        #expect(p.ignoredTypes == ["tmpfs"])
        #expect(p.unsupportedTypes.isEmpty)
    }

    /// Space-separated form, which BuildKit also accepts.
    @Test func spaceSeparatedMountFormIsHandled() {
        let p = RunMountFlags.parse("--mount type=cache,target=/c pip install .")
        #expect(p.command == "pip install .")
        #expect(p.ignoredTypes == ["cache"])
    }

    // MARK: - Unsupported types must fail loudly

    /// Dropping a bind/secret/ssh mount changes what the command can see,
    /// so building anyway would ship a wrong image.
    @Test(arguments: ["bind", "secret", "ssh"])
    func mountsThatChangeVisibleStateAreRejected(type: String) {
        let p = RunMountFlags.parse("--mount=type=\(type),target=/x cat /x")
        #expect(p.unsupportedTypes == [type])
        #expect(p.ignoredTypes.isEmpty)
    }

    /// BuildKit defaults an untyped mount to `bind`, which is unsupported.
    @Test func untypedMountDefaultsToBindAndIsRejected() {
        let p = RunMountFlags.parse("--mount=target=/x,source=/y echo hi")
        #expect(p.unsupportedTypes == ["bind"])
    }

    // MARK: - Commands without mounts must be untouched

    @Test func plainCommandIsUnchanged() {
        let p = RunMountFlags.parse("apk add --no-cache curl")
        #expect(p.command == "apk add --no-cache curl")
        #expect(p.ignoredTypes.isEmpty)
        #expect(p.unsupportedTypes.isEmpty)
    }

    /// A `--mount` appearing later belongs to the user's command line
    /// (`docker run --mount=...` inside a RUN) and must survive verbatim.
    @Test func laterMountFlagIsNotStripped() {
        let cmd = "docker run --mount=type=bind,src=/a,dst=/b img"
        #expect(RunMountFlags.parse(cmd).command == cmd)
    }

    /// A flag that merely starts with the same letters is not a mount.
    @Test func similarlyNamedFlagIsNotAMount() {
        let cmd = "--mountains-of-madness --do-something"
        let p = RunMountFlags.parse(cmd)
        #expect(p.command == cmd)
        #expect(p.ignoredTypes.isEmpty)
    }

    @Test func mountWithQuotedValueIsParsed() {
        let p = RunMountFlags.parse("--mount=type=cache,target=\"/root/my cache\" ls")
        #expect(p.command == "ls")
        #expect(p.ignoredTypes == ["cache"])
    }

    // MARK: - Messages must be actionable

    @Test func ignoreWarningNamesTheTypeAndReassures() {
        let msg = RunMountFlags.warning(for: ["cache"])
        #expect(msg.contains("cache"))
        #expect(msg.lowercased().contains("still runs"))
    }

    @Test func warningDeduplicatesRepeatedTypes() {
        #expect(RunMountFlags.warning(for: ["cache", "cache"])
            == RunMountFlags.warning(for: ["cache"]))
    }

    /// The failure has to explain WHY it is not simply ignored, otherwise
    /// the user just wonders why cache works and bind does not.
    @Test func failureExplainsWhyItCannotBeIgnored() {
        let msg = RunMountFlags.failure(for: ["bind"])
        #expect(msg.contains("bind"))
        #expect(msg.lowercased().contains("wrong image"))
    }

    /// `--network=none` and `--mount=type=bind` are both refused, but the
    /// fix differs. A single message mentioning "mount type" and
    /// suggesting COPY was actively misleading for the network case.
    @Test func networkFailureMessageDoesNotTalkAboutMounts() {
        let msg = RunMountFlags.failure(for: ["network=none"])
        #expect(msg.contains("--network=none"))
        #expect(!msg.contains("mount type"))
        #expect(!msg.contains("COPY"))
    }

    @Test func mountAndNetworkFailuresAreBothReported() {
        let msg = RunMountFlags.failure(for: ["bind", "network=none"])
        #expect(msg.contains("bind"))
        #expect(msg.contains("--network=none"))
    }

    /// The default network mode matches what cocker already does, so it is
    /// noted rather than refused.
    @Test func defaultNetworkIsMerelyNoted() {
        let p = RunMountFlags.parse("--network=default pip install .")
        #expect(p.command == "pip install .")
        #expect(p.unsupportedTypes.isEmpty)
        #expect(p.ignoredTypes == ["network"])
    }
}
