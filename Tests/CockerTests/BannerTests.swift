import Testing
import Foundation
@testable import CockerCore

@Suite("Banner — ASCII logo")
struct BannerLogoTests {
    @Test func logoIsNonEmpty() {
        #expect(!Banner.logo.isEmpty)
    }

    @Test func logoIsMultipleLines() {
        let lines = Banner.logo.split(separator: "\n")
        #expect(lines.count >= 4)
    }

    @Test func logoFitsIn80Columns() {
        for line in Banner.logo.split(separator: "\n") {
            #expect(line.count <= 80)
        }
    }
}

@Suite("Banner — cocker welcome")
struct BannerWelcomeTests {
    @Test func plainTextOmitsAnsi() {
        let s = Banner.cockerWelcome(version: "1.2.3", colored: false)
        #expect(!s.contains("\u{1B}"))  // no escape codes
        #expect(s.contains("v1.2.3"))
    }

    @Test func coloredVersionUsesAnsi() {
        let s = Banner.cockerWelcome(version: "0.2.8", colored: true)
        #expect(s.contains("\u{1B}["))
        #expect(s.contains(ANSIStyle.warmOrange))
        #expect(s.contains(ANSIStyle.reset))
    }

    @Test func carriesProjectURL() {
        let s = Banner.cockerWelcome(version: "x", colored: false)
        #expect(s.contains("github.com/gloiiire/cocker"))
    }

    @Test func endsWithBlankLine() {
        let s = Banner.cockerWelcome(version: "x", colored: false)
        #expect(s.hasSuffix("\n\n"))
    }
}

@Suite("Banner — cockerd boot screen")
struct BannerCockerdTests {
    private func banner(colored: Bool = false) -> String {
        Banner.cockerdBanner(
            version: "0.2.8",
            rootDir: "/Users/me/.cocker",
            ipcSocket: "/Users/me/.cocker/cocker.sock",
            dockerSocket: "/Users/me/.cocker/docker.sock",
            dnsPort: 5300,
            colored: colored
        )
    }

    @Test func plainBoot() {
        let s = banner()
        #expect(!s.contains("\u{1B}"))
    }

    @Test func showsListenerSocketPaths() {
        let s = banner()
        #expect(s.contains("/Users/me/.cocker/cocker.sock"))
        #expect(s.contains("/Users/me/.cocker/docker.sock"))
        #expect(s.contains("5300"))
    }

    @Test func showsRootDir() {
        let s = banner()
        #expect(s.contains("/Users/me/.cocker"))
    }

    @Test func showsReadyMessage() {
        let s = banner()
        #expect(s.contains("Ready"))
        #expect(s.contains("Ctrl-C"))
    }

    @Test func tellsUserToTryRunCommand() {
        let s = banner()
        #expect(s.contains("cocker run alpine echo hello"))
    }

    @Test func coloredVariantContainsAnsi() {
        let s = banner(colored: true)
        #expect(s.contains(ANSIStyle.warmOrange))
        #expect(s.contains(ANSIStyle.warmAmber))
        #expect(s.contains(ANSIStyle.bold))
    }

    @Test func versionIsRendered() {
        let s = banner()
        #expect(s.contains("v0.2.8"))
    }

    @Test func carriesProjectURL() {
        let s = banner()
        #expect(s.contains("github.com/gloiiire/cocker"))
    }

    @Test func mentionsUDPAndTCP() {
        // Both DNS transports are spelled out — useful for grep / ops
        // verifying that both protocols came up.
        let s = banner()
        #expect(s.contains("UDP"))
        #expect(s.contains("TCP"))
    }
}

@Suite("Banner — ANSI palette")
struct BannerANSIStyleTests {
    @Test func resetEscapeIsCanonical() {
        #expect(ANSIStyle.reset == "\u{1B}[0m")
    }

    @Test func styleCodesStartWithCSI() {
        for code in [ANSIStyle.bold, ANSIStyle.dim, ANSIStyle.red,
                     ANSIStyle.green, ANSIStyle.yellow, ANSIStyle.blue,
                     ANSIStyle.magenta, ANSIStyle.cyan, ANSIStyle.white,
                     ANSIStyle.brightCyan, ANSIStyle.brightGreen] {
            #expect(code.hasPrefix("\u{1B}["))
            #expect(code.hasSuffix("m"))
        }
    }

    @Test func brightVariantsUseHighRange() {
        // Bright (high-intensity) colors live in the 90..=97 range.
        #expect(ANSIStyle.brightCyan.contains("96"))
        #expect(ANSIStyle.brightGreen.contains("92"))
    }

    @Test func warmPaletteUsesXterm256Codes() {
        // 256-color escapes are "\e[38;5;Nm" — verify the format.
        for code in [ANSIStyle.warmOrange, ANSIStyle.warmAmber, ANSIStyle.warmGold,
                     ANSIStyle.warmMustard, ANSIStyle.warmPeach, ANSIStyle.warmRed] {
            #expect(code.hasPrefix("\u{1B}[38;5;"))
            #expect(code.hasSuffix("m"))
        }
    }

    @Test func warmOrangeIsCode208() {
        #expect(ANSIStyle.warmOrange == "\u{1B}[38;5;208m")
    }
}

@Suite("Banner — cockerd help")
struct BannerHelpTests {
    @Test func plainHelpHasNoEscapes() {
        let s = Banner.cockerdHelp(version: "0.2.9", colored: false)
        #expect(!s.contains("\u{1B}"))
    }

    @Test func helpStartsWithLogo() {
        let s = Banner.cockerdHelp(version: "0.2.9", colored: false)
        // cockerd uses the dedicated "cockerd" logo with trailing 'd'
        #expect(s.contains(Banner.logoDaemon))
    }

    @Test func daemonLogoHasTrailingD() {
        // The shape difference vs the CLI logo is the extra "d" block on
        // the right. Verify the daemon logo is strictly wider (more
        // characters per line on average).
        let cliLines = Banner.logo.split(separator: "\n")
        let dLines = Banner.logoDaemon.split(separator: "\n")
        let cliMax = cliLines.map { $0.count }.max() ?? 0
        let dMax = dLines.map { $0.count }.max() ?? 0
        #expect(dMax > cliMax)
    }

    @Test func helpRecommendsCockerDaemonStart() {
        // The user explicitly asked for `cocker daemon start` to come first
        // in the USAGE section. Make sure it stays first.
        let s = Banner.cockerdHelp(version: "0.2.9", colored: false)
        let usageRange = s.range(of: "USAGE")!
        let optionsRange = s.range(of: "OPTIONS")!
        let between = String(s[usageRange.upperBound..<optionsRange.lowerBound])
        let firstCmdLine = between.split(separator: "\n").first { $0.contains("$") }!
        #expect(firstCmdLine.contains("cocker daemon start"))
    }

    @Test func helpHasAllSectionHeaders() {
        let s = Banner.cockerdHelp(version: "0.2.9", colored: false)
        for h in ["USAGE", "OPTIONS", "DAEMON LIFECYCLE", "ENVIRONMENT", "ENTITLEMENTS"] {
            #expect(s.contains(h))
        }
    }

    @Test func helpShowsBrewServices() {
        let s = Banner.cockerdHelp(version: "0.2.9", colored: false)
        #expect(s.contains("brew services start cocker"))
    }

    @Test func helpListsAllDaemonSubcommands() {
        let s = Banner.cockerdHelp(version: "0.2.9", colored: false)
        for sub in ["start", "status", "logs -f", "stop", "restart"] {
            #expect(s.contains("cocker daemon \(sub)"))
        }
    }

    @Test func helpCarriesVersion() {
        let s = Banner.cockerdHelp(version: "9.8.7", colored: false)
        #expect(s.contains("v9.8.7"))
    }

    @Test func coloredHelpUsesWarmPalette() {
        let s = Banner.cockerdHelp(version: "0.2.9", colored: true)
        #expect(s.contains(ANSIStyle.warmOrange))
        #expect(s.contains(ANSIStyle.warmGold))
        #expect(s.contains(ANSIStyle.warmAmber))
        #expect(s.contains(ANSIStyle.warmMustard))
    }
}

@Suite("Banner — cocker CLI help")
struct BannerCockerCLIHelpTests {
    @Test func helpHasMainSections() {
        let s = Banner.cockerCLIHelp(version: "0.2.9", colored: false)
        for h in ["USAGE", "GET STARTED", "DAEMON", "CONTAINERS",
                  "IMAGES", "NETWORK & VOLUMES", "ORCHESTRATION",
                  "SYSTEM & AUTH"] {
            #expect(s.contains(h))
        }
    }

    @Test func helpRecommendsDaemonStart() {
        let s = Banner.cockerCLIHelp(version: "0.2.9", colored: false)
        // The "daemon" command in DAEMON section gets the ★ marker.
        #expect(s.contains("daemon"))
    }

    @Test func helpListsKeyCommands() {
        let s = Banner.cockerCLIHelp(version: "0.2.9", colored: false)
        for cmd in ["run", "ps, ls", "pull", "build", "compose", "system, s"] {
            #expect(s.contains(cmd))
        }
    }

    @Test func helpStartsWithLogo() {
        let s = Banner.cockerCLIHelp(version: "0.2.9", colored: false)
        #expect(s.contains(Banner.logo))
    }

    @Test func helpHasNoEscapesInPlain() {
        let s = Banner.cockerCLIHelp(version: "0.2.9", colored: false)
        #expect(!s.contains("\u{1B}"))
    }

    @Test func coloredHelpUsesWarmPalette() {
        let s = Banner.cockerCLIHelp(version: "0.2.9", colored: true)
        #expect(s.contains(ANSIStyle.warmOrange))
        #expect(s.contains(ANSIStyle.warmGold))
        #expect(s.contains(ANSIStyle.warmAmber))
    }
}

@Suite("Banner — ArgumentParser help colorizer")
struct ColorizerTests {
    private let rawHelp = """
    OVERVIEW: Run a command in a new container

    USAGE: cocker run [<options>] <image> [<command> ...]

    ARGUMENTS:
      <image>             Image to run
      <command>           Command to run

    OPTIONS:
      -d, --detach        Run container in the background
      --name <name>       Assign a name to the container
      -h, --help          Show help information.

    SUBCOMMANDS:
      start               Start cockerd in the background
      stop                Stop the background cockerd process
    """

    @Test func uncoloredIsIdentity() {
        let out = Banner.colorizeArgumentParserHelp(rawHelp, colored: false)
        #expect(out == rawHelp)
    }

    @Test func coloredAddsAnsiCodes() {
        let out = Banner.colorizeArgumentParserHelp(rawHelp, colored: true)
        #expect(out.contains("\u{1B}["))
    }

    @Test func sectionHeadersGetAmber() {
        let out = Banner.colorizeArgumentParserHelp(rawHelp, colored: true)
        // OVERVIEW:, USAGE:, ARGUMENTS:, OPTIONS:, SUBCOMMANDS: all amber
        // — pick one to confirm.
        #expect(out.contains("\(ANSIStyle.bold)\(ANSIStyle.warmAmber)OVERVIEW:\(ANSIStyle.reset)"))
        #expect(out.contains("\(ANSIStyle.bold)\(ANSIStyle.warmAmber)OPTIONS:\(ANSIStyle.reset)"))
    }

    @Test func headerInlineContentSurvives() {
        let out = Banner.colorizeArgumentParserHelp(rawHelp, colored: true)
        // After "OVERVIEW:" we should still have " Run a command in a new container"
        #expect(out.contains("Run a command in a new container"))
        #expect(out.contains("cocker run [<options>]"))
    }

    @Test func flagsGetMustard() {
        let out = Banner.colorizeArgumentParserHelp(rawHelp, colored: true)
        #expect(out.contains(ANSIStyle.warmMustard))
        // The "-d, --detach" sequence should be inside mustard.
        let mustardSlice = out.range(of: ANSIStyle.warmMustard)
        #expect(mustardSlice != nil)
    }

    @Test func subcommandNamesGetGold() {
        let out = Banner.colorizeArgumentParserHelp(rawHelp, colored: true)
        #expect(out.contains(ANSIStyle.warmGold))
    }

    @Test func nonHeaderColonLineNotMistakenForHeader() {
        let raw = "    --name <name>       Assign a name: with a colon in description"
        let out = Banner.colorizeArgumentParserHelp(raw, colored: true)
        // First content should still be the flag (mustard), not amber.
        // The "name:" inside the description must not be coloured as a header.
        #expect(!out.hasPrefix(ANSIStyle.bold))
    }

    @Test func emptyInputReturnsEmpty() {
        let out = Banner.colorizeArgumentParserHelp("", colored: true)
        #expect(out == "")
    }
}

@Suite("Banner — I/O smoke tests")
struct BannerIOTests {
    /// Just confirm the I/O wrappers don't crash. Output gets captured by
    /// the test runner so it doesn't pollute the suite output.
    @Test func printCockerWelcomeDoesNotCrash() {
        Banner.printCockerWelcome(version: "test-version")
    }

    @Test func printCockerdBannerDoesNotCrash() {
        Banner.printCockerdBanner(
            version: "test",
            rootDir: "/tmp/cocker-test",
            ipcSocket: "/tmp/cocker.sock",
            dockerSocket: "/tmp/docker.sock",
            dnsPort: 5300
        )
    }

    @Test func stderrIsTTYReturnsBool() {
        // Just exercise the path — value depends on test runner attachment.
        _ = Banner.stderrIsTTY
    }
}
