import Testing
import Foundation
@testable import CockerCore

@Suite("Kernel command line builder")
struct KernelCommandLineTests {
    private func makeContainer(
        id: String = "abc123",
        name: String = "web",
        hostname: String = "web",
        ports: [PortMapping] = [],
        volumes: [VolumeMount] = [],
        env: [String: String] = [:],
        ip: String? = nil,
        cockerIP: String? = nil,
        cockerMAC: String? = nil
    ) -> Container {
        var c = Container(
            id: id, name: name,
            image: "alpine:latest", command: ["sh"],
            ports: ports, volumes: volumes,
            env: env,
            hostname: hostname
        )
        c.ip = ip
        c.cockerIP = cockerIP
        c.cockerMAC = cockerMAC
        return c
    }

    @Test func includesMandatoryBootParams() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(),
            dnsIP: "192.168.64.1",
            dnsPort: 5300,
            cockerSwitchGateway: "10.42.0.1"
        ))
        #expect(cmdline.contains("console=hvc0"))
        #expect(cmdline.contains("root=virtiofs"))
        #expect(cmdline.contains("rootfstype=virtiofs"))
        #expect(cmdline.contains("rw"))
        #expect(cmdline.contains("quiet"))
    }

    @Test func carriesIdNameAndHostname() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(id: "deadbeef1234", name: "srv-a", hostname: "myhost"),
            dnsIP: "1.2.3.4", dnsPort: 5300, cockerSwitchGateway: "10.42.0.1"
        ))
        #expect(cmdline.contains("cocker.id=deadbeef1234"))
        #expect(cmdline.contains("cocker.name=srv-a"))
        #expect(cmdline.contains("cocker.hostname=myhost"))
    }

    @Test func omitsHostnameWhenEmpty() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(hostname: ""),
            dnsIP: "1.2.3.4", dnsPort: 5300, cockerSwitchGateway: "10.42.0.1"
        ))
        #expect(!cmdline.contains("cocker.hostname"))
    }

    @Test func includesDnsHostAndPortAndVsockPort() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(),
            dnsIP: "192.168.64.1",
            dnsPort: 5300,
            dnsVsockPort: 5353,
            cockerSwitchGateway: "10.42.0.1"
        ))
        #expect(cmdline.contains("cocker.dns=192.168.64.1"))
        #expect(cmdline.contains("cocker.dns_port=5300"))
        #expect(cmdline.contains("cocker.dns_vsock_port=5353"))
    }

    @Test func emitsSwitchParamsWhenCockerIPAndMACPresent() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(cockerIP: "10.42.0.5", cockerMAC: "02:42:0a:2a:00:05"),
            dnsIP: "192.168.64.1", dnsPort: 5300,
            cockerSwitchGateway: "10.42.0.1"
        ))
        #expect(cmdline.contains("cocker.cnet_ip=10.42.0.5/16"))
        #expect(cmdline.contains("cocker.cnet_gw=10.42.0.1"))
        #expect(cmdline.contains("cocker.cnet_mac=02:42:0a:2a:00:05"))
    }

    @Test func omitsSwitchParamsWhenIPMissing() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(),  // no cockerIP / cockerMAC
            dnsIP: "192.168.64.1", dnsPort: 5300,
            cockerSwitchGateway: "10.42.0.1"
        ))
        #expect(!cmdline.contains("cocker.cnet_ip"))
        #expect(!cmdline.contains("cocker.cnet_gw"))
        #expect(!cmdline.contains("cocker.cnet_mac"))
    }

    @Test func emitsPortMappings() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(ports: [
                PortMapping(hostPort: 8080, containerPort: 80, proto: .tcp),
                PortMapping(hostPort: 5353, containerPort: 53, proto: .udp),
            ]),
            dnsIP: "1.2.3.4", dnsPort: 5300, cockerSwitchGateway: "10.42.0.1"
        ))
        #expect(cmdline.contains("cocker.port.80=8080/tcp"))
        #expect(cmdline.contains("cocker.port.53=5353/udp"))
    }

    @Test func emitsVolumeMounts() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(volumes: [
                VolumeMount(source: "myvol", destination: "/data"),
                VolumeMount(source: "logs", destination: "/var/log"),
            ]),
            dnsIP: "1.2.3.4", dnsPort: 5300, cockerSwitchGateway: "10.42.0.1"
        ))
        #expect(cmdline.contains("cocker.vol0=vol0:/data"))
        #expect(cmdline.contains("cocker.vol1=vol1:/var/log"))
    }

    @Test func emitsWorkdirAndUserFromEnv() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(env: ["WORKDIR": "/app", "USER": "nobody"]),
            dnsIP: "1.2.3.4", dnsPort: 5300, cockerSwitchGateway: "10.42.0.1"
        ))
        #expect(cmdline.contains("cocker.workdir=/app"))
        #expect(cmdline.contains("cocker.user=nobody"))
    }

    @Test func resultIsSingleSpaceSeparatedString() {
        let cmdline = KernelCommandLine.build(KernelCommandLineParams(
            container: makeContainer(),
            dnsIP: "1.2.3.4", dnsPort: 5300, cockerSwitchGateway: "10.42.0.1"
        ))
        // No newlines, no double-spaces — bootloader is picky.
        #expect(!cmdline.contains("\n"))
        #expect(!cmdline.contains("  "))
    }
}

@Suite("Rootfs bootstrap — /cocker-spec")
struct CockerSpecTests {
    private func parseSpec(_ data: Data) -> (argv: [String], env: [String], workdir: String) {
        // Mirror cocker-init's parser : 3 lines, NUL-separated within each.
        let parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let argv = parts[0].split(separator: 0).map { String(data: Data($0), encoding: .utf8) ?? "" }
        let env  = parts.count > 1 ? parts[1].split(separator: 0).map { String(data: Data($0), encoding: .utf8) ?? "" } : []
        let wd   = parts.count > 2 ? (String(data: Data(parts[2]), encoding: .utf8) ?? "/") : "/"
        return (argv, env, wd)
    }

    @Test func encodeSpecRoundtripsArgv() {
        let data = RootfsBootstrap.encodeSpec(
            command: ["/bin/sh", "-c", "echo hi && exit 0"],
            env: [:],
            workdir: nil
        )
        let parsed = parseSpec(data)
        #expect(parsed.argv == ["/bin/sh", "-c", "echo hi && exit 0"])
    }

    @Test func encodeSpecInjectsDefaultPath() {
        let data = RootfsBootstrap.encodeSpec(command: ["sh"], env: [:], workdir: nil)
        let parsed = parseSpec(data)
        #expect(parsed.env.contains { $0.hasPrefix("PATH=/usr/local/sbin") })
    }

    @Test func encodeSpecInjectsDefaultHomeAndTerm() {
        let data = RootfsBootstrap.encodeSpec(command: ["sh"], env: [:], workdir: nil)
        let parsed = parseSpec(data)
        #expect(parsed.env.contains("HOME=/root"))
        #expect(parsed.env.contains("TERM=xterm"))
    }

    @Test func encodeSpecRespectsUserPath() {
        let data = RootfsBootstrap.encodeSpec(command: ["sh"], env: ["PATH": "/opt/bin"], workdir: nil)
        let parsed = parseSpec(data)
        #expect(parsed.env.contains("PATH=/opt/bin"))
        #expect(!parsed.env.contains { $0.hasPrefix("PATH=/usr/local/sbin") })
    }

    @Test func encodeSpecCarriesUserEnv() {
        let data = RootfsBootstrap.encodeSpec(
            command: ["sh"],
            env: ["FOO": "bar", "BAZ": "qux"],
            workdir: nil
        )
        let parsed = parseSpec(data)
        #expect(parsed.env.contains("FOO=bar"))
        #expect(parsed.env.contains("BAZ=qux"))
    }

    @Test func encodeSpecWorkdirFallback() {
        let dataNil = RootfsBootstrap.encodeSpec(command: ["sh"], env: [:], workdir: nil)
        #expect(parseSpec(dataNil).workdir == "/")

        let dataEnv = RootfsBootstrap.encodeSpec(command: ["sh"], env: ["WORKDIR": "/srv"], workdir: nil)
        #expect(parseSpec(dataEnv).workdir == "/srv")

        let dataExplicit = RootfsBootstrap.encodeSpec(command: ["sh"], env: ["WORKDIR": "/srv"], workdir: "/app")
        #expect(parseSpec(dataExplicit).workdir == "/app")
    }

    @Test func writeSpecPersistsToFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-spec-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try RootfsBootstrap.writeSpec(
            to: tmp,
            command: ["/bin/echo", "hi"],
            env: ["FOO": "bar"],
            workdir: "/app"
        )

        let read = try Data(contentsOf: tmp.appendingPathComponent("cocker-spec"))
        let parsed = parseSpec(read)
        #expect(parsed.argv == ["/bin/echo", "hi"])
        #expect(parsed.env.contains("FOO=bar"))
        #expect(parsed.workdir == "/app")
    }
}

@Suite("Rootfs bootstrap — /etc/resolv.conf and /etc/hosts")
struct ResolvHostsTests {
    @Test func resolvConfPointsAtProvidedDNS() {
        let rc = RootfsBootstrap.buildResolvConf(dnsIP: "192.168.64.1")
        #expect(rc.contains("nameserver 192.168.64.1"))
        #expect(rc.contains("search cocker"))
    }

    @Test func hostsContainsLocalhost() {
        let h = RootfsBootstrap.buildHosts(containerName: "web", hostname: "web", ip: nil)
        #expect(h.contains("127.0.0.1   localhost"))
        #expect(h.contains("::1         localhost"))
    }

    @Test func hostsCarriesContainerEntryWhenIPPresent() {
        let h = RootfsBootstrap.buildHosts(containerName: "web", hostname: "myhost", ip: "10.42.0.5")
        #expect(h.contains("10.42.0.5   web myhost"))
    }

    @Test func hostsHasNoContainerEntryWhenIPNil() {
        let h = RootfsBootstrap.buildHosts(containerName: "web", hostname: "web", ip: nil)
        #expect(!h.contains("web web"))
    }

    @Test func writeResolvConfCreatesEtcDir() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-resolv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try RootfsBootstrap.writeResolvConf(to: tmp, dnsIP: "1.2.3.4")
        let content = try String(contentsOf: tmp.appendingPathComponent("etc/resolv.conf"))
        #expect(content.contains("nameserver 1.2.3.4"))
    }

    @Test func writeHostsIfAbsentDoesNotOverwrite() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-hosts-test-\(UUID().uuidString)")
        let etcDir = tmp.appendingPathComponent("etc")
        try FileManager.default.createDirectory(at: etcDir, withIntermediateDirectories: true)
        let hostsPath = etcDir.appendingPathComponent("hosts")
        try "EXISTING".write(to: hostsPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try RootfsBootstrap.writeHostsIfAbsent(
            to: tmp, containerName: "web", hostname: "web", ip: "10.42.0.5"
        )
        let content = try String(contentsOf: hostsPath)
        #expect(content == "EXISTING")  // untouched
    }

    @Test func writeHostsIfAbsentCreatesWhenMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-hosts-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try RootfsBootstrap.writeHostsIfAbsent(
            to: tmp, containerName: "web", hostname: "web", ip: "10.42.0.5"
        )
        let content = try String(contentsOf: tmp.appendingPathComponent("etc/hosts"))
        #expect(content.contains("127.0.0.1"))
        #expect(content.contains("10.42.0.5   web web"))
    }
}
