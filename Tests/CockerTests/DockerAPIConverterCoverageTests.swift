import Foundation
import Testing
import CockerCore
@testable import CockerDaemon

/// The DTOs every Docker client actually parses. A field in the wrong shape
/// here doesn't fail loudly — the client decodes it and acts on something
/// that isn't true.
@Suite("Docker API DTO conversion")
struct DockerAPIConverterCoverageTests {

    private func container(_ mutate: (inout Container) -> Void = { _ in }) -> Container {
        var c = Container(id: "abc123abc123", name: "web", image: "nginx:latest",
                          command: ["nginx", "-g", "daemon off;"])
        mutate(&c)
        return c
    }

    // MARK: - Container summary (docker ps)

    @Test func summaryCarriesIdentity() {
        let s = DockerContainerSummary(from: container())
        #expect(s.Id == "abc123abc123")
        #expect(s.Image == "nginx:latest")
        #expect(s.Command.contains("nginx"))
    }

    /// Docker reports container names with a leading slash. Clients strip it;
    /// omitting it makes name matching fail in some of them.
    @Test func namesCarryDockersLeadingSlash() {
        #expect(DockerContainerSummary(from: container()).Names.first == "/web")
    }

    @Test func portsAreExposedWithTheirProtocol() {
        let c = container {
            $0.ports = [PortMapping(hostPort: 8080, containerPort: 80),
                        PortMapping(hostPort: 5353, containerPort: 53, proto: .udp)]
        }
        let ports = DockerContainerSummary(from: c).Ports
        #expect(ports.count == 2)
        #expect(ports.contains { $0.PrivatePort == 80 && $0.PublicPort == 8080 && $0.portType == "tcp" })
        #expect(ports.contains { $0.portType == "udp" })
    }

    /// A host path is a bind mount, a name is a volume. Getting this backwards
    /// makes `docker inspect` misreport what a container is actually using.
    @Test func mountTypeFollowsTheSource() {
        let c = container {
            $0.volumes = [VolumeMount(source: "/host/path", destination: "/data"),
                          VolumeMount(source: "pgdata", destination: "/var/lib/pg")]
        }
        let mounts = DockerContainerSummary(from: c).Mounts
        #expect(mounts.first(where: { $0.Source == "/host/path" })?.mountType == "bind")
        #expect(mounts.first(where: { $0.Source == "pgdata" })?.mountType == "volume")
    }

    @Test func readOnlyMountsAreReportedAsSuch() {
        let c = container {
            $0.volumes = [VolumeMount(source: "conf", destination: "/etc/conf", readOnly: true)]
        }
        let mount = DockerContainerSummary(from: c).Mounts.first
        #expect(mount?.Mode == "ro")
        #expect(mount?.RW == false)
    }

    @Test func labelsSurvive() {
        let c = container { $0.labels = ["com.docker.compose.project": "shop"] }
        #expect(DockerContainerSummary(from: c).Labels["com.docker.compose.project"] == "shop")
    }

    // MARK: - Status vocabulary

    /// Docker says `exited` where cocker's state machine says `stopped`, and
    /// clients filter and display on Docker's word.
    @Test func statusUsesDockersVocabulary() {
        #expect(ContainerStatus.stopped.dockerState == "exited")
        #expect(ContainerStatus.running.dockerState == "running")
        #expect(ContainerStatus.paused.dockerState == "paused")
    }

    @Test func exitedStatusStringCarriesTheCode() {
        let text = ContainerStatus.stopped.dockerStatus(startedAt: Date(), exitCode: 137)
        #expect(text.contains("137"))
        #expect(text.lowercased().contains("exited"))
    }

    @Test func runningStatusReadsAsUptime() {
        let text = ContainerStatus.running.dockerStatus(startedAt: Date(), exitCode: nil)
        #expect(text.lowercased().contains("up"))
    }

    // MARK: - Image / network / volume

    @Test func imageSummaryCarriesTagAndSize() {
        var img = ImageInfo(id: "sha256:abc", repository: "nginx", tag: "1.25")
        img.size = 4096
        let s = DockerImageSummary(from: img)
        #expect(s.Id.contains("abc"))
        #expect(s.RepoTags.contains("nginx:1.25"))
        #expect(s.Size == 4096)
    }

    @Test func networkResourceCarriesDriverAndSubnet() {
        let net = NetworkInfo(name: "shop_default", driver: .bridge,
                              subnet: "172.20.0.0/16", gateway: "172.20.0.1")
        let r = DockerNetworkResource(from: net)
        #expect(r.Name == "shop_default")
        #expect(r.Driver == "bridge")
    }

    @Test func volumeResourceCarriesNameAndMountpoint() {
        let vol = VolumeInfo(name: "pgdata", mountpoint: "/x/pgdata/data.img", driver: "local")
        let r = DockerVolumeResource(from: vol)
        #expect(r.Name == "pgdata")
        #expect(r.Mountpoint == "/x/pgdata/data.img")
        #expect(r.Driver == "local")
    }

    // MARK: - Encoding

    /// Whatever the shape is, it has to survive JSON — a client that can't
    /// decode the response sees a broken daemon, not a missing field.
    @Test func summariesEncodeToJSON() throws {
        let data = try JSONEncoder().encode(DockerContainerSummary(from: container()))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["Id"] as? String == "abc123abc123")
        #expect(json["Names"] != nil)
        #expect(json["State"] != nil)
    }
}
