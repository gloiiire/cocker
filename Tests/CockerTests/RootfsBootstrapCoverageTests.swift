import Foundation
import Testing
@testable import CockerCore

/// Everything cockerd writes into a container's rootfs before boot. Pure
/// string/byte building, and the only thing standing between a Dockerfile's
/// `STOPSIGNAL`/`cap_add` and what the guest actually applies.
@Suite("Rootfs bootstrap")
struct RootfsBootstrapCoverageTests {

    // MARK: - STOPSIGNAL

    @Test func resolvesSignalNames() {
        #expect(RootfsBootstrap.resolveStopSignal("SIGQUIT") == 3)
        #expect(RootfsBootstrap.resolveStopSignal("SIGTERM") == 15)
        #expect(RootfsBootstrap.resolveStopSignal("SIGINT") == 2)
        #expect(RootfsBootstrap.resolveStopSignal("SIGKILL") == 9)
    }

    /// Dockerfiles write it both ways.
    @Test func acceptsTheBareFormAndNumbers() {
        #expect(RootfsBootstrap.resolveStopSignal("QUIT") == 3)
        #expect(RootfsBootstrap.resolveStopSignal("15") == 15)
    }

    /// 0 means "init's own default" — an unknown name must land there rather
    /// than on some arbitrary signal.
    @Test func unknownSignalsFallBackToTheDefault() {
        #expect(RootfsBootstrap.resolveStopSignal(nil) == 0)
        #expect(RootfsBootstrap.resolveStopSignal("") == 0)
        #expect(RootfsBootstrap.resolveStopSignal("SIGNOSUCH") == 0)
    }

    // MARK: - Capabilities

    @Test func resolvesCapabilityNames() {
        #expect(RootfsBootstrap.resolveCap("NET_ADMIN") != nil)
        #expect(RootfsBootstrap.resolveCap("CAP_NET_ADMIN") != nil)
        #expect(RootfsBootstrap.resolveCap("CAP_NET_ADMIN") == RootfsBootstrap.resolveCap("NET_ADMIN"))
    }

    /// Docker warns and carries on for an unknown capability rather than
    /// failing the run; nil is how that reaches the encoder.
    @Test func unknownCapabilitiesAreDropped() {
        #expect(RootfsBootstrap.resolveCap("NOT_A_CAP") == nil)
        #expect(RootfsBootstrap.resolveCap("") == nil)
    }

    // MARK: - /etc/resolv.conf

    @Test func resolvConfPointsAtTheGivenServer() {
        let text = RootfsBootstrap.buildResolvConf(dnsIP: "127.0.0.1")
        #expect(text.contains("nameserver 127.0.0.1"))
        #expect(text.hasSuffix("\n"), "a resolver file without a trailing newline is a classic parse trap")
    }

    // MARK: - /etc/hosts

    @Test func hostsMapsLoopbackAndTheContainerItself() {
        let text = RootfsBootstrap.buildHosts(containerName: "web", hostname: "web", ip: "172.17.0.2")
        #expect(text.contains("127.0.0.1"))
        #expect(text.contains("localhost"))
        #expect(text.contains("172.17.0.2"))
        #expect(text.contains("web"))
    }

    /// A container with no address yet still needs a usable hosts file —
    /// omitting loopback breaks name resolution inside the container.
    @Test func hostsSurvivesAMissingIP() {
        let text = RootfsBootstrap.buildHosts(containerName: "web", hostname: "web", ip: nil)
        #expect(text.contains("127.0.0.1"))
        #expect(!text.contains("()"))
    }

    // MARK: - Spec encoding

    @Test func argvRoundTripsInOrder() {
        let data = RootfsBootstrap.encodeSpec(command: ["/bin/sh", "-c", "echo hi"],
                                              env: [:], workdir: nil)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("/bin/sh"))
        #expect(text.contains("echo hi"))
    }

    /// The guest gets no environment from the kernel, so a container with no
    /// PATH could not exec anything by name.
    @Test func injectsTheDefaultsAContainerCannotDoWithout() {
        let text = String(decoding: RootfsBootstrap.encodeSpec(command: ["sh"], env: [:], workdir: nil),
                          as: UTF8.self)
        for expected in ["PATH=", "HOME=", "TERM="] {
            #expect(text.contains(expected), "missing \(expected)")
        }
    }

    @Test func callerValuesWinOverTheDefaults() {
        let text = String(decoding: RootfsBootstrap.encodeSpec(
            command: ["sh"], env: ["PATH": "/custom/bin"], workdir: nil), as: UTF8.self)
        #expect(text.contains("PATH=/custom/bin"))
    }

    @Test func workdirFallsBackToRoot() {
        let data = RootfsBootstrap.encodeSpec(command: ["sh"], env: [:], workdir: nil)
        #expect(String(decoding: data, as: UTF8.self).contains("/"))
        let explicit = RootfsBootstrap.encodeSpec(command: ["sh"], env: [:], workdir: "/app")
        #expect(String(decoding: explicit, as: UTF8.self).contains("/app"))
    }

    /// `WORKDIR` in the environment is how the Dockerfile's value reaches
    /// here when nothing overrides it on the command line.
    @Test func workdirCanComeFromTheEnvironment() {
        let data = RootfsBootstrap.encodeSpec(command: ["sh"], env: ["WORKDIR": "/srv"], workdir: nil)
        #expect(String(decoding: data, as: UTF8.self).contains("/srv"))
    }

    @Test func writesTheSpecWhereInitLooksForIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-spec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try RootfsBootstrap.writeSpec(to: root, command: ["true"], env: [:], workdir: nil)
        let written = root.appendingPathComponent("cocker-spec")
        #expect(FileManager.default.fileExists(atPath: written.path))
        #expect(try Data(contentsOf: written).starts(with: RootfsBootstrap.specMagic))
    }

    @Test func writesResolvConfAndHosts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-etc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("etc"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try RootfsBootstrap.writeResolvConf(to: root, dnsIP: "10.0.0.1")
        let resolv = root.appendingPathComponent("etc/resolv.conf")
        #expect(try String(contentsOf: resolv, encoding: .utf8).contains("10.0.0.1"))

        try RootfsBootstrap.writeHostsIfAbsent(to: root, containerName: "web",
                                               hostname: "web", ip: "172.17.0.2")
        #expect(try String(contentsOf: root.appendingPathComponent("etc/hosts"),
                           encoding: .utf8).contains("web"))
    }

    /// An image that ships its own /etc/hosts keeps it — overwriting one a
    /// Dockerfile deliberately wrote would be a silent surprise.
    @Test func doesNotOverwriteAnExistingHostsFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-hosts-\(UUID().uuidString)")
        let etc = root.appendingPathComponent("etc")
        try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hosts = etc.appendingPathComponent("hosts")
        try "# shipped by the image\n".write(to: hosts, atomically: true, encoding: .utf8)
        try RootfsBootstrap.writeHostsIfAbsent(to: root, containerName: "web",
                                               hostname: "web", ip: "1.2.3.4")
        #expect(try String(contentsOf: hosts, encoding: .utf8).contains("shipped by the image"))
    }
}
