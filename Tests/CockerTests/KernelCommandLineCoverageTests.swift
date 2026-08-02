import Foundation
import Testing
@testable import CockerCore

/// The kernel command line is the only channel that configures a container's
/// VM before `cocker-init` can read anything else — the rootfs backend, the
/// networks, the volume table. A mistake here doesn't fail loudly; the
/// container boots into the wrong shape.
@Suite("Kernel command line")
struct KernelCommandLineCoverageTests {

    private func container(_ mutate: (inout Container) -> Void = { _ in }) -> Container {
        var c = Container(id: "abc123abc123", name: "web", image: "alpine", command: ["sh"])
        mutate(&c)
        return c
    }

    private func params(_ c: Container,
                        rootDevice: String? = nil,
                        buildOverlay: Bool = false,
                        outboxTag: String? = nil,
                        volumeSpecs: [String] = []) -> KernelCommandLineParams {
        KernelCommandLineParams(container: c, dnsIP: "192.168.64.1", dnsPort: 5300,
                                cockerSwitchGateway: "10.42.0.1",
                                volumeSpecs: volumeSpecs,
                                rootDevice: rootDevice,
                                buildOverlay: buildOverlay,
                                outboxTag: outboxTag)
    }

    // MARK: - Rootfs backend

    @Test func defaultsToTheVirtiofsShare() {
        let line = KernelCommandLine.build(params(container()))
        #expect(line.contains("root=virtiofs"))
        #expect(line.contains("rootfstype=virtiofs"))
        #expect(!line.contains("cocker.rootfs="))
    }

    /// The image-build path boots from a real ext4 disk. The stock `root=`
    /// has to agree with what cocker-init mounts, or the kernel and init
    /// disagree about what the rootfs even is.
    @Test func blockRootfsSetsBothTheKernelAndInitViews() {
        let line = KernelCommandLine.build(params(container(), rootDevice: "/dev/vda"))
        #expect(line.contains("root=/dev/vda"))
        #expect(line.contains("rootfstype=ext4"))
        #expect(line.contains("cocker.rootfs=blk:/dev/vda"))
    }

    @Test func buildOverlayIsDistinctFromAPlainBlockRoot() {
        let line = KernelCommandLine.build(
            params(container(), rootDevice: "/dev/vda", buildOverlay: true, outboxTag: "outbox"))
        #expect(line.contains("cocker.rootfs=overlay:/dev/vda"))
        #expect(line.contains("cocker.outbox=outbox"))
    }

    // MARK: - Identity and DNS

    @Test func carriesIdentityAndDNS() {
        let line = KernelCommandLine.build(params(container()))
        #expect(line.contains("cocker.id=abc123abc123"))
        #expect(line.contains("cocker.name=web"))
        #expect(line.contains("cocker.dns=192.168.64.1"))
        #expect(line.contains("cocker.dns_port=5300"))
        #expect(line.contains("console=hvc0"))
    }

    // MARK: - Switch fabric

    /// Both the IP and the MAC have to be present, or eth1 comes up without
    /// an identity on the inter-container fabric.
    @Test func switchFabricNeedsBothIPAndMAC() {
        let withBoth = container {
            $0.cockerIP = "10.42.0.5"
            $0.cockerMAC = "02:42:0a:2a:00:05"
        }
        let line = KernelCommandLine.build(params(withBoth))
        #expect(line.contains("cocker.cnet_ip=10.42.0.5/16"))
        #expect(line.contains("cocker.cnet_gw=10.42.0.1"))
        #expect(line.contains("cocker.cnet_mac=02:42:0a:2a:00:05"))

        // Only one of the pair → the whole block is omitted rather than
        // half-configured.
        let ipOnly = container { $0.cockerIP = "10.42.0.5" }
        #expect(!KernelCommandLine.build(params(ipOnly)).contains("cnet_ip"))
    }

    // MARK: - Ports and volumes

    @Test func portsCarryTheirProtocol() {
        let c = container {
            $0.ports = [PortMapping(hostPort: 8080, containerPort: 80),
                        PortMapping(hostPort: 5353, containerPort: 53, proto: .udp)]
        }
        let line = KernelCommandLine.build(params(c))
        #expect(line.contains("cocker.port.80=8080/tcp"))
        #expect(line.contains("cocker.port.53=5353/udp"))
    }

    /// The runtime hands over already-resolved specs (block or virtiofs).
    /// They must be used verbatim — re-synthesising them would erase the
    /// block/virtiofs distinction the volume moat depends on.
    @Test func resolvedVolumeSpecsWinOverSynthesis() {
        let c = container { $0.volumes = [VolumeMount(source: "data", destination: "/data")] }
        let line = KernelCommandLine.build(
            params(c, volumeSpecs: ["blk:/dev/vdb:/data", "virtiofs:vol1:/etc/conf"]))
        #expect(line.contains("cocker.vol0=blk:/dev/vdb:/data"))
        #expect(line.contains("cocker.vol1=virtiofs:vol1:/etc/conf"))
    }

    /// Callers that predate block storage still get a working line.
    @Test func fallsBackToVirtiofsSynthesis() {
        let c = container { $0.volumes = [VolumeMount(source: "data", destination: "/data")] }
        #expect(KernelCommandLine.build(params(c)).contains("cocker.vol0=virtiofs:vol0:/data"))
    }

    // MARK: - Workdir / user / hostname

    @Test func carriesWorkdirUserAndHostname() {
        let c = container {
            $0.env["WORKDIR"] = "/app"
            $0.env["USER"] = "appuser"
        }
        let line = KernelCommandLine.build(params(c))
        #expect(line.contains("cocker.workdir=/app"))
        #expect(line.contains("cocker.user=appuser"))
        #expect(line.contains("cocker.hostname="))
    }

    @Test func omitsWhatWasNotSet() {
        let line = KernelCommandLine.build(params(container()))
        #expect(!line.contains("cocker.workdir="))
        #expect(!line.contains("cocker.user="))
        #expect(!line.contains("cocker.outbox="))
    }
}
