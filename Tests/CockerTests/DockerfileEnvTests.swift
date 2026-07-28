import Testing
@testable import CockerCore

@Suite("Dockerfile ENV parsing")
struct DockerfileEnvTests {
    @Test func parsesMultipleAssignmentsFromContinuedEnv() throws {
        let instructions = try parseDockerfile(
            """
            FROM alpine
            ENV FIRST=one \\
                SECOND="two words" \\
                EMPTY="" \\
                ESCAPED=three\\ words
            """)

        let env = try #require(instructions.last)
        #expect(env.keyword == "ENV")
        let pairs = Dictionary(uniqueKeysWithValues: parseDockerfileEnv(env.args))
        #expect(pairs["FIRST"] == "one")
        #expect(pairs["SECOND"] == "two words")
        #expect(pairs["EMPTY"] == "")
        #expect(pairs["ESCAPED"] == "three words")
    }

    @Test func parsesLegacySingleVariableForm() {
        let pairs = parseDockerfileEnv("MESSAGE hello quoted world")
        #expect(pairs.count == 1)
        #expect(pairs.first?.key == "MESSAGE")
        #expect(pairs.first?.value == "hello quoted world")
    }

    @Test func doesNotTreatFollowingAssignmentAsFirstValue() {
        let pairs = Dictionary(uniqueKeysWithValues:
            parseDockerfileEnv("PYTHONPATH=/app/analysis PATH=/venv/bin:$PATH"))
        #expect(pairs["PYTHONPATH"] == "/app/analysis")
        #expect(pairs["PATH"] == "/venv/bin:$PATH")
    }
}
