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
        #expect(s.contains(ANSIStyle.brightCyan))
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
        #expect(s.contains(ANSIStyle.brightCyan))
        #expect(s.contains(ANSIStyle.brightGreen))
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
}
