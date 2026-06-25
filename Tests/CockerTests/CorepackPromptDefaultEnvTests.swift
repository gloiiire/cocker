import XCTest
@testable import CockerDaemon

// PRO-54 — auto-inject COREPACK_ENABLE_DOWNLOAD_PROMPT=0 in the build VM
// env. Before this fix, `RUN corepack enable && pnpm install` would hang
// for 10 minutes (the full RUN timeout) because corepack ≥0.20 prints a
// confirmation prompt before downloading the actual pnpm tarball and
// waits on stdin — which a non-TTY build VM never provides.

final class CorepackPromptDefaultEnvTests: XCTestCase {

    func testDefaultBuildEnvIncludesPathAndCorepackSuppressor() {
        let env = DockerfileBuilder.defaultBuildEnv(path: "/sbin:/bin")
        XCTAssertEqual(env["PATH"], "/sbin:/bin")
        XCTAssertEqual(env["COREPACK_ENABLE_DOWNLOAD_PROMPT"], "0",
            "build VMs have no TTY; without this corepack hangs on its download prompt")
    }

    func testNoOtherSurprisingDefaults() {
        // Keep the default env intentional and minimal — surprising
        // implicit defaults (e.g. CI=true, NODE_ENV=production) would
        // bite the next person trying to debug a build divergence.
        let env = DockerfileBuilder.defaultBuildEnv(path: "/x")
        XCTAssertEqual(Set(env.keys), ["PATH", "COREPACK_ENABLE_DOWNLOAD_PROMPT"],
            "only PATH and the corepack suppressor should ship by default")
    }

    func testUserEnvOverridesTheSuppressor() {
        // Simulate the Dockerfile ENV handler running AFTER the default
        // env is set : the user's value must win. (The real builder
        // applies ENV instructions via `env[key] = value` line by line,
        // so a plain dict-merge already gives that semantics.)
        var env = DockerfileBuilder.defaultBuildEnv(path: "/x")
        // User: ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=1
        env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "1"
        XCTAssertEqual(env["COREPACK_ENABLE_DOWNLOAD_PROMPT"], "1",
            "Dockerfile ENV instructions must override cocker's defaults")
    }
}
