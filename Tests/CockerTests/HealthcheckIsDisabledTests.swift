import Testing
import Foundation
@testable import CockerCore

@Suite("Healthcheck.isDisabled — canonical disabled detection")
struct HealthcheckIsDisabledTests {
    @Test func uppercaseNoneIsDisabled() {
        #expect(Healthcheck(test: ["NONE"]).isDisabled)
    }

    @Test func lowercaseNoneIsAlsoDisabled() {
        // OCI spec is uppercase but hand-written image configs / compose
        // files routinely lowercase ; we accept both.
        #expect(Healthcheck(test: ["none"]).isDisabled)
        #expect(Healthcheck(test: ["None"]).isDisabled)
    }

    @Test func emptyTestArrayIsDisabled() {
        #expect(Healthcheck(test: []).isDisabled)
    }

    @Test func cmdShellNotDisabled() {
        #expect(!Healthcheck(test: ["CMD-SHELL", "true"]).isDisabled)
    }

    @Test func cmdNotDisabled() {
        #expect(!Healthcheck(test: ["CMD", "/bin/true"]).isDisabled)
    }

    @Test func bareArgvNotDisabled() {
        // A test array whose first element is the binary itself (no
        // "CMD" / "CMD-SHELL" prefix) is a valid Docker shape — treat
        // it as a non-disabled probe rather than misclassifying "NONE"
        // arg to a binary named "none".
        #expect(!Healthcheck(test: ["myprobe", "--quick"]).isDisabled)
    }
}
