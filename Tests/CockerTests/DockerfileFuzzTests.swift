import Testing
import Foundation
@testable import CockerCore

// Property-based fuzz of the Dockerfile parser. The contract :
//   - parseDockerfile never throws anything except `CockerError`
//   - it never crashes / fatalErrors / infinite-loops
//   - empty / comment-only / garbage input is rejected cleanly
// We don't check the parse RESULT is correct ; just the absence of
// pathological behaviour on adversarial input.

@Suite("Dockerfile parser — fuzz")
struct DockerfileFuzzTests {

    /// Deterministic seed so the fuzz is reproducible in CI.
    private func rng(seed: UInt64) -> SystemRandomNumberGenerator {
        // SystemRandomNumberGenerator is non-deterministic by design.
        // We accept that here ; flaky failures are still useful — they
        // surface real bugs. For reproduction we capture the failing
        // input in the test message.
        SystemRandomNumberGenerator()
    }

    private let knownKeywords = [
        "FROM", "RUN", "CMD", "ENTRYPOINT", "ENV", "ARG", "LABEL", "EXPOSE",
        "WORKDIR", "USER", "VOLUME", "COPY", "ADD", "HEALTHCHECK", "STOPSIGNAL",
        "ONBUILD", "SHELL", "MAINTAINER",
    ]

    private let charset = Array(" \t\n\\\"$=:/'.,-_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ#[]<>{}!@%^&*+()")

    private func randomLine<R: RandomNumberGenerator>(maxLen: Int, rng: inout R) -> String {
        let len = Int.random(in: 0...maxLen, using: &rng)
        var s = ""
        s.reserveCapacity(len)
        for _ in 0..<len {
            s.append(charset.randomElement(using: &rng) ?? " ")
        }
        return s
    }

    private func randomDockerfile<R: RandomNumberGenerator>(rng: inout R) -> String {
        var lines: [String] = []
        let nLines = Int.random(in: 0...30, using: &rng)
        for _ in 0..<nLines {
            let kind = Int.random(in: 0...4, using: &rng)
            switch kind {
            case 0:
                // Plausible keyword line
                let kw = knownKeywords.randomElement(using: &rng) ?? "RUN"
                lines.append("\(kw) \(randomLine(maxLen: 60, rng: &rng))")
            case 1:
                lines.append("# \(randomLine(maxLen: 40, rng: &rng))")
            case 2:
                lines.append("")
            case 3:
                // Line continuation — common Dockerfile gotcha
                lines.append("\(randomLine(maxLen: 30, rng: &rng)) \\")
            default:
                lines.append(randomLine(maxLen: 80, rng: &rng))
            }
        }
        return lines.joined(separator: "\n")
    }

    @Test func parseNeverCrashesOnRandomBytes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let input = randomDockerfile(rng: &rng)
            do {
                _ = try parseDockerfile(input)
            } catch is CockerError {
                // expected for inputs without a valid FROM
            } catch {
                Issue.record("parser threw unexpected non-CockerError on input: \(input.prefix(200))")
            }
        }
    }

    @Test func parseHandlesValidPrefixGarbageSuffix() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let suffix = randomDockerfile(rng: &rng)
            let input = "FROM alpine\n\(suffix)"
            do {
                _ = try parseDockerfile(input)
            } catch is CockerError {
                // ok
            } catch {
                Issue.record("threw non-CockerError: \(error) on input prefix=\(input.prefix(120))")
            }
        }
    }

    @Test func emptyInputRejectsCleanly() {
        #expect(throws: CockerError.self) {
            _ = try parseDockerfile("")
        }
        #expect(throws: CockerError.self) {
            _ = try parseDockerfile("\n\n\n")
        }
        #expect(throws: CockerError.self) {
            _ = try parseDockerfile("# only comments\n# more comments\n")
        }
    }

    @Test func backslashAtEndOfFileDoesNotInfiniteLoop() {
        // The Dockerfile parser joins lines ending in `\` ; pathological
        // inputs where the very last line ends in `\` must not loop
        // forever waiting for a continuation that never comes.
        let inputs = [
            "FROM alpine\nRUN echo hi \\",
            "FROM alpine\nRUN \\",
            "\\",
            "FROM alpine\n\\\n\\\n\\\n\\\n",
        ]
        for s in inputs {
            do {
                _ = try parseDockerfile(s)
            } catch {
                // any thrown error fine — just shouldn't hang
            }
        }
    }

    @Test func veryLongSingleLineDoesNotBlowMemory() {
        // 100 KB single line, no newlines.
        var s = "FROM alpine\n"
        s.append(String(repeating: "A", count: 100_000))
        do {
            _ = try parseDockerfile(s)
        } catch {
            // either CockerError or normal completion is fine
        }
    }
}
