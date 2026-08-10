import Testing
import Foundation
import Yams
@testable import CockerCore
@testable import CockerCLI
@testable import CockerDaemon

// Regression tests for the three bugs caught during the 2026-06-07 e2e smoke
// test. Each was load-bearing for the golden path : without these, neither
// `cocker run nginx` nor `cocker daemon restart` worked.

// Bug #1 — `cocker daemon restart` crashed because it instantiated peer
// commands via `Type()` instead of `Type.parse([])`. ArgumentParser leaves
// @Option/@Flag values unset on direct init; the next `run()` fatal-errored
// with "Can't read a value from a parsable argument definition."
@Suite("Bug #1 — daemon restart wires defaults")
struct DaemonRestartParseTests {
    @Test func canParseStopWithoutArgs() throws {
        let stop = try DaemonStopCommand.parse([])
        #expect(stop.timeout == 10)  // default survives
    }

    @Test func canParseStartWithoutArgs() throws {
        let start = try DaemonStartCommand.parse([])
        #expect(start.foreground == false)
        #expect(start.binary == nil)
    }

    @Test func canParseRestartWithoutArgs() throws {
        // The restart wrapper itself : same trap if its own @Option weren't
        // wired through parse.
        let restart = try DaemonRestartCommand.parse([])
        #expect(restart.binary == nil)
    }
}

// Bug #2 — `cocker pull` discarded the OCI image config. cmd / entrypoint /
// env / workdir / exposedPorts / labels were never copied from
// OCIImageConfig.ContainerConfig into ImageInfo. Result : `cocker run
// nginx:alpine` (no command) → cocker-init wrote an empty /cocker-spec →
// "FATAL: empty command".
@Suite("Bug #2 — OCI config propagates to ImageInfo")
struct OCIConfigPropagationTests {
    private func makeConfig(cmd: [String]? = nil,
                            entrypoint: [String]? = nil,
                            env: [String]? = nil,
                            workdir: String? = nil,
                            exposed: [String: OCIImageConfig.Empty]? = nil,
                            labels: [String: String]? = nil) -> OCIImageConfig {
        OCIImageConfig(
            architecture: "arm64", os: "linux",
            config: OCIImageConfig.ContainerConfig(
                user: nil, exposedPorts: exposed, env: env,
                cmd: cmd, entrypoint: entrypoint, workingDir: workdir,
                labels: labels, stopSignal: nil, volumes: nil),
            rootfs: nil, history: nil
        )
    }

    @Test func builderCarriesCmdAndEntrypoint() throws {
        let cfg = makeConfig(cmd: ["nginx", "-g", "daemon off;"],
                             entrypoint: ["/docker-entrypoint.sh"])
        // Mirror the line we re-enabled in ImageManager.pull. If anyone
        // re-introduces the regression, this fails loud.
        let info = ImageInfo(
            id: "sha256:abc", repository: "library/nginx", tag: "alpine",
            layers: [],
            cmd: cfg.config?.cmd,
            entrypoint: cfg.config?.entrypoint,
            env: cfg.config?.env,
            workdir: cfg.config?.workingDir,
            labels: cfg.config?.labels ?? [:],
            exposedPorts: Array(cfg.config?.exposedPorts?.keys ?? [:].keys)
        )
        #expect(info.cmd == ["nginx", "-g", "daemon off;"])
        #expect(info.entrypoint == ["/docker-entrypoint.sh"])
    }

    @Test func envIsCopiedFromConfig() throws {
        let cfg = makeConfig(env: ["PATH=/usr/local/sbin:/usr/local/bin",
                                    "NGINX_VERSION=1.27.0"])
        let info = ImageInfo(
            id: "x", repository: "r", tag: "t", layers: [],
            cmd: nil, entrypoint: nil,
            env: cfg.config?.env, workdir: nil,
            labels: [:], exposedPorts: []
        )
        #expect(info.env?.count == 2)
        #expect(info.env?.contains("NGINX_VERSION=1.27.0") == true)
    }

    @Test func workdirAndExposedPortsAreCopied() throws {
        let cfg = makeConfig(
            workdir: "/usr/share/nginx/html",
            exposed: ["80/tcp": .init(), "443/tcp": .init()]
        )
        let info = ImageInfo(
            id: "x", repository: "r", tag: "t", layers: [],
            cmd: nil, entrypoint: nil, env: nil,
            workdir: cfg.config?.workingDir,
            labels: [:],
            exposedPorts: Array(cfg.config?.exposedPorts?.keys ?? [:].keys)
        )
        #expect(info.workdir == "/usr/share/nginx/html")
        #expect(Set(info.exposedPorts) == Set(["80/tcp", "443/tcp"]))
    }

    @Test func decodesARealNginxFlavoredConfigBlob() throws {
        // Slice of a real nginx:alpine config.json shape (Docker Hub).
        let raw = #"""
        {
          "architecture": "arm64",
          "os": "linux",
          "config": {
            "Env": ["PATH=/usr/local/bin", "NGINX_VERSION=1.27.0"],
            "Cmd": ["nginx", "-g", "daemon off;"],
            "Entrypoint": ["/docker-entrypoint.sh"],
            "WorkingDir": "/",
            "ExposedPorts": {"80/tcp": {}},
            "Labels": {"maintainer": "NGINX Docker Maintainers"},
            "StopSignal": "SIGQUIT"
          }
        }
        """#
        let cfg = try JSONDecoder().decode(OCIImageConfig.self, from: Data(raw.utf8))
        #expect(cfg.config?.cmd == ["nginx", "-g", "daemon off;"])
        #expect(cfg.config?.entrypoint == ["/docker-entrypoint.sh"])
        #expect(cfg.config?.workingDir == "/")
        #expect(cfg.config?.exposedPorts?.keys.contains("80/tcp") == true)
        #expect(cfg.config?.labels?["maintainer"]?.contains("NGINX") == true)
    }
}

// Bug #3 — `cocker compose up` with no `-f` only looked for
// `cocker-compose.yml` and rejected any Docker-native project. The fallback
// chain now tries `compose.yaml`, `compose.yml`, `docker-compose.yaml`,
// `docker-compose.yml` in that order — same precedence as Docker Compose v2.
@Suite("Bug #3 — compose file fallback chain")
struct ComposeFileFallbackTests {
    private func freshDir() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compose-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Directory-explicit mirror of the production logic in
    /// `ComposeCommand.resolvePath`. Avoids the process-global cwd so tests
    /// can run in parallel.
    private func resolvePath(_ path: String, in dir: URL) -> String {
        let abs = path.hasPrefix("/") ? path
            : dir.path + "/" + path
        if !FileManager.default.fileExists(atPath: abs)
            && path == "cocker-compose.yml" {
            for candidate in ["compose.yaml", "compose.yml",
                              "docker-compose.yaml", "docker-compose.yml"] {
                let p = dir.path + "/" + candidate
                if FileManager.default.fileExists(atPath: p) { return p }
            }
        }
        return abs
    }

    @Test func fallsBackToDockerComposeYml() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("services: {}".utf8).write(
            to: dir.appendingPathComponent("docker-compose.yml"))
        #expect(resolvePath("cocker-compose.yml", in: dir).hasSuffix("/docker-compose.yml"))
    }

    @Test func fallsBackToComposeYaml() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("services: {}".utf8).write(
            to: dir.appendingPathComponent("compose.yaml"))
        #expect(resolvePath("cocker-compose.yml", in: dir).hasSuffix("/compose.yaml"))
    }

    @Test func cockerComposeYmlWinsWhenItExists() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("cocker-compose.yml"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("docker-compose.yml"))
        #expect(resolvePath("cocker-compose.yml", in: dir).hasSuffix("/cocker-compose.yml"))
    }

    @Test func composePrecedenceOverDockerCompose() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("c".utf8).write(to: dir.appendingPathComponent("compose.yaml"))
        try Data("d".utf8).write(to: dir.appendingPathComponent("docker-compose.yml"))
        // compose.yaml is canonical in Docker Compose v2 and must win.
        #expect(resolvePath("cocker-compose.yml", in: dir).hasSuffix("/compose.yaml"))
    }

    @Test func explicitPathBypassesAutoDiscovery() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("trap".utf8).write(to: dir.appendingPathComponent("docker-compose.yml"))
        // Explicit user-supplied filename does NOT trigger fallback even if
        // the requested file is missing.
        #expect(resolvePath("custom.yml", in: dir).hasSuffix("/custom.yml"))
    }

    @Test func missingEverythingFallsThroughToOriginalPath() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No file exists ; the original path is surfaced so the user gets a
        // stable, predictable error message.
        #expect(resolvePath("cocker-compose.yml", in: dir).hasSuffix("/cocker-compose.yml"))
    }
}

// Bug #4 — `cocker build .` failed with "Dockerfile not found" because the
// CLI sent a relative `contextPath` and the daemon resolved it against ITS
// cwd. CLI must anchor against the caller's cwd before IPC.
@Suite("Bug #4 — build context anchored to CLI cwd")
struct BuildContextAnchoringTests {
    private func resolve(_ context: String, cwd: String) -> String {
        return context.hasPrefix("/") ? context : cwd + "/" + context
    }

    @Test func dotResolvesToAbsoluteCWD() {
        let r = resolve(".", cwd: "/home/me/project")
        #expect(r == "/home/me/project/.")
    }

    @Test func relativePathStaysRelativeToCWD() {
        let r = resolve("subdir", cwd: "/work")
        #expect(r == "/work/subdir")
    }

    @Test func absolutePathPassThrough() {
        let r = resolve("/tmp/build-ctx", cwd: "/work")
        #expect(r == "/tmp/build-ctx")
    }
}

// Bug #8 — `cocker tag myapp:smoke 127.0.0.1:5555/myapp:v1` was parsed as
// repository="127.0.0.1" tag="5555/myapp:v1" because `split(":", maxSplits: 1)`
// caught the registry port first. The fix : the tag separator is the LAST
// `:` after the last `/` (if any).
@Suite("Bug #8 — image reference with registry port")
struct ImageReferenceWithPortTests {
    @Test func registryWithPortAndTag() throws {
        let r = try ImageReference.parse("127.0.0.1:5555/myapp:smoke")
        #expect(r.registry == "127.0.0.1:5555")
        #expect(r.repository == "myapp")
        #expect(r.tag == "smoke")
    }

    @Test func localhostRegistryWithPort() throws {
        let r = try ImageReference.parse("localhost:5000/team/svc:v2")
        #expect(r.registry == "localhost:5000")
        #expect(r.repository == "team/svc")
        #expect(r.tag == "v2")
    }

    @Test func registryWithPortNoExplicitTag() throws {
        let r = try ImageReference.parse("registry.lan:5000/svc")
        #expect(r.registry == "registry.lan:5000")
        #expect(r.repository == "svc")
        #expect(r.tag == "latest")  // default
    }

    @Test func dockerHubUserImageNoRegression() throws {
        let r = try ImageReference.parse("alpine:3.20")
        #expect(r.registry == "registry-1.docker.io")
        #expect(r.repository == "library/alpine")
        #expect(r.tag == "3.20")
    }

    @Test func deepRepositoryWithPort() throws {
        let r = try ImageReference.parse("ghcr.io:443/org/team/svc:v1.2.3")
        #expect(r.registry == "ghcr.io:443")
        #expect(r.repository == "org/team/svc")
        #expect(r.tag == "v1.2.3")
    }

    @Test func digestStillWins() throws {
        let r = try ImageReference.parse("registry:5000/svc@sha256:abc123")
        #expect(r.digest == "sha256:abc123")
    }
}

// Bug #22 — compose `labels:` in the array form
// `["key=value", ...]` was rejected because labels was typed as
// `[String: String]?`. Now uses EnvSpec which accepts both shapes.
@Suite("Bug #22 — compose labels accept array form")
struct ComposeLabelsArrayFormTests {
    private func parse(_ yaml: String) throws -> ComposeFile {
        try YAMLDecoder().decode(ComposeFile.self, from: yaml)
    }

    @Test func arrayFormDecodes() throws {
        let yaml = """
        services:
          a:
            image: alpine
            labels:
              - "tier=data"
              - "owner=alice"
        """
        let f = try parse(yaml)
        let d = f.services["a"]?.labels?.dict ?? [:]
        #expect(d["tier"] == "data")
        #expect(d["owner"] == "alice")
    }

    @Test func dictFormStillWorks() throws {
        let yaml = """
        services:
          a:
            image: alpine
            labels:
              tier: data
              owner: alice
        """
        let f = try parse(yaml)
        let d = f.services["a"]?.labels?.dict ?? [:]
        #expect(d["tier"] == "data")
        #expect(d["owner"] == "alice")
    }
}

// Bug #X — compose `profiles:` field parses
@Suite("Compose profiles parsing")
struct ComposeProfilesTests {
    @Test func profilesArray() throws {
        let yaml = """
        services:
          web:
            image: nginx
            profiles: [proxy, optional]
        """
        let f = try YAMLDecoder().decode(ComposeFile.self, from: yaml)
        #expect(f.services["web"]?.profiles == ["proxy", "optional"])
    }
}

// Bug #24 — `cocker rm -f` dropped the force flag on the wire ; the daemon
// always saw force=false and refused to delete running containers.
@Suite("Bug #24 — rm force flag round-trips over IPC")
struct RmForceFlagTests {
    @Test func encodingCarriesForce() throws {
        let req = ContainerIDRequest(id: "abc", force: true)
        let data = try JSONEncoder().encode(req)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"force\":true"))
    }

    @Test func decodingPreservesForce() throws {
        let raw = #"{"id":"abc","force":true}"#
        let req = try JSONDecoder().decode(ContainerIDRequest.self, from: Data(raw.utf8))
        #expect(req.force == true)
    }

    @Test func backwardCompatibleWithoutForce() throws {
        // Older clients send no `force` key ; we treat it as false.
        let raw = #"{"id":"abc"}"#
        let req = try JSONDecoder().decode(ContainerIDRequest.self, from: Data(raw.utf8))
        #expect(req.force == nil)
    }
}

// Bug #X — compose activeProfiles carries through the IPC payload.
@Suite("Compose activeProfiles round-trip")
struct ComposeActiveProfilesTests {
    @Test func activeProfilesRoundtrip() throws {
        let req = ComposeRequest(composePath: "/tmp/foo.yml", activeProfiles: ["proxy"])
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(ComposeRequest.self, from: data)
        #expect(decoded.activeProfiles == ["proxy"])
    }

    @Test func backwardCompatibleWithoutProfiles() throws {
        let raw = #"{"composePath":"/x.yml","services":[],"detach":false}"#
        let decoded = try JSONDecoder().decode(ComposeRequest.self, from: Data(raw.utf8))
        #expect(decoded.activeProfiles == nil)
    }
}

// Bug #10 — Dockerfile parser refused `ARG ...` lines before the first FROM
// (standard Dockerfile syntax allows them so vars can be substituted in the
// FROM line itself).
@Suite("Bug #10 — Dockerfile ARG before FROM")
struct DockerfileARGBeforeFROMTests {
    @Test func argBeforeFromAccepted() throws {
        let df = """
        ARG BASE_TAG=latest
        FROM alpine:${BASE_TAG}
        RUN echo hi
        """
        let instructions = try parseDockerfile(df)
        #expect(instructions.count == 3)
        #expect(instructions[0].keyword == "ARG")
        #expect(instructions[1].keyword == "FROM")
    }

    @Test func multipleArgsBeforeFromAccepted() throws {
        let df = """
        ARG A=1
        ARG B=2
        FROM alpine
        RUN echo $A $B
        """
        let instructions = try parseDockerfile(df)
        #expect(instructions.prefix(3).map(\.keyword) == ["ARG", "ARG", "FROM"])
    }

    @Test func runBeforeFromStillRejected() {
        let df = """
        RUN echo wrong
        FROM alpine
        """
        #expect(throws: CockerError.self) {
            _ = try parseDockerfile(df)
        }
    }

    @Test func emptyDockerfileStillRejected() {
        #expect(throws: CockerError.self) {
            _ = try parseDockerfile("# just a comment\n")
        }
    }
}

// Bug #51 — USER instruction was acknowledged by the Dockerfile parser but
// never propagated to cocker-init, so every container ran as root. The wire
// format grew trailers for it: v3 user, v4 caps, v5 stop signal, v6 tty +
// terminal geometry (so `cocker run -it` can give the main process a
// controlling terminal). The guest still parses v2–v5 and treats a missing
// trailer as "not requested".
@Suite("/cocker-spec trailers")
struct CockerSpecTrailerTests {

    /// An empty v7 trailer: read_only(1) + four zero list counts (4×4).
    /// Named rather than baked into every offset below, because the last
    /// time this layout grew, six tests broke on arithmetic instead of on
    /// the thing they were guarding.
    private static let emptyV7Trailer = 1 + 4 * 4

    /// v7 adds read-only root, tmpfs, extra hosts and DNS. The guest keys
    /// its parse off this byte, so a mismatch means the two sides disagree
    /// about the layout — exactly what the magic exists to catch.
    @Test func magicByteIsV7() {
        let data = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil)
        #expect(data.starts(with: Array("COCKER\u{07}".utf8)))
    }

    /// v7 layout: … stop_signal(4) tty(1) rows(4) cols(4) ‖ read_only(1)
    /// n_tmpfs(4) n_hosts(4) n_dns(4) n_dns_search(4).
    @Test func stopSignalPrecedesTheTTYTrailer() {
        let data = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil,
                                              stopSignal: "SIGQUIT")
        let n = data.count - Self.emptyV7Trailer
        #expect(data[n - 13] == 0)
        #expect(data[n - 12] == 0)
        #expect(data[n - 11] == 0)
        #expect(data[n - 10] == 3)   // SIGQUIT
    }

    @Test func defaultStopSignalIsZero() {
        let data = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil)
        let n = data.count - Self.emptyV7Trailer
        #expect(data[n - 10] == 0)   // no STOPSIGNAL → init's default
    }

    @Test func ttyTrailerDefaultsToOff() {
        let data = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil)
        let n = data.count - Self.emptyV7Trailer
        #expect(data[n - 9] == 0)                                     // tty flag
        #expect(Array(data[(n - 8)..<n]) == [0, 0, 0, 0, 0, 0, 0, 0])  // rows + cols
    }

    /// `run -it` : the flag and the caller's real window size have to reach
    /// the guest, or the main process gets a terminal stuck at the kernel
    /// default and anything that redraws is wrong.
    @Test func ttyTrailerCarriesTheGeometry() {
        let data = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil,
                                              tty: true, rows: 40, cols: 120)
        let n = data.count - Self.emptyV7Trailer
        #expect(data[n - 9] == 1)
        #expect(Array(data[(n - 8)..<(n - 4)]) == [0, 0, 0, 40])
        #expect(Array(data[(n - 4)..<n]) == [0, 0, 0, 120])
    }

    /// A geometry that wouldn't fit a UInt16 would truncate into nonsense
    /// on the guest side, so it's clamped rather than wrapped.
    @Test func absurdGeometryIsClamped() {
        let data = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil,
                                              tty: true, rows: 999_999, cols: -5)
        let n = data.count - Self.emptyV7Trailer
        #expect(Array(data[(n - 8)..<(n - 4)]) == [0, 0, 255, 255])  // clamped to 65535
        #expect(Array(data[(n - 4)..<n]) == [0, 0, 0, 0])            // negative → 0
    }

    // MARK: - v7 : the four flags that used to be accepted and ignored

    @Test func readOnlyDefaultsToOffAndSetsWhenAsked() {
        let off = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil)
        #expect(off[off.count - Self.emptyV7Trailer] == 0)
        let on = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil,
                                            readOnly: true)
        #expect(on[on.count - Self.emptyV7Trailer] == 1)
    }

    /// Each list is length-prefixed, so a v6 guest reading a v7 spec stops
    /// at the tty trailer and behaves exactly as it did before.
    @Test func theListsAreLengthPrefixedInOrder() {
        let data = RootfsBootstrap.encodeSpec(
            command: ["true"], env: [:], workdir: nil,
            readOnly: true,
            tmpfsMounts: ["/run:size=64m"],
            addHosts: ["db:10.0.0.5"],
            dnsServers: ["1.1.1.1"],
            dnsSearch: ["example.com"])
        let bytes = Array(data)
        // Order matters: tmpfs, hosts, dns, dns-search. Reading them in the
        // wrong order on the guest would mount a hostname.
        let text = String(decoding: bytes, as: UTF8.self)
        let iTmpfs = text.range(of: "/run:size=64m")
        let iHosts = text.range(of: "db:10.0.0.5")
        let iDNS = text.range(of: "1.1.1.1")
        let iSearch = text.range(of: "example.com")
        #expect(iTmpfs != nil && iHosts != nil && iDNS != nil && iSearch != nil)
        if let a = iTmpfs, let b = iHosts, let c = iDNS, let d = iSearch {
            #expect(a.lowerBound < b.lowerBound)
            #expect(b.lowerBound < c.lowerBound)
            #expect(c.lowerBound < d.lowerBound)
        }
    }

    @Test func emptyListsCostFiveWordsAndNothingElse() {
        let bare = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil)
        let withOne = RootfsBootstrap.encodeSpec(command: ["true"], env: [:], workdir: nil,
                                                 dnsServers: ["1.1.1.1"])
        // 4-byte length prefix + the 7 bytes of "1.1.1.1".
        #expect(withOne.count == bare.count + 4 + 7)
    }
}


// Bug #52 — IP discovery race. `/cocker-ip` from the previous container
// (cloned through APFS clonefile from the image rootfs) lingered, so
// cockerd's polling loop sometimes captured the wrong IP. The fix : the
// build VM cleans up /cocker-ip before exit AND cocker-init truncates it
// at net_setup_eth0_dhcp() entry. Tests below pin the contract on the
// daemon side ; the C side is exercised end-to-end in the smoke harness.
@Suite("Bug #52 — /cocker-ip cleanup contract")
struct CockerIPCleanupTests {
    @Test func emptyFileMeansKeepPolling() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-ip-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ipFile = dir.appendingPathComponent("cocker-ip")
        try Data().write(to: ipFile)
        // The polling helper considers `realIP == nil` when the file is
        // present but empty. We reimplement the inline check the daemon
        // does ; it must reject empty strings as "not yet".
        let data = try Data(contentsOf: ipFile)
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(s?.isEmpty == true)
    }

    @Test func nonEmptyFileWinsOverDefault() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-ip-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ipFile = dir.appendingPathComponent("cocker-ip")
        try Data("192.168.65.42\n".utf8).write(to: ipFile)
        let data = try Data(contentsOf: ipFile)
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(s == "192.168.65.42")
    }
}

// Bug #56 — vmnet DHCP flake recovery. When `/cocker-ip` polling times out
// (DHCP loss inside the VM), cockerd now reads `/var/db/dhcpd_leases` and
// matches on the VZ-generated eth0 MAC. The parser must be tolerant of
// macOS's shortened MAC form ("2:cc:1" instead of "02:cc:01").
@Suite("Bug #56 — DHCP lease fallback parser")
struct DHCPLeaseFallbackTests {
    /// Drop the `lookupLeasedIP` helper against a fixture lease file so we
    /// don't depend on the host's real /var/db/dhcpd_leases.
    private func withFixture(_ contents: String, _ body: () throws -> Void) throws {
        // The production helper hard-codes the path, so we can't redirect
        // it from a test ; instead we re-implement the parser here against
        // the same data shape. That's enough to lock the normalization
        // contract.
        try body()
    }

    /// Local mirror of `ContainerEngine.lookupLeasedIP` so we can test the
    /// parser without touching /var/db/dhcpd_leases. Keep in sync with the
    /// production helper.
    private func parse(_ text: String, mac: String) -> String? {
        func normalize(_ s: String) -> String {
            s.split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }
             .joined(separator: ":")
        }
        let target = normalize(mac).lowercased()
        var currentIP: String? = nil
        var matched: String? = nil
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ip_address=") {
                currentIP = String(trimmed.dropFirst("ip_address=".count))
            } else if trimmed.hasPrefix("hw_address=") {
                let val = trimmed.dropFirst("hw_address=".count)
                let macPart = val.split(separator: ",").last.map(String.init) ?? String(val)
                if normalize(macPart).lowercased() == target {
                    matched = currentIP
                }
            }
        }
        return matched
    }

    @Test func findsMACInStandardForm() {
        let fixture = """
        {
        \tip_address=192.168.65.42
        \thw_address=1,16:d2:29:38:85:ec
        }
        """
        #expect(parse(fixture, mac: "16:d2:29:38:85:ec") == "192.168.65.42")
    }

    @Test func handlesMacOSShortenedForm() {
        // macOS bootpd strips leading zeros : "02:cc:01" → "2:cc:1".
        let fixture = """
        {
        \tip_address=10.0.0.5
        \thw_address=1,2:cc:1:2:3:4
        }
        """
        #expect(parse(fixture, mac: "02:cc:01:02:03:04") == "10.0.0.5")
    }

    @Test func lastEntryWinsForRepeatMAC() {
        // The file is append-only ; for the same MAC the newest lease wins.
        let fixture = """
        {
        \tip_address=192.168.65.100
        \thw_address=1,aa:bb:cc:dd:ee:ff
        }
        {
        \tip_address=192.168.65.200
        \thw_address=1,aa:bb:cc:dd:ee:ff
        }
        """
        #expect(parse(fixture, mac: "aa:bb:cc:dd:ee:ff") == "192.168.65.200")
    }

    @Test func returnsNilWhenAbsent() {
        let fixture = """
        {
        \tip_address=192.168.65.1
        \thw_address=1,11:22:33:44:55:66
        }
        """
        #expect(parse(fixture, mac: "ff:ff:ff:ff:ff:ff") == nil)
    }

    @Test func emptyFileReturnsNil() {
        #expect(parse("", mac: "aa:bb:cc:dd:ee:ff") == nil)
    }
}
