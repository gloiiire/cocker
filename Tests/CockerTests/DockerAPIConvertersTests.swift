import Testing
import Foundation
@testable import CockerCore
@testable import CockerDaemon

// The `init(from:)` extension converters in DockerAPITypes.swift translate
// cocker's internal model into Docker Engine API v1.41 shapes. They're
// pure data mapping (no async, no IO), so they're high-leverage unit
// tests : every Container/Image/Network/Volume status the daemon can
// surface goes through one of these.

@Suite("Container → DockerContainerSummary conversion")
struct ContainerSummaryConversionTests {
    private func sample(status: ContainerStatus = .running) -> Container {
        var c = Container(
            id: "abcdef123456",
            name: "web",
            image: "nginx:alpine",
            command: ["nginx", "-g", "daemon off;"],
            status: status,
            ports: [PortMapping(hostPort: 8080, containerPort: 80, proto: .tcp)],
            volumes: [VolumeMount(source: "/host/data", destination: "/data", readOnly: false)],
            env: ["KEY": "val"],
            labels: ["env": "prod"],
            networkMode: .nat
        )
        c.startedAt = Date(timeIntervalSinceNow: -30)
        return c
    }

    @Test func mapsCoreFields() {
        let s = DockerContainerSummary(from: sample())
        #expect(s.Id == "abcdef123456")
        #expect(s.Names == ["/web"])
        #expect(s.Image == "nginx:alpine")
        #expect(s.Command == "nginx -g daemon off;")
        #expect(s.Labels == ["env": "prod"])
    }

    @Test func portsTranslated() {
        let s = DockerContainerSummary(from: sample())
        #expect(s.Ports.count == 1)
        #expect(s.Ports.first?.PrivatePort == 80)
        #expect(s.Ports.first?.PublicPort == 8080)
        #expect(s.Ports.first?.portType == "tcp")
    }

    @Test func bindMountClassification() {
        let s = DockerContainerSummary(from: sample())
        #expect(s.Mounts.count == 1)
        let m = s.Mounts[0]
        #expect(m.mountType == "bind")
        #expect(m.Source == "/host/data")
        #expect(m.Destination == "/data")
        #expect(m.RW == true)
        #expect(m.Mode == "rw")
    }

    @Test func namedVolumeMountClassification() {
        var c = sample()
        c.volumes = [VolumeMount(source: "myvol", destination: "/var/lib", readOnly: true)]
        let s = DockerContainerSummary(from: c)
        #expect(s.Mounts.first?.mountType == "volume")
        #expect(s.Mounts.first?.RW == false)
        #expect(s.Mounts.first?.Mode == "ro")
    }

    @Test func emptyCommandStillFormatsCleanly() {
        var c = sample()
        c.command = []
        let s = DockerContainerSummary(from: c)
        #expect(s.Command == "")
    }

    @Test func runningStatusShowsUpUptime() {
        let s = DockerContainerSummary(from: sample(status: .running))
        #expect(s.State == "running")
        #expect(s.Status.hasPrefix("Up"))
    }

    @Test func stoppedStatusShowsExited() {
        var c = sample(status: .stopped)
        c.exitCode = 0
        c.finishedAt = Date(timeIntervalSinceNow: -10)
        let s = DockerContainerSummary(from: c)
        #expect(s.State == "exited")
        #expect(s.Status.hasPrefix("Exited"))
    }

    @Test func pausedAndRestartingStateMapping() {
        let p = DockerContainerSummary(from: sample(status: .paused))
        #expect(p.State == "paused")
        #expect(p.Status == "Up (Paused)")

        let r = DockerContainerSummary(from: sample(status: .restarting))
        #expect(r.State == "restarting")
        #expect(r.Status == "Restarting")
    }

    @Test func createdAndDeadStateMapping() {
        let cr = DockerContainerSummary(from: sample(status: .created))
        #expect(cr.State == "created")
        #expect(cr.Status == "Created")

        let dd = DockerContainerSummary(from: sample(status: .dead))
        #expect(dd.State == "dead")
        #expect(dd.Status == "Dead")
    }
}

@Suite("ImageInfo → DockerImageSummary conversion")
struct ImageSummaryConversionTests {
    @Test func mapsCoreFields() {
        let img = ImageInfo(
            id: "sha256:abc",
            repository: "alpine",
            tag: "3.20",
            size: 5_500_000,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            layers: ["sha256:layer1"]
        )
        let s = DockerImageSummary(from: img)
        #expect(s.Id == "sha256:abc")
        #expect(s.RepoTags == ["alpine:3.20"])
        #expect(s.RepoDigests == ["alpine@sha256:abc"])
        #expect(s.Size == 5_500_000)
        #expect(s.VirtualSize == 5_500_000)
        #expect(s.Created == 1_700_000_000)
        #expect(s.SharedSize == 0)
        #expect(s.Containers == 0)
    }
}

@Suite("NetworkInfo → DockerNetworkResource conversion")
struct NetworkResourceConversionTests {
    @Test func mapsBridgeNetwork() {
        let net = NetworkInfo(
            id: "net123",
            name: "mynet",
            driver: .bridge,
            subnet: "172.21.0.0/16",
            gateway: "172.21.0.1"
        )
        let r = DockerNetworkResource(from: net)
        #expect(r.Id == "net123")
        #expect(r.Name == "mynet")
        #expect(r.Driver == "bridge")
        #expect(r.Scope == "local")
        #expect(r.EnableIPv6 == false)
        #expect(r.IPAM.Config.first?.Subnet == "172.21.0.0/16")
        #expect(r.IPAM.Config.first?.Gateway == "172.21.0.1")
        #expect(r.IPAM.Driver == "default")
    }

    @Test func mapsHostNetwork() {
        let net = NetworkInfo(
            id: "host", name: "host", driver: .host,
            subnet: "0.0.0.0/0", gateway: "0.0.0.0"
        )
        let r = DockerNetworkResource(from: net)
        #expect(r.Driver == "host")
    }
}

@Suite("VolumeInfo → DockerVolumeResource conversion")
struct VolumeResourceConversionTests {
    @Test func mapsLocalVolume() {
        let vol = VolumeInfo(
            name: "myvol",
            mountpoint: "/var/lib/cocker/volumes/myvol/_data",
            driver: "local",
            labels: ["app": "db"]
        )
        let r = DockerVolumeResource(from: vol)
        #expect(r.Name == "myvol")
        #expect(r.Driver == "local")
        #expect(r.Mountpoint == "/var/lib/cocker/volumes/myvol/_data")
        #expect(r.Labels == ["app": "db"])
        #expect(r.Scope == "local")
    }

    @Test func emptyLabelsAreOK() {
        let vol = VolumeInfo(name: "x", mountpoint: "/m", driver: "local", labels: [:])
        let r = DockerVolumeResource(from: vol)
        #expect(r.Labels.isEmpty)
    }
}

@Suite("ContainerStatus.dockerState — string mapping")
struct ContainerStatusDockerStateTests {
    @Test func allCasesMap() {
        #expect(ContainerStatus.running.dockerState == "running")
        #expect(ContainerStatus.stopped.dockerState == "exited")
        #expect(ContainerStatus.created.dockerState == "created")
        #expect(ContainerStatus.paused.dockerState == "paused")
        #expect(ContainerStatus.restarting.dockerState == "restarting")
        #expect(ContainerStatus.dead.dockerState == "dead")
    }
}

@Suite("ContainerStatus.dockerStatus — uptime / exit formatting")
struct ContainerStatusDockerStatusTests {
    @Test func runningWithoutStartedAtFallsBackToZero() {
        // No startedAt → uptime 0s. Should still produce a valid string.
        let s = ContainerStatus.running.dockerStatus(startedAt: nil, exitCode: nil)
        #expect(s.hasPrefix("Up"))
    }

    @Test func stoppedShowsExitCode() {
        let s = ContainerStatus.stopped.dockerStatus(startedAt: Date(), exitCode: 137)
        #expect(s.hasPrefix("Exited (137)"))
    }

    @Test func stoppedWithoutExitCodeDefaultsToZero() {
        let s = ContainerStatus.stopped.dockerStatus(startedAt: Date(), exitCode: nil)
        #expect(s.hasPrefix("Exited (0)"))
    }

    @Test func createdAndPausedAreStatic() {
        #expect(ContainerStatus.created.dockerStatus(startedAt: nil, exitCode: nil) == "Created")
        #expect(ContainerStatus.paused.dockerStatus(startedAt: Date(), exitCode: nil) == "Up (Paused)")
    }

    @Test func deadAndRestartingAreStatic() {
        #expect(ContainerStatus.dead.dockerStatus(startedAt: nil, exitCode: nil) == "Dead")
        #expect(ContainerStatus.restarting.dockerStatus(startedAt: nil, exitCode: nil) == "Restarting")
    }
}
