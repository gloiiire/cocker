import Testing
import Foundation
@testable import CockerCore

// ContainerEngine.mergeHealthcheck is the merge between an image's HEALTHCHECK
// and the CLI overrides on `cocker run`. The logic lives in CockerDaemon, so
// here we re-state the precedence rules as pure expectations on Healthcheck.
//
// We can't import CockerDaemon directly from a CockerCore-flavoured test
// target, so we duplicate the merge body. Keep it in sync with
// ContainerEngine.mergeHealthcheck (any drift will surface as a behavioural
// difference in the live tests).
private func merge(image: Healthcheck?, cli: RunConfig) -> Healthcheck? {
    if cli.healthDisable { return Healthcheck(test: ["NONE"]) }
    if let cmd = cli.healthCmd,
       cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return Healthcheck(test: ["NONE"])
    }
    let test: [String]
    if let cmd = cli.healthCmd,
       !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        test = ["CMD-SHELL", cmd]
    } else if let img = image {
        test = img.test
    } else if cli.healthInterval == nil && cli.healthTimeout == nil
              && cli.healthStartPeriod == nil && cli.healthRetries == nil {
        return nil
    } else {
        return nil
    }
    return Healthcheck(
        test: test,
        interval: cli.healthInterval ?? image?.interval ?? 30,
        timeout: cli.healthTimeout ?? image?.timeout ?? 30,
        startPeriod: cli.healthStartPeriod ?? image?.startPeriod ?? 0,
        retries: cli.healthRetries ?? image?.retries ?? 3
    )
}

@Suite("Healthcheck merge — CLI override precedence")
struct HealthcheckMergeTests {
    @Test func noImageNoCLIReturnsNil() {
        let cfg = RunConfig(image: "alpine")
        #expect(merge(image: nil, cli: cfg) == nil)
    }

    @Test func imageOnlyPasses() {
        let img = Healthcheck(test: ["CMD-SHELL", "wget -q http://localhost/"],
                              interval: 10, timeout: 5, startPeriod: 0, retries: 3)
        let cfg = RunConfig(image: "alpine")
        let out = merge(image: img, cli: cfg)
        #expect(out?.test == ["CMD-SHELL", "wget -q http://localhost/"])
        #expect(out?.interval == 10)
    }

    @Test func cliCmdReplacesImageTest() {
        let img = Healthcheck(test: ["CMD-SHELL", "old"], interval: 5,
                              timeout: 5, startPeriod: 0, retries: 3)
        var cfg = RunConfig(image: "alpine"); cfg.healthCmd = "new"
        let out = merge(image: img, cli: cfg)
        #expect(out?.test == ["CMD-SHELL", "new"])
        #expect(out?.interval == 5) // image default carried over
    }

    @Test func emptyStringDisablesImageHealthcheck() {
        let img = Healthcheck(test: ["CMD-SHELL", "true"])
        var cfg = RunConfig(image: "alpine"); cfg.healthCmd = ""
        #expect(merge(image: img, cli: cfg)?.test == ["NONE"])
    }

    @Test func whitespaceOnlyDisablesImageHealthcheck() {
        let img = Healthcheck(test: ["CMD-SHELL", "true"])
        var cfg = RunConfig(image: "alpine"); cfg.healthCmd = "   \n\t  "
        #expect(merge(image: img, cli: cfg)?.test == ["NONE"])
    }

    @Test func disableFlagWinsOverEverything() {
        let img = Healthcheck(test: ["CMD-SHELL", "true"])
        var cfg = RunConfig(image: "alpine")
        cfg.healthCmd = "ignored"
        cfg.healthDisable = true
        #expect(merge(image: img, cli: cfg)?.test == ["NONE"])
    }

    @Test func intervalOverridePreservesImageTest() {
        let img = Healthcheck(test: ["CMD-SHELL", "true"], interval: 30,
                              timeout: 30, startPeriod: 0, retries: 3)
        var cfg = RunConfig(image: "alpine"); cfg.healthInterval = 2
        let out = merge(image: img, cli: cfg)
        #expect(out?.test == ["CMD-SHELL", "true"])
        #expect(out?.interval == 2)
        #expect(out?.timeout == 30)
    }
}

@Suite("Container — state.json forward-migration defaults")
struct ContainerMigrationTests {
    @Test func oldJSONMissingHealthFieldsDecodes() throws {
        // A state.json from a cocker version before healthFailingStreak /
        // healthLog existed. Decoding must succeed and apply zero-defaults
        // instead of throwing — otherwise the StateStore load wipes every
        // container the user had at upgrade.
        let legacy = """
        {
          "id": "abc123def456",
          "name": "legacy",
          "image": "alpine:latest",
          "command": ["sleep","60"],
          "status": "running",
          "ports": [], "volumes": [],
          "env": {}, "labels": {},
          "networkMode": "nat",
          "cpuCount": 2, "memoryMB": 512,
          "createdAt": "2026-01-01T00:00:00Z",
          "hostname": "legacy",
          "restartPolicy": "no",
          "healthStatus": "none",
          "restartCount": 0,
          "privileged": false,
          "capAdd": [], "capDrop": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let c = try decoder.decode(Container.self, from: Data(legacy.utf8))
        #expect(c.id == "abc123def456")
        #expect(c.healthFailingStreak == 0)
        #expect(c.healthLog.isEmpty)
    }

    @Test func emptyJSONDoesNotCrash() {
        let almostEmpty = """
        {"id":"x","name":"x","image":"x"}
        """
        let decoder = JSONDecoder()
        let c = try? decoder.decode(Container.self, from: Data(almostEmpty.utf8))
        #expect(c != nil)
        #expect(c?.status == .stopped)
    }
}

@Suite("HealthLogEntry — Docker shape roundtrip")
struct HealthLogEntryTests {
    @Test func encodeDecodeRoundtrip() throws {
        let entry = HealthLogEntry(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end:   Date(timeIntervalSince1970: 1_700_000_001),
            exitCode: 1,
            output: "probe failed: connection refused\n"
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let back = try decoder.decode(HealthLogEntry.self, from: data)
        #expect(back == entry)
    }
}
