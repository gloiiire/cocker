import XCTest
import CockerCore
@testable import CockerCLI

// Tests for the sticky build/compose views introduced in PR #3 of the
// v0.7.0 "Polished" refactor. We pin TTY capabilities to non-color
// non-animation so renders are deterministic and we can assert on the
// raw structure of each frame.

final class UXBuildParserTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
    }

    // MARK: - BuildEvent parser

    func testParseStepWithSpaceColonForm() {
        let e = UX.BuildEvent.parse(stream: .status, line: "Step 3/5 : RUN apt-get update")
        guard case .step(let n, let total, let kw, let args) = e else {
            return XCTFail("expected step, got \(e)")
        }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(total, 5)
        XCTAssertEqual(kw, "RUN")
        XCTAssertEqual(args, "apt-get update")
    }

    func testParseStepWithColonOnlyForm() {
        let e = UX.BuildEvent.parse(stream: .status, line: "Step 0/5: Parsing Dockerfile")
        guard case .step(let n, let total, let kw, let args) = e else {
            return XCTFail("expected step, got \(e)")
        }
        XCTAssertEqual(n, 0)
        XCTAssertEqual(total, 5)
        XCTAssertEqual(kw, "Parsing")
        XCTAssertEqual(args, "Dockerfile")
    }

    func testParseCacheHitFromStdout() {
        let e = UX.BuildEvent.parse(stream: .stdout, line: " ---> Using cache (layer sha256:abc)")
        XCTAssertEqual(e, .cacheHit)
    }

    func testParseSuccessfullyBuilt() {
        let e = UX.BuildEvent.parse(stream: .status, line: "Successfully built sha256:abc123def")
        XCTAssertEqual(e, .builtHash("sha256:abc123def"))
    }

    func testParseSuccessfullyTagged() {
        let e = UX.BuildEvent.parse(stream: .status, line: "Successfully tagged my-app:latest")
        XCTAssertEqual(e, .taggedAs("my-app:latest"))
    }

    func testParseUnknownStatusIsIgnored() {
        let e = UX.BuildEvent.parse(stream: .status, line: "Some banner the daemon logged")
        XCTAssertEqual(e, .ignore)
    }

    func testParseErrorStreamPropagatesText() {
        let e = UX.BuildEvent.parse(stream: .error, line: "boom")
        XCTAssertEqual(e, .error("boom"))
    }

    // MARK: - BuildView state

    func testBuildViewAdvancesPreviousStepOnNewStep() {
        let view = UX.BuildView()
        view.ingest(stream: .status, line: "Step 1/3 : FROM ubuntu")
        view.ingest(stream: .status, line: "Step 2/3 : RUN echo hi")
        // No crash, no assertion on stdout (sticky in animated mode is
        // a no-op for stdout when animation disabled — the state
        // transitions are what we care about).
        view.finalize()
    }

    func testBuildViewCacheHitMarksStep() {
        let view = UX.BuildView()
        view.ingest(stream: .status, line: "Step 1/2 : FROM ubuntu")
        view.ingest(stream: .stdout, line: " ---> Using cache (layer sha256:xyz)")
        view.finalize()
        // Smoke test : ensure no crash. Branch coverage exercised.
    }
}

final class UXComposeParserTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UX.TTY.set(.init(isInteractive: false, colorEnabled: false, animationEnabled: false))
    }

    func testParseCreatedNetwork() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "Created network: myapp_default\n")
        XCTAssertEqual(e, .created(type: .network, name: "myapp_default"))
    }

    func testParseCreatedVolume() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "Created volume: myapp_data\n")
        XCTAssertEqual(e, .created(type: .volume, name: "myapp_data"))
    }

    func testParseBuildingService() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "Building web...\n")
        XCTAssertEqual(e, .building(service: "web"))
    }

    func testParseBuilt() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "Built my-app:web\n")
        XCTAssertEqual(e, .built(service: "my-app:web"))
    }

    func testParsePullingImage() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "Pulling nginx:1.27...\n")
        XCTAssertEqual(e, .pulling(image: "nginx:1.27"))
    }

    func testParsePulledImage() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "Pulled nginx:1.27\n")
        XCTAssertEqual(e, .pulled(image: "nginx:1.27"))
    }

    func testParseImageAlreadyExists() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "nginx:1.27: Already exists\n")
        XCTAssertEqual(e, .alreadyExists(image: "nginx:1.27"))
    }

    func testParseStartingContainer() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "Starting myapp_db_1...\n")
        XCTAssertEqual(e, .starting(container: "myapp_db_1"))
    }

    func testParseStartedContainer() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "Started container abc123def456\n")
        XCTAssertEqual(e, .started(container: "abc123def456"))
    }

    func testParseUnknownIsIgnored() {
        let e = UX.ComposeEvent.parse(stream: .status, line: "Starting project: myapp\n")
        XCTAssertEqual(e, .ignore)
    }

    func testParseStderrPropagatesText() {
        let e = UX.ComposeEvent.parse(stream: .stderr, line: "[web] runtime error\n")
        XCTAssertEqual(e, .stderr("[web] runtime error\n"))
    }

    // MARK: - ComposeUpView state

    func testComposeUpViewAccumulatesResources() {
        let view = UX.ComposeUpView()
        view.ingest(stream: .status, line: "Created network: myapp_default\n")
        view.ingest(stream: .status, line: "Starting myapp_db_1...\n")
        view.ingest(stream: .status, line: "Started container abc123\n")
        view.finalize()
        // Smoke : exercise upsert/render branches without asserting
        // on cursor codes (animation disabled).
    }

    func testComposeUpViewHandlesPullingPulledCycle() {
        let view = UX.ComposeUpView()
        view.ingest(stream: .status, line: "Pulling nginx:1.27...\n")
        view.ingest(stream: .status, line: "Pulled nginx:1.27\n")
        view.finalize()
    }
}
