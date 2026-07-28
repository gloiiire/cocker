import Foundation
import Testing
import ArgumentParser
@testable import CockerCore
@testable import CockerDaemon
@testable import CockerCLI

@Suite("Reported build regressions")
struct ReportedBuildRegressionTests {
    @Test func runCacheKeyIncludesParentLayer() {
        let common = (command: "pip install /app/analysis", workdir: "/", user: "", env: ["PATH": "/bin"])
        let old = DockerfileBuilder.runCacheKey(
            command: common.command, parentLayers: ["sha256:copy-old"],
            workdir: common.workdir, user: common.user, env: common.env)
        let new = DockerfileBuilder.runCacheKey(
            command: common.command, parentLayers: ["sha256:copy-new"],
            workdir: common.workdir, user: common.user, env: common.env)
        #expect(old != new)
    }

    @Test func runCacheKeyIncludesExecutionContextAndSortsEnv() {
        let a = DockerfileBuilder.runCacheKey(
            command: "python build.py", parentLayers: ["sha256:parent"],
            workdir: "/app", user: "1000", env: ["B": "2", "A": "1"])
        let same = DockerfileBuilder.runCacheKey(
            command: "python build.py", parentLayers: ["sha256:parent"],
            workdir: "/app", user: "1000", env: ["A": "1", "B": "2"])
        let otherWorkdir = DockerfileBuilder.runCacheKey(
            command: "python build.py", parentLayers: ["sha256:parent"],
            workdir: "/srv", user: "1000", env: ["A": "1", "B": "2"])
        #expect(a == same)
        #expect(a != otherWorkdir)
    }

    @Test(arguments: [
        ".venv", "analysis/.venv", "a/b/.venv", "analysis/.venv/bin/python",
        "__pycache__", "analysis/__pycache__", "a/b/__pycache__/x.pyc",
    ])
    func doubleStarDirectoryPatternsMatchAtEveryDepth(path: String) {
        #expect(DockerfileBuilder.isIgnoredPath(
            path, patterns: ["**/.venv/", "**/__pycache__/"]))
    }

    @Test func negationStillReincludesAfterDoubleStarRule() {
        #expect(!DockerfileBuilder.isIgnoredPath(
            "analysis/.venv/keep.txt",
            patterns: ["**/.venv/", "!analysis/.venv/keep.txt"]))
    }
}

@Suite("Reported Compose regressions")
struct ReportedComposeRegressionTests {
    @Test func composeRequestNoCacheRoundTripsAndDefaultsFalse() throws {
        let request = ComposeRequest(composePath: "/tmp/compose.yml", noCache: true)
        let decoded = try JSONDecoder().decode(
            ComposeRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.noCache)

        let legacy = Data(#"{"composePath":"/tmp/compose.yml"}"#.utf8)
        #expect(try !JSONDecoder().decode(ComposeRequest.self, from: legacy).noCache)
    }

    @Test func execCapturesPythonAndNodeOptionsWithoutDoubleDash() throws {
        let python = try ComposeExecCommand.parse(["api", "python", "-c", "print('ok')"])
        #expect(python.command == ["python", "-c", "print('ok')"])
        let node = try ComposeExecCommand.parse(["web", "node", "-e", "console.log('ok')"])
        #expect(node.command == ["node", "-e", "console.log('ok')"])
    }

    @Test func projectFolderNameNormalizesLikeComposeUp() {
        #expect(ProjectName.normalize("Memoire M2") == "memoire_m2")
    }

    @Test func projectGateSerializesSameProject() async throws {
        let gate = ComposeProjectGate()
        let state = OrderedState()
        async let first: Void = gate.withLock(project: "memoire_m2") {
            await state.append("first-start")
            try? await Task.sleep(nanoseconds: 30_000_000)
            await state.append("first-end")
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
        async let second: Void = gate.withLock(project: "memoire_m2") {
            await state.append("second")
        }
        _ = await (first, second)
        #expect(await state.values == ["first-start", "first-end", "second"])
    }
}

private actor OrderedState {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
