import Foundation
import Testing
import CockerCore
@testable import CockerDaemon

/// `?filters=` was ignored by every list endpoint. That is destructive, not
/// merely incomplete: `docker compose` knows which containers it owns only by
/// `label=com.docker.compose.project=<name>`, so it received every container
/// on the host and treated the rest as orphans — `compose down` in one
/// project could remove another's.
@Suite("Docker API filters")
struct DockerFiltersTests {

    private func container(
        id: String = "abc123def456",
        name: String = "web",
        image: String = "nginx:latest",
        status: ContainerStatus = .running,
        labels: [String: String] = [:],
        exitCode: Int32? = nil
    ) -> Container {
        var c = Container(id: id, name: name, image: image, command: [],
                          status: status, labels: labels)
        c.exitCode = exitCode
        return c
    }

    private func filters(_ json: String) throws -> DockerFilters {
        try DockerFilters.parse(json)
    }

    // MARK: - Parsing

    @Test func absentFilterMatchesEverything() throws {
        #expect(try filters("").isEmpty)
        #expect(try DockerFilters.parse(nil).isEmpty)
    }

    @Test func parsesTheArrayEncoding() throws {
        let f = try filters(#"{"label":["a=1","b=2"]}"#)
        #expect(f.values("label") == ["a=1", "b=2"])
    }

    /// Older clients send `{"dangling":{"true":true}}` for the same thing.
    @Test func parsesTheLegacySetEncoding() throws {
        let f = try filters(#"{"dangling":{"true":true}}"#)
        #expect(f.danglingWanted() == true)
    }

    @Test func parsesPercentEncodedPayloads() throws {
        let raw = #"{"label":["com.docker.compose.project=web"]}"#
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(try filters(encoded).values("label") == ["com.docker.compose.project=web"])
    }

    /// Malformed input must not degrade into "no filter" — answering with the
    /// full list to a client that asked to narrow it is the bug being fixed.
    @Test func malformedPayloadIsRejected() {
        #expect(throws: DockerFilters.FilterError.self) { try filters("not json") }
        #expect(throws: DockerFilters.FilterError.self) { try filters(#"{"label":5}"#) }
    }

    /// An unimplemented key is refused rather than ignored, for the same
    /// reason: a silently unnarrowed list can be acted on destructively.
    @Test func unsupportedKeysAreRejected() throws {
        let f = try filters(#"{"before":["x"]}"#)
        #expect(throws: DockerFilters.FilterError.self) {
            try f.requireSupported(DockerFilters.containerKeys)
        }
        // ...and a supported one passes.
        let ok = try filters(#"{"label":["x"]}"#)
        #expect(throws: Never.self) { try ok.requireSupported(DockerFilters.containerKeys) }
    }

    // MARK: - The compose scenario

    @Test func labelFilterIsolatesOneComposeProject() throws {
        let mine = container(name: "web-1", labels: ["com.docker.compose.project": "shop"])
        let theirs = container(name: "api-1", labels: ["com.docker.compose.project": "blog"])
        let unlabelled = container(name: "stray")

        let f = try filters(#"{"label":["com.docker.compose.project=shop"]}"#)
        #expect(f.matches(container: mine))
        #expect(!f.matches(container: theirs))
        #expect(!f.matches(container: unlabelled))
    }

    /// Multiple labels are AND'd — this is what makes
    /// `--filter label=a --filter label=b` mean "both".
    @Test func multipleLabelsMustAllMatch() throws {
        let both = container(labels: ["a": "1", "b": "2"])
        let one = container(labels: ["a": "1"])
        let f = try filters(#"{"label":["a=1","b=2"]}"#)
        #expect(f.matches(container: both))
        #expect(!f.matches(container: one))
    }

    @Test func bareLabelKeyMatchesOnPresence() throws {
        let f = try filters(#"{"label":["traefik.enable"]}"#)
        #expect(f.matches(container: container(labels: ["traefik.enable": "false"])))
        #expect(!f.matches(container: container(labels: ["other": "x"])))
    }

    // MARK: - Container predicates

    @Test func idMatchesOnPrefix() throws {
        let f = try filters(#"{"id":["abc123"]}"#)
        #expect(f.matches(container: container(id: "abc123def456")))
        #expect(!f.matches(container: container(id: "zzz999")))
    }

    @Test func nameMatchesOnSubstring() throws {
        let f = try filters(#"{"name":["web"]}"#)
        #expect(f.matches(container: container(name: "shop-web-1")))
        #expect(!f.matches(container: container(name: "shop-api-1")))
    }

    /// Docker says `exited`; cocker's state machine says `stopped`. Filtering
    /// on the raw enum would make `--filter status=exited` return nothing.
    @Test func statusUsesDockerVocabulary() throws {
        #expect(DockerFilters.dockerStatusName(.stopped) == "exited")
        let f = try filters(#"{"status":["exited"]}"#)
        #expect(f.matches(container: container(status: .stopped)))
        #expect(!f.matches(container: container(status: .running)))
    }

    @Test func exitedFilterNarrowsByCode() throws {
        let f = try filters(#"{"exited":["1"]}"#)
        #expect(f.matches(container: container(status: .stopped, exitCode: 1)))
        #expect(!f.matches(container: container(status: .stopped, exitCode: 0)))
        #expect(!f.matches(container: container(status: .running)))
    }

    @Test func ancestorMatchesTheSourceImage() throws {
        let f = try filters(#"{"ancestor":["nginx"]}"#)
        #expect(f.matches(container: container(image: "nginx:latest")))
        #expect(!f.matches(container: container(image: "redis:7")))
    }

    // MARK: - Image reference patterns

    @Test func bareRepoMatchesEveryTag() {
        #expect(DockerFilters.matchesReferencePattern("nginx:latest", pattern: "nginx"))
        #expect(DockerFilters.matchesReferencePattern("nginx:1.25", pattern: "nginx"))
        #expect(!DockerFilters.matchesReferencePattern("nginxinc/nginx:1", pattern: "nginx"))
    }

    @Test func taggedReferenceIsExact() {
        #expect(DockerFilters.matchesReferencePattern("nginx:1.25", pattern: "nginx:1.25"))
        #expect(!DockerFilters.matchesReferencePattern("nginx:latest", pattern: "nginx:1.25"))
    }

    @Test func wildcardsAreHonoured() {
        #expect(DockerFilters.matchesReferencePattern("nginx:1.25", pattern: "ngin*"))
        #expect(DockerFilters.matchesReferencePattern("ghcr.io/me/app:v1", pattern: "ghcr.io/*"))
        #expect(!DockerFilters.matchesReferencePattern("redis:7", pattern: "ngin*"))
    }

    @Test func danglingSelectsUntaggedImages() throws {
        let tagged = ImageInfo(id: "sha256:a", repository: "nginx", tag: "latest")
        let untagged = ImageInfo(id: "sha256:b", repository: "<none>", tag: "<none>")

        let wantDangling = try filters(#"{"dangling":["true"]}"#)
        #expect(wantDangling.matches(image: untagged))
        #expect(!wantDangling.matches(image: tagged))

        let wantTagged = try filters(#"{"dangling":["false"]}"#)
        #expect(wantTagged.matches(image: tagged))
        #expect(!wantTagged.matches(image: untagged))
    }

    // MARK: - Volumes and networks

    @Test func volumeFiltersOnNameDriverAndLabel() throws {
        let vol = VolumeInfo(name: "shop_pgdata", mountpoint: "/tmp/x", driver: "local",
                             labels: ["com.docker.compose.project": "shop"])

        #expect(try filters(#"{"name":["pgdata"]}"#).matches(volume: vol))
        #expect(try !filters(#"{"name":["redis"]}"#).matches(volume: vol))
        #expect(try filters(#"{"driver":["local"]}"#).matches(volume: vol))
        #expect(try !filters(#"{"driver":["nfs"]}"#).matches(volume: vol))
        #expect(try filters(#"{"label":["com.docker.compose.project=shop"]}"#).matches(volume: vol))
    }

    @Test func networkFiltersOnNameAndDriver() throws {
        let net = NetworkInfo(name: "shop_default", driver: .bridge)
        #expect(try filters(#"{"name":["shop"]}"#).matches(network: net))
        #expect(try !filters(#"{"name":["blog"]}"#).matches(network: net))
        #expect(try filters(#"{"driver":["bridge"]}"#).matches(network: net))
    }

    /// `network create --label` reached the daemon and was dropped, so no
    /// label filter could ever match. NetworkInfo carries them now.
    @Test func networkFiltersOnLabel() throws {
        let labelled = NetworkInfo(name: "shop_default", driver: .bridge,
                                   labels: ["com.docker.compose.project": "shop"])
        let bare = NetworkInfo(name: "blog_default", driver: .bridge)

        let f = try filters(#"{"label":["com.docker.compose.project=shop"]}"#)
        #expect(f.matches(network: labelled))
        #expect(!f.matches(network: bare))
        #expect(try filters(#"{"label":["x=1"]}"#).matches(network: bare) == false)
    }

    /// Networks written by an older daemon have no labels key at all; they
    /// must decode rather than taking the whole state file down.
    @Test func networkWithoutLabelsStillDecodes() throws {
        let legacy = #"{"id":"abc","name":"bridge","driver":"bridge","subnet":"172.20.0.0/16","gateway":"172.20.0.1","subnet6":"fd00::/48","gateway6":"fd00::1","containers":[],"createdAt":0}"#
        let net = try JSONDecoder().decode(NetworkInfo.self, from: Data(legacy.utf8))
        #expect(net.labelMap.isEmpty)
    }
}
