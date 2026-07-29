import Foundation
import Testing
@testable import CockerCLI

/// `cocker run alpine -- sh -c 'echo hi'` died with
/// `execvp --: No such file or directory` (exit 127) : the POSIX
/// terminator was forwarded to the guest as argv[0] instead of being
/// consumed as a separator. Docker (cobra) strips it ; Swift
/// ArgumentParser's `.captureForPassthrough` does not.
///
/// Four e2e scenarios (01 basic run, 02 by IP, 03 by DNS, 04 port
/// forwarding) were red because of this single bug — CI only lints the
/// scripts, it cannot boot a VM, so nothing caught it.
@Suite("POSIX command separator")
struct CommandSeparatorTests {

    @Test func leadingSeparatorIsDropped() {
        #expect(CommandSeparator.strippingLeadingSeparator(["--", "sh", "-c", "echo hi"])
            == ["sh", "-c", "echo hi"])
    }

    @Test func commandWithoutSeparatorIsUntouched() {
        #expect(CommandSeparator.strippingLeadingSeparator(["sh", "-c", "echo hi"])
            == ["sh", "-c", "echo hi"])
    }

    /// The critical safety property : a `--` the user meant as an argument
    /// must survive. `git log --` and `find . -- -name x` are real usages.
    @Test func laterSeparatorsArePreserved() {
        #expect(CommandSeparator.strippingLeadingSeparator(["sh", "-c", "git log --"])
            == ["sh", "-c", "git log --"])
        #expect(CommandSeparator.strippingLeadingSeparator(["find", ".", "--", "-name", "x"])
            == ["find", ".", "--", "-name", "x"])
    }

    /// Only one terminator is consumed : `-- --` means the command really
    /// is `--`, and that is the caller's call to make.
    @Test func onlyOneSeparatorIsConsumed() {
        #expect(CommandSeparator.strippingLeadingSeparator(["--", "--", "sh"])
            == ["--", "sh"])
    }

    @Test func emptyCommandStaysEmpty() {
        #expect(CommandSeparator.strippingLeadingSeparator([]).isEmpty)
    }

    /// A lone `--` leaves no command at all, so the image's own CMD runs —
    /// same as `docker run alpine --`.
    @Test func loneSeparatorYieldsNoCommand() {
        #expect(CommandSeparator.strippingLeadingSeparator(["--"]).isEmpty)
    }

    /// A flag-looking first argument is not a separator.
    @Test func dashDashPrefixedFlagIsNotASeparator() {
        #expect(CommandSeparator.strippingLeadingSeparator(["--version"]) == ["--version"])
        #expect(CommandSeparator.strippingLeadingSeparator(["-", "x"]) == ["-", "x"])
    }

    // MARK: - End-to-end through the actual CLI parser

    /// Parse the real command so the fix is pinned to what users type,
    /// not just to the helper in isolation.
    @Test func runCommandParsesAndStripsTheSeparator() throws {
        var cmd = try RunCommand.parse(["--rm", "alpine:latest", "--", "sh", "-c", "echo ok"])
        #expect(cmd.image == "alpine:latest")
        // Raw capture still holds the terminator...
        #expect(cmd.command.first == "--")
        // ...and the normalised form drops it.
        #expect(CommandSeparator.strippingLeadingSeparator(cmd.command)
            == ["sh", "-c", "echo ok"])
        _ = cmd  // silence unused-mutation warning
    }

    @Test func runCommandWithoutSeparatorIsUnchanged() throws {
        let cmd = try RunCommand.parse(["--rm", "alpine:latest", "sh", "-c", "echo ok"])
        #expect(CommandSeparator.strippingLeadingSeparator(cmd.command)
            == ["sh", "-c", "echo ok"])
    }

    /// The separator is what lets a command start with its own flags.
    @Test func separatorProtectsALeadingFlagInTheUserCommand() throws {
        let cmd = try RunCommand.parse(["alpine:latest", "--", "ls", "-la"])
        #expect(CommandSeparator.strippingLeadingSeparator(cmd.command) == ["ls", "-la"])
    }

    @Test func execCommandStripsTheSeparator() throws {
        let cmd = try ExecCommand.parse(["my-container", "--", "sh", "-c", "echo hi"])
        #expect(cmd.container == "my-container")
        #expect(CommandSeparator.strippingLeadingSeparator(cmd.command)
            == ["sh", "-c", "echo hi"])
    }
}
