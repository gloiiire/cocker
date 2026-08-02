import Foundation
import Testing
@testable import CockerCore

/// The charter §6 block lived only in `CockerCLI`, so `cockerd` — which the
/// user sees every time they run it in the foreground, and whose output is
/// what lands in cockerd.log — never adopted it. It printed `Error:` /
/// `Warning:` prefixes and bare `✗` lines, so `cocker daemon setup` read like
/// a different product from `cocker run`.
///
/// Rendering is shared now rather than copied: duplicating the shape is how
/// the two drifted apart to begin with.
@Suite("Charter §6 failure block")
struct FailureBlockTests {

    @Test func rendersTheThreeLineShape() {
        let text = FailureBlock.render(
            headline: "Cannot remove container web",
            reason: "no such container",
            hint: "check `cocker ps -a`",
            colored: false)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == " ✗ Cannot remove container web")
        #expect(lines[1] == "   reason : no such container")
        #expect(lines[2] == "   hint   : check `cocker ps -a`")
    }

    /// A block with nothing useful to add shouldn't pad itself with empty
    /// labels.
    @Test func omitsMissingLines() {
        let text = FailureBlock.render(headline: "Boom", colored: false)
        #expect(text == " ✗ Boom")
        #expect(!text.contains("reason"))
        #expect(!text.contains("hint"))
    }

    @Test func detailsIsTheOptionalFourthLine() {
        let text = FailureBlock.render(headline: "Boom", details: "see cockerd.log", colored: false)
        #expect(text.hasSuffix("   details: see cockerd.log"))
    }

    /// Piped output has to stay greppable — no escape sequences.
    @Test func plainWhenNotColoured() {
        let text = FailureBlock.render(headline: "Boom", reason: "why", hint: "how", colored: false)
        #expect(!text.contains("\u{1B}["))
    }

    @Test func colouredWhenAsked() {
        let text = FailureBlock.render(headline: "Boom", colored: true)
        #expect(text.contains("\u{1B}["))
        // The headline still has to survive the escapes.
        #expect(text.contains("Boom"))
    }

    @Test func warningUsesItsOwnMarker() {
        let text = FailureBlock.renderWarning(headline: "kernel path is unusual",
                                              note: "outside ~/.cocker", colored: false)
        #expect(text.hasPrefix(" ⚠ "))
        #expect(text.contains("   note   : outside ~/.cocker"))
    }

    @Test func warningOmitsAnAbsentNote() {
        #expect(FailureBlock.renderWarning(headline: "just this", colored: false) == " ⚠ just this")
    }
}
