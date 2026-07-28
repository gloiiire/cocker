import Testing
import Foundation
@testable import CockerCore

// Codable roundtrip for the IPC request/response types. Every payload
// crossing the daemon socket must encode then decode losslessly ;
// adding a non-optional field to one of these structs without a
// migration story would silently break older CLI / daemon combos.

@Suite("IPC payloads — Codable roundtrip")
struct IPCRoundtripTests {
    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    @Test func emptyPayload() throws {
        let raw = try enc.encode(EmptyPayload())
        _ = try dec.decode(EmptyPayload.self, from: raw)
    }

    @Test func imagePruneRequestRoundtrips() throws {
        for flag in [true, false] {
            let back = try dec.decode(ImagePruneRequest.self, from: enc.encode(ImagePruneRequest(all: flag)))
            #expect(back.all == flag)
        }
    }

    @Test func imagePruneDefaultsToAllFalse() throws {
        // Safety default when constructed without an argument.
        #expect(ImagePruneRequest().all == false)
    }

    @Test func imagePruneFallsBackWhenEmptyPayloadSent() throws {
        // An older CLI sends EmptyPayload for `image prune`. The daemon decodes
        // it as ImagePruneRequest with `try?` and must fall back to all:false
        // (the safe, backward-compatible prune) rather than crash.
        let legacy = try enc.encode(EmptyPayload())
        let decoded = (try? dec.decode(ImagePruneRequest.self, from: legacy)) ?? ImagePruneRequest(all: false)
        #expect(decoded.all == false)
    }

    @Test func saveLoadExportImportV2PathHandoffRoundtrips() throws {
        let save = try dec.decode(SaveRequest.self, from: enc.encode(
            SaveRequest(image: "alpine:latest", outputPath: "/tmp/image.tar")))
        #expect(save.image == "alpine:latest")
        #expect(save.outputPath == "/tmp/image.tar")

        let saveResponse = try dec.decode(SaveResponse.self, from: enc.encode(
            SaveResponse(tarData: Data(), filePath: "/tmp/image.tar", byteCount: 123)))
        #expect(saveResponse.tarData.isEmpty)
        #expect(saveResponse.filePath == "/tmp/image.tar")
        #expect(saveResponse.byteCount == 123)

        let load = try dec.decode(LoadRequest.self, from: enc.encode(
            LoadRequest(tarData: Data(), inputPath: "/tmp/image.tar")))
        #expect(load.tarData.isEmpty)
        #expect(load.inputPath == "/tmp/image.tar")

        let export = try dec.decode(ExportRequest.self, from: enc.encode(
            ExportRequest(containerID: "abc", outputPath: "/tmp/rootfs.tar")))
        #expect(export.containerID == "abc")
        #expect(export.outputPath == "/tmp/rootfs.tar")

        let imp = try dec.decode(ContainerImportRequest.self, from: enc.encode(
            ContainerImportRequest(tarData: Data(), tag: "repo:tag", inputPath: "/tmp/rootfs.tar")))
        #expect(imp.tarData.isEmpty)
        #expect(imp.tag == "repo:tag")
        #expect(imp.inputPath == "/tmp/rootfs.tar")
    }

    @Test func v2PayloadsDecodeLegacyShapes() throws {
        // Older peers omit every path/metadata field. The v2 decoder must
        // default them instead of breaking mixed-version CLI/daemon pairs.
        let legacySave = try dec.decode(SaveRequest.self, from: Data(#"{"image":"alpine"}"#.utf8))
        #expect(legacySave.outputPath == nil)

        let bytes = Data("tar".utf8)
        let legacyResponse = try dec.decode(SaveResponse.self, from: enc.encode(["tarData": bytes]))
        #expect(legacyResponse.tarData == bytes)
        #expect(legacyResponse.filePath == nil)

        let legacyLoad = try dec.decode(LoadRequest.self, from: enc.encode(["tarData": bytes]))
        #expect(legacyLoad.tarData == bytes)
        #expect(legacyLoad.inputPath == nil)

        let legacyExport = try dec.decode(ExportRequest.self,
            from: Data(#"{"containerID":"abc"}"#.utf8))
        #expect(legacyExport.outputPath == nil)

        let legacyImport = try dec.decode(ContainerImportRequest.self,
            from: enc.encode(LegacyImport(tarData: bytes, tag: "repo:tag")))
        #expect(legacyImport.tarData == bytes)
        #expect(legacyImport.inputPath == nil)
    }

    private struct LegacyImport: Codable {
        let tarData: Data
        let tag: String
    }

    @Test func pingResponseCarriesVersion() throws {
        let p = PingResponse()
        let back = try dec.decode(PingResponse.self, from: enc.encode(p))
        #expect(back.version == CockerVersion.version)
        #expect(back.apiVersion == CockerVersion.apiVersion)
        #expect(back.buildTime == CockerVersion.buildTime)
    }

    @Test func runRequestRoundtripsConfig() throws {
        var cfg = RunConfig(image: "alpine:latest", command: ["sh", "-c", "echo hi"])
        cfg.name = "test"
        cfg.detach = true
        cfg.ports = [PortMapping(hostPort: 8080, containerPort: 80, proto: .tcp)]
        cfg.env = ["KEY": "val"]
        let req = RunRequest(config: cfg)
        let back = try dec.decode(RunRequest.self, from: enc.encode(req))
        #expect(back.config.image == "alpine:latest")
        #expect(back.config.command == ["sh", "-c", "echo hi"])
        #expect(back.config.name == "test")
        #expect(back.config.detach)
        #expect(back.config.ports.first?.hostPort == 8080)
        #expect(back.config.env["KEY"] == "val")
    }

    @Test func runResponseRoundtrip() throws {
        let r = RunResponse(containerID: "abc123def456")
        let back = try dec.decode(RunResponse.self, from: enc.encode(r))
        #expect(back.containerID == "abc123def456")
    }

    @Test func containerIDRequestRoundtrip() throws {
        let r = ContainerIDRequest(id: "abc", signal: "SIGTERM", force: true)
        let back = try dec.decode(ContainerIDRequest.self, from: enc.encode(r))
        #expect(back.id == "abc")
        #expect(back.signal == "SIGTERM")
        #expect(back.force == true)
    }

    @Test func containerIDRequestWithDefaultsRoundtrip() throws {
        let r = ContainerIDRequest(id: "abc")
        let back = try dec.decode(ContainerIDRequest.self, from: enc.encode(r))
        #expect(back.signal == nil)
        #expect(back.force == nil)
    }

    @Test func psRequestRoundtrip() throws {
        let r = PSRequest(all: true, filter: ["status": "running"])
        let back = try dec.decode(PSRequest.self, from: enc.encode(r))
        #expect(back.all)
        #expect(back.filter == ["status": "running"])
    }

    @Test func logsRequestRoundtrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r = LogsRequest(id: "c", follow: true, tail: 50, timestamps: true, since: now)
        let back = try dec.decode(LogsRequest.self, from: enc.encode(r))
        #expect(back.id == "c")
        #expect(back.follow)
        #expect(back.tail == 50)
        #expect(back.timestamps)
        #expect(back.since == now)
    }

    @Test func pullRequestWithPlatformRoundtrip() throws {
        let r = PullRequest(reference: "alpine:3.20", platform: "linux/arm64")
        let back = try dec.decode(PullRequest.self, from: enc.encode(r))
        #expect(back.reference == "alpine:3.20")
        #expect(back.platform == "linux/arm64")
    }

    @Test func networkCreateRequestRoundtrip() throws {
        let r = NetworkCreateRequest(
            name: "mynet",
            driver: .bridge,
            subnet: "172.30.0.0/16",
            gateway: "172.30.0.1",
            labels: ["env": "test"]
        )
        let back = try dec.decode(NetworkCreateRequest.self, from: enc.encode(r))
        #expect(back.name == "mynet")
        #expect(back.driver == .bridge)
        #expect(back.subnet == "172.30.0.0/16")
        #expect(back.gateway == "172.30.0.1")
        #expect(back.labels == ["env": "test"])
    }

    @Test func psResponseRoundtripPreservesContainerFields() throws {
        let c = Container(
            id: "c1", name: "n", image: "alpine", command: [],
            status: .running,
            healthcheck: Healthcheck(test: ["CMD-SHELL", "true"], interval: 5),
            healthFailingStreak: 2,
            healthLog: [HealthLogEntry(start: Date(timeIntervalSince1970: 1),
                                       end: Date(timeIntervalSince1970: 2),
                                       exitCode: 1,
                                       output: "boom")]
        )
        let r = PSResponse(containers: [c])
        let back = try dec.decode(PSResponse.self, from: enc.encode(r))
        #expect(back.containers.count == 1)
        #expect(back.containers.first?.healthFailingStreak == 2)
        #expect(back.containers.first?.healthLog.first?.output == "boom")
        #expect(back.containers.first?.healthcheck?.test == ["CMD-SHELL", "true"])
    }
}
