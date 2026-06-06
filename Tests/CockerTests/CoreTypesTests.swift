import Testing
import Foundation
@testable import CockerCore

@Suite("Credentials")
struct CredentialsTests {
    @Test func emptyStoreReturnsNilForAnyRegistry() {
        let store = CredentialStore()
        #expect(store.get(for: "registry-1.docker.io") == nil)
        #expect(store.get(for: "ghcr.io") == nil)
        #expect(store.get(for: "") == nil)
    }

    @Test func exactMatchOnFullRegistry() {
        var store = CredentialStore()
        store.credentials["ghcr.io"] = .init(username: "alice", password: "secret")
        let cred = store.get(for: "ghcr.io")
        #expect(cred?.username == "alice")
        #expect(cred?.password == "secret")
    }

    @Test func fallbackToHostnamePrefix() {
        var store = CredentialStore()
        store.credentials["ghcr.io"] = .init(username: "alice", password: "pw")
        // Asking for "ghcr.io/owner/repo" should fall back to "ghcr.io"
        let cred = store.get(for: "ghcr.io")
        #expect(cred?.username == "alice")
    }

    @Test func differentRegistriesAreIsolated() {
        var store = CredentialStore()
        store.credentials["ghcr.io"] = .init(username: "alice", password: "a")
        store.credentials["docker.io"] = .init(username: "bob", password: "b")
        #expect(store.get(for: "ghcr.io")?.username == "alice")
        #expect(store.get(for: "docker.io")?.username == "bob")
        #expect(store.get(for: "quay.io") == nil)
    }
}

@Suite("Cocker Context")
struct CockerContextTests {
    @Test func defaultContextSocketPath() {
        let ctx = CockerContext(name: "default", dockerHost: "unix:///Users/me/.cocker/cocker.sock")
        #expect(ctx.socketPath == "/Users/me/.cocker/cocker.sock")
    }

    @Test func tcpHostHasNoSocketPath() {
        let ctx = CockerContext(name: "remote", dockerHost: "tcp://1.2.3.4:2376")
        #expect(ctx.socketPath == nil)
    }

    @Test func tildeIsExpandedInSocketPath() {
        let ctx = CockerContext(name: "tilde", dockerHost: "unix://~/.cocker/cocker.sock")
        let path = ctx.socketPath
        #expect(path?.hasPrefix("/") == true)
        #expect(path?.contains(".cocker/cocker.sock") == true)
        #expect(path?.contains("~") == false)
    }

    @Test func storeLoadGuaranteesDefault() {
        let store = ContextStore.load()
        #expect(store.contexts.contains(where: { $0.name == "default" }))
    }

    @Test func currentContextDefaultsToFirstIfMissing() {
        var store = ContextStore()
        store.contexts = [
            CockerContext(name: "alpha", dockerHost: "unix:///a"),
            CockerContext(name: "beta", dockerHost: "unix:///b"),
        ]
        store.current = "nope"
        #expect(store.currentContext == nil)
    }

    @Test func currentSocketPathFallback() {
        let store = ContextStore()
        // No contexts → falls back to a default path
        #expect(store.currentSocketPath.hasSuffix(".cocker/cocker.sock"))
    }
}

@Suite("Cocker Error descriptions")
struct CockerErrorTests {
    @Test func containerNotFoundMessage() {
        let e = CockerError.containerNotFound("abc123")
        #expect(e.description.contains("abc123"))
        #expect(e.description.lowercased().contains("no such container"))
    }

    @Test func containerAlreadyExistsMessage() {
        let e = CockerError.containerAlreadyExists("web")
        #expect(e.description.contains("web"))
    }

    @Test func imageNotFoundMessage() {
        let e = CockerError.imageNotFound("nginx:latest")
        #expect(e.description.contains("nginx:latest"))
    }

    @Test func invalidPortMappingMentionsExpectedFormat() {
        let e = CockerError.invalidPortMapping("bogus")
        #expect(e.description.contains("bogus"))
        #expect(e.description.contains("host:container"))
    }

    @Test func kernelNotFoundIncludesSetupHint() {
        let e = CockerError.kernelNotFound("/some/path")
        #expect(e.description.contains("/some/path"))
        #expect(e.description.contains("cockerd setup"))
    }

    @Test func daemonNotRunningMentionsCockerd() {
        let e = CockerError.daemonNotRunning
        #expect(e.description.lowercased().contains("cockerd"))
    }

    @Test func errorDescriptionAndLocalizedAreEqual() {
        let e: CockerError = .internalError("boom")
        #expect(e.description == e.errorDescription)
    }
}

@Suite("Container Model defaults")
struct ContainerModelDefaultTests {
    @Test func idIsTruncatedToTwelve() {
        let c = Container(id: "abcdefabcdef999999", name: "x", image: "alpine", command: [])
        #expect(c.id.count == 12)
        #expect(c.id == "abcdefabcdef")
    }

    @Test func hostnameDefaultsToIdPrefix() {
        let c = Container(id: "abcdefabcdef999", name: "x", image: "alpine", command: [])
        #expect(c.hostname == "abcdefabcdef")
    }

    @Test func explicitHostnameWins() {
        let c = Container(id: "abc", name: "x", image: "alpine", command: [], hostname: "myhost")
        #expect(c.hostname == "myhost")
    }

    @Test func defaultStatusIsCreated() {
        let c = Container(name: "x", image: "alpine", command: [])
        #expect(c.status == .created)
    }

    @Test func portMappingsEmptyByDefault() {
        let c = Container(name: "x", image: "alpine", command: [])
        #expect(c.ports.isEmpty)
    }

    @Test func restartPolicyDefaultsToNo() {
        let c = Container(name: "x", image: "alpine", command: [])
        #expect(c.restartPolicy == .no)
    }

    @Test func healthStatusDefaultsToNone() {
        let c = Container(name: "x", image: "alpine", command: [])
        #expect(c.healthStatus == .none)
    }
}

@Suite("Port mapping descriptions")
struct PortMappingDescriptionTests {
    @Test func tcpDefault() {
        let p = PortMapping(hostPort: 8080, containerPort: 80)
        #expect(p.description == "0.0.0.0:8080->80/tcp")
    }

    @Test func udpProto() {
        let p = PortMapping(hostPort: 53, containerPort: 53, proto: .udp)
        #expect(p.description == "0.0.0.0:53->53/udp")
    }
}

@Suite("Volume mount descriptions")
struct VolumeMountDescriptionTests {
    @Test func readWriteSpec() {
        let v = VolumeMount(source: "myvol", destination: "/data")
        #expect(v.description == "myvol:/data")
        #expect(!v.readOnly)
    }

    @Test func readOnlySpec() {
        let v = VolumeMount(source: "/host", destination: "/c", readOnly: true)
        #expect(v.description == "/host:/c:ro")
    }
}

@Suite("Run config defaults")
struct RunConfigDefaultTests {
    @Test func defaultsAreReasonable() {
        let r = RunConfig(image: "alpine")
        #expect(r.image == "alpine")
        #expect(r.command.isEmpty)
        #expect(r.detach == false)
        #expect(r.interactive == false)
        #expect(r.tty == false)
        #expect(r.cpuCount == 2)
        #expect(r.memoryMB == 512)
        #expect(r.restartPolicy == .no)
    }

    @Test func commandRespectsExplicitValue() {
        let r = RunConfig(image: "alpine", command: ["/bin/echo", "hi"])
        #expect(r.command == ["/bin/echo", "hi"])
    }
}

@Suite("Image info")
struct ImageInfoTests {
    @Test func referenceCombinesRepoAndTag() {
        let img = ImageInfo(id: "sha256:abc", repository: "library/alpine", tag: "latest")
        #expect(img.reference == "library/alpine:latest")
    }

    @Test func optionalConfigFieldsAreNilByDefault() {
        let img = ImageInfo(id: "sha256:abc", repository: "x", tag: "y")
        #expect(img.cmd == nil)
        #expect(img.entrypoint == nil)
        #expect(img.env == nil)
        #expect(img.workdir == nil)
        #expect(img.labels.isEmpty)
        #expect(img.exposedPorts.isEmpty)
    }

    @Test func canCarryDockerfileConfig() {
        let img = ImageInfo(
            id: "sha256:abc",
            repository: "x",
            tag: "y",
            cmd: ["/app/main"],
            entrypoint: ["/sbin/init"],
            env: ["APP=test"],
            workdir: "/app",
            labels: ["maintainer": "me"],
            exposedPorts: ["80/tcp"]
        )
        #expect(img.cmd == ["/app/main"])
        #expect(img.entrypoint == ["/sbin/init"])
        #expect(img.env == ["APP=test"])
        #expect(img.workdir == "/app")
        #expect(img.labels["maintainer"] == "me")
        #expect(img.exposedPorts == ["80/tcp"])
    }
}

@Suite("OCI Manifest")
struct OCIManifestTests {
    @Test func descriptorDetectsGzipLayer() {
        let d = OCIDescriptor(
            mediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
            digest: "sha256:abc",
            size: 100,
            urls: nil
        )
        #expect(d.isGzipLayer)
        #expect(!d.isZstdLayer)
    }

    @Test func descriptorDetectsZstdLayer() {
        let d = OCIDescriptor(
            mediaType: "application/vnd.oci.image.layer.v1.tar+zstd",
            digest: "sha256:abc",
            size: 100,
            urls: nil
        )
        #expect(d.isZstdLayer)
        #expect(!d.isGzipLayer)
    }

    @Test func referenceShortNameStripsLibraryPrefix() throws {
        let ref = try ImageReference.parse("alpine:3.20")
        #expect(ref.shortName == "alpine:3.20")
    }

    @Test func referenceShortNameKeepsUserPath() throws {
        let ref = try ImageReference.parse("myuser/myapp:v1")
        #expect(ref.shortName == "myuser/myapp:v1")
    }

    @Test func referenceShortNameIncludesNonDefaultRegistry() throws {
        let ref = try ImageReference.parse("ghcr.io/owner/repo:v1")
        #expect(ref.shortName == "ghcr.io/owner/repo:v1")
    }

    @Test func fullNameUsesDigestIfPresent() throws {
        let ref = try ImageReference.parse("alpine@sha256:deadbeef")
        #expect(ref.fullName.contains("@sha256:deadbeef"))
    }

    @Test func pullURLFormat() throws {
        let ref = try ImageReference.parse("alpine:latest")
        #expect(ref.pullURL == "registry-1.docker.io/v2/library/alpine")
    }
}

@Suite("Network info")
struct NetworkInfoTests {
    @Test func defaultsForBridge() {
        let n = NetworkInfo(name: "bridge")
        #expect(n.driver == .bridge)
        #expect(n.subnet == "172.20.0.0/16")
        #expect(n.gateway == "172.20.0.1")
        #expect(n.containers.isEmpty)
    }

    @Test func explicitSubnetWins() {
        let n = NetworkInfo(name: "x", subnet: "10.0.0.0/24", gateway: "10.0.0.1")
        #expect(n.subnet == "10.0.0.0/24")
        #expect(n.gateway == "10.0.0.1")
    }
}

@Suite("Volume info")
struct VolumeInfoTests {
    @Test func mountpointDefaultsUnderHome() {
        let v = VolumeInfo(name: "myvol")
        #expect(v.mountpoint.hasSuffix("/.cocker/volumes/myvol/_data"))
        #expect(v.driver == "local")
    }

    @Test func explicitMountpointWins() {
        let v = VolumeInfo(name: "x", mountpoint: "/tmp/explicit")
        #expect(v.mountpoint == "/tmp/explicit")
    }
}

@Suite("Container status")
struct ContainerStatusMappingTests {
    @Test func descriptionMatchesRawValue() {
        #expect(ContainerStatus.running.description == "running")
        #expect(ContainerStatus.stopped.description == "stopped")
        #expect(ContainerStatus.created.description == "created")
    }
}

@Suite("Utils host IP")
struct UtilsHostIPTests {
    @Test func returnsRoutableIPv4OrLoopback() {
        let ip = localHostIP()
        #expect(!ip.isEmpty)
        let parts = ip.split(separator: ".")
        #expect(parts.count == 4)
        // Each component should be a valid 0–255 integer
        for p in parts {
            let n = Int(p)
            #expect(n != nil)
            #expect((0...255).contains(n!))
        }
    }
}

@Suite("Exec config")
struct ExecConfigTests {
    @Test func defaults() {
        let e = ExecConfig(containerID: "abc", command: ["sh"])
        #expect(e.interactive == false)
        #expect(e.tty == false)
        #expect(e.env.isEmpty)
    }
}

@Suite("Build config")
struct BuildConfigTests {
    @Test func defaults() {
        let b = BuildConfig(contextPath: "/ctx", tag: "myimage:1")
        #expect(b.dockerfile == "Dockerfile")
        #expect(b.tag == "myimage:1")
        #expect(b.buildArgs.isEmpty)
        #expect(!b.noCache)
    }
}

@Suite("Network create request")
struct NetworkCreateRequestTests {
    @Test func defaults() {
        let r = NetworkCreateRequest(name: "n1")
        #expect(r.driver == .bridge)
        #expect(r.subnet == nil)
        #expect(r.gateway == nil)
        #expect(r.labels.isEmpty)
    }
}

@Suite("Volume create request")
struct VolumeCreateRequestTests {
    @Test func defaults() {
        let r = VolumeCreateRequest(name: "v1")
        #expect(r.driver == "local")
        #expect(r.labels.isEmpty)
    }
}

@Suite("IPC empty / ping / info payloads")
struct IPCPayloadShapeTests {
    @Test func emptyPayloadInitMakes() {
        let _ = EmptyPayload()
    }

    @Test func pingResponseHasVersion() {
        let p = PingResponse()
        #expect(p.version == CockerVersion.version)
        #expect(p.apiVersion == CockerVersion.apiVersion)
        #expect(!p.buildTime.isEmpty)
    }

    @Test func infoResponseRoundtrips() throws {
        let info = InfoResponse(
            containers: 3, containersRunning: 1, images: 5, volumes: 2, networks: 4,
            kernelVersion: "6.12", architecture: "arm64", cpus: 8, totalMemory: 1_000_000,
            cockerRootDir: "/x", socketPath: "/x.sock"
        )
        let data = try JSONEncoder().encode(info)
        let back = try JSONDecoder().decode(InfoResponse.self, from: data)
        #expect(back.containers == 3)
        #expect(back.containersRunning == 1)
        #expect(back.kernelVersion == "6.12")
    }
}

@Suite("Error variants — full enumeration")
struct CockerErrorVariantsTests {
    @Test func allVariantsHaveNonEmptyDescription() {
        let cases: [CockerError] = [
            .containerNotFound("x"),
            .containerAlreadyExists("x"),
            .containerNotRunning("x"),
            .containerAlreadyRunning("x"),
            .imageNotFound("x"),
            .imageAlreadyExists("x"),
            .imagePullFailed("x", "y"),
            .invalidImageReference("x"),
            .manifestNotFound("x"),
            .layerDownloadFailed("x", "y"),
            .dockerfileNotFound("x"),
            .buildFailed("x"),
            .invalidDockerfileInstruction("x"),
            .buildContextTooLarge(1024 * 1024 * 1024),
            .networkNotFound("x"),
            .networkAlreadyExists("x"),
            .networkInUse("x"),
            .invalidSubnet("x"),
            .volumeNotFound("x"),
            .volumeAlreadyExists("x"),
            .volumeInUse("x"),
            .vmStartFailed("x"),
            .vmStopFailed("x"),
            .kernelNotFound("/k"),
            .initrdNotFound("/i"),
            .vmCommunicationFailed("x"),
            .daemonNotRunning,
            .connectionFailed("x"),
            .requestFailed("x"),
            .responseDecodingFailed("x"),
            .invalidPortMapping("x"),
            .invalidVolumeSpec("x"),
            .invalidEnvironmentVar("x"),
            .invalidComposeFile("x"),
            .permissionDenied("x"),
            .diskFull,
            .unsupportedPlatform("x"),
            .internalError("x"),
        ]
        for e in cases {
            #expect(!e.description.isEmpty, "empty description for \(e)")
            #expect(e.errorDescription == e.description, "errorDescription mismatch for \(e)")
        }
    }

    @Test func messagesPassThroughArguments() {
        #expect(CockerError.containerNotFound("c1").description.contains("c1"))
        #expect(CockerError.imagePullFailed("nginx", "timeout").description.contains("nginx"))
        #expect(CockerError.imagePullFailed("nginx", "timeout").description.contains("timeout"))
        #expect(CockerError.layerDownloadFailed("sha:1", "bad").description.contains("sha:1"))
        #expect(CockerError.buildContextTooLarge(1024 * 1024).description.contains("MB"))
        #expect(CockerError.networkInUse("backend").description.contains("backend"))
        #expect(CockerError.invalidVolumeSpec("x:y:z:w").description.contains("source:dest"))
    }
}

@Suite("Credentials roundtrip + register")
struct CredentialsRoundtripTests {
    @Test func encoderDecoderRoundtrip() throws {
        var store = CredentialStore()
        store.credentials["ghcr.io"] = .init(username: "alice", password: "pw")
        store.credentials["docker.io"] = .init(username: "bob", password: "x")
        let data = try JSONEncoder().encode(store)
        let back = try JSONDecoder().decode(CredentialStore.self, from: data)
        #expect(back.credentials.count == 2)
        #expect(back.credentials["ghcr.io"]?.username == "alice")
    }

    @Test func storeRegistry() {
        let cred = CredentialStore.Credential(username: "u", password: "p")
        #expect(cred.username == "u")
        #expect(cred.password == "p")
    }
}

@Suite("IPC Protocol encoding")
struct IPCProtocolEncodingTests {
    @Test func runRequestRoundtrip() throws {
        var cfg = RunConfig(image: "nginx")
        cfg.detach = true
        cfg.ports = [PortMapping(hostPort: 8080, containerPort: 80)]
        let req = RunRequest(config: cfg)
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(RunRequest.self, from: data)
        #expect(back.config.image == "nginx")
        #expect(back.config.detach == true)
        #expect(back.config.ports.first?.hostPort == 8080)
    }

    @Test func runResponseRoundtrip() throws {
        let r = RunResponse(containerID: "abc")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RunResponse.self, from: data)
        #expect(back.containerID == "abc")
    }

    @Test func containerIDRequestRoundtrip() throws {
        let r = ContainerIDRequest(id: "abc", signal: "SIGKILL")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ContainerIDRequest.self, from: data)
        #expect(back.id == "abc")
        #expect(back.signal == "SIGKILL")
    }

    @Test func psRequestRoundtrip() throws {
        let r = PSRequest(all: true, filter: ["status": "running"])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(PSRequest.self, from: data)
        #expect(back.all == true)
        #expect(back.filter["status"] == "running")
    }

    @Test func logsRequestRoundtripWithDefaults() throws {
        let r = LogsRequest(id: "c")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(LogsRequest.self, from: data)
        #expect(back.id == "c")
        #expect(back.tail == 100)
        #expect(back.follow == false)
    }

    @Test func pullRequestRoundtrip() throws {
        let r = PullRequest(reference: "alpine:latest", platform: "linux/arm64")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(PullRequest.self, from: data)
        #expect(back.reference == "alpine:latest")
        #expect(back.platform == "linux/arm64")
    }

    @Test func networkCreateRequestRoundtrip() throws {
        let r = NetworkCreateRequest(
            name: "backend", driver: .bridge,
            subnet: "10.0.0.0/16", gateway: "10.0.0.1",
            labels: ["env": "prod"]
        )
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(NetworkCreateRequest.self, from: data)
        #expect(back.name == "backend")
        #expect(back.driver == .bridge)
        #expect(back.subnet == "10.0.0.0/16")
        #expect(back.labels["env"] == "prod")
    }

    @Test func volumeCreateRequestRoundtrip() throws {
        let r = VolumeCreateRequest(name: "vol1", driver: "local", labels: ["app": "x"])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(VolumeCreateRequest.self, from: data)
        #expect(back.name == "vol1")
        #expect(back.driver == "local")
        #expect(back.labels["app"] == "x")
    }

    @Test func streamEventRoundtrip() throws {
        let e = StreamEvent(stream: .stderr, data: "boom")
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(StreamEvent.self, from: data)
        #expect(back.stream == .stderr)
        #expect(back.data == "boom")
    }

    @Test func psResponseRoundtrip() throws {
        let r = PSResponse(containers: [
            Container(name: "a", image: "alpine", command: ["sh"])
        ])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(PSResponse.self, from: data)
        #expect(back.containers.count == 1)
        #expect(back.containers[0].name == "a")
    }

    @Test func imagesResponseRoundtrip() throws {
        let r = ImagesResponse(images: [
            ImageInfo(id: "sha256:a", repository: "x", tag: "y")
        ])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ImagesResponse.self, from: data)
        #expect(back.images.count == 1)
    }
}

@Suite("OCI manifest extra")
struct OCIManifestExtraTests {
    @Test func ociImageConfigStructInits() {
        let cfg = OCIImageConfig(
            architecture: "arm64", os: "linux",
            config: OCIImageConfig.ContainerConfig(
                user: "root", exposedPorts: nil, env: ["A=1"], cmd: ["sh"],
                entrypoint: nil, workingDir: "/", labels: nil, stopSignal: nil, volumes: nil
            ),
            rootfs: OCIImageConfig.RootFS(type: "layers", diffIDs: ["sha256:a"]),
            history: nil
        )
        #expect(cfg.architecture == "arm64")
        #expect(cfg.config?.cmd == ["sh"])
        #expect(cfg.rootfs?.diffIDs == ["sha256:a"])
    }

    @Test func ociHistoryInit() {
        let h = OCIImageConfig.LayerHistory(
            created: "2026-06-06",
            createdBy: "RUN",
            emptyLayer: false,
            comment: "test"
        )
        #expect(h.created == "2026-06-06")
        #expect(h.createdBy == "RUN")
        #expect(h.comment == "test")
    }

    @Test func ociDescriptorRoundtrip() throws {
        let d = OCIDescriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:abc", size: 100, urls: nil
        )
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(OCIDescriptor.self, from: data)
        #expect(back.digest == "sha256:abc")
        #expect(back.size == 100)
    }
}

@Suite("Image reference edge cases")
struct ImageReferenceEdgeCases {
    @Test func parseDigestPreservesRepoTag() throws {
        let ref = try ImageReference.parse("alpine:latest@sha256:abc")
        #expect(ref.tag == "latest")
        #expect(ref.digest == "sha256:abc")
    }

    @Test func parseDeepUserPath() throws {
        let ref = try ImageReference.parse("group/sub/repo:1")
        #expect(ref.repository == "group/sub/repo")
    }
}

@Suite("Network mode + restart policy")
struct EnumsCoverageTests {
    @Test func networkModesRoundtripCodable() throws {
        for mode in [NetworkMode.nat, .bridged, .host, .none] {
            let data = try JSONEncoder().encode(mode)
            let back = try JSONDecoder().decode(NetworkMode.self, from: data)
            #expect(back == mode)
        }
    }

    @Test func restartPolicyRawValues() {
        #expect(RestartPolicy.no.rawValue == "no")
        #expect(RestartPolicy.always.rawValue == "always")
        #expect(RestartPolicy.onFailure.rawValue == "on-failure")
        #expect(RestartPolicy.unlessStopped.rawValue == "unless-stopped")
    }

    @Test func healthStatusValues() {
        for h in [HealthStatus.none, .starting, .healthy, .unhealthy] {
            #expect(!h.rawValue.isEmpty)
        }
    }

    @Test func transportProtoValues() {
        #expect(TransportProto.tcp.rawValue == "tcp")
        #expect(TransportProto.udp.rawValue == "udp")
    }

    @Test func networkDriverValues() {
        #expect(NetworkDriver.bridge.rawValue == "bridge")
        #expect(NetworkDriver.host.rawValue == "host")
        #expect(NetworkDriver.overlay.rawValue == "overlay")
    }
}

@Suite("Port mapping parse edge cases")
struct PortMappingParseEdge {
    @Test func parseSingleNumber() throws {
        let p = try PortMapping.parse("443")
        #expect(p.hostPort == 443)
        #expect(p.containerPort == 443)
        #expect(p.proto == .tcp)
    }

    @Test func parseHostContainer() throws {
        let p = try PortMapping.parse("8080:80")
        #expect(p.hostPort == 8080)
        #expect(p.containerPort == 80)
    }

    @Test func parseGarbage() {
        #expect(throws: CockerError.self) {
            try PortMapping.parse("abc")
        }
    }

    @Test func parseEmpty() {
        #expect(throws: CockerError.self) {
            try PortMapping.parse("")
        }
    }
}

@Suite("Volume mount parse edge cases")
struct VolumeMountParseEdge {
    @Test func parseBindWithRO() throws {
        let v = try VolumeMount.parse("/host:/c:ro")
        #expect(v.readOnly)
    }

    @Test func parseNamedRW() throws {
        let v = try VolumeMount.parse("vol:/data")
        #expect(!v.readOnly)
        #expect(v.source == "vol")
    }

    @Test func parseSingleArgFails() {
        #expect(throws: CockerError.self) {
            try VolumeMount.parse("/only-source")
        }
    }
}

@Suite("Context store mutation")
struct ContextStoreMutationTests {
    @Test func addRemoveContext() {
        var store = ContextStore()
        store.contexts = [
            CockerContext(name: "a", dockerHost: "unix:///a")
        ]
        store.current = "a"
        #expect(store.currentContext?.name == "a")
        #expect(store.currentSocketPath == "/a")
    }
}
