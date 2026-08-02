import Foundation
import Testing
import CockerCore
@testable import CockerDaemon

/// A batch of flags that parsed cleanly, appeared in `--help`, and then did
/// nothing. A silently ignored flag is worse than a missing one: the user
/// gets no signal at all that what they asked for didn't happen.
///
/// These pin the wire contract — that the value actually leaves the CLI and
/// survives the daemon's decode. The behaviour each one drives is covered by
/// its own subsystem's tests.
@Suite("Previously-ignored flags reach the daemon")
struct IgnoredFlagsTests {

    private func roundTrip<T: Codable>(_ payload: T, as type: T.Type,
                                       through kind: IPCRequestType) throws -> T {
        let request = try IPCRequest(type: kind, payload: payload)
        return try JSONDecoder().decode(type, from: request.payload)
    }

    // MARK: - stop -t / restart -t

    @Test func stopCarriesItsGracePeriod() throws {
        let decoded = try roundTrip(ContainerIDRequest(id: "web", timeout: 30),
                                    as: ContainerIDRequest.self, through: .stop)
        #expect(decoded.timeout == 30)
    }

    /// An older CLI omits the field entirely; the daemon must fall back to
    /// its 10 s default rather than failing to decode.
    @Test func absentTimeoutDecodesAsNil() throws {
        let legacy = #"{"id":"web"}"#
        let decoded = try JSONDecoder().decode(ContainerIDRequest.self, from: Data(legacy.utf8))
        #expect(decoded.timeout == nil)
        #expect(decoded.removeVolumes == nil)
        #expect(decoded.force == nil)
    }

    // MARK: - rm -v

    @Test func removeCarriesTheVolumesFlag() throws {
        let decoded = try roundTrip(ContainerIDRequest(id: "web", force: true, removeVolumes: true),
                                    as: ContainerIDRequest.self, through: .rm)
        #expect(decoded.removeVolumes == true)
        #expect(decoded.force == true)
    }

    /// `rm -v` must only ever reclaim volumes cocker invented. A named
    /// volume outliving its container is the whole point of naming it.
    @Test func onlyAutoCreatedVolumesAreAnonymous() {
        #expect(VolumeInfo(name: "pgdata").isAnonymous == false)
        #expect(VolumeInfo(name: "proj_web_anon_app_node_modules", anonymous: true).isAnonymous)
    }

    /// Volumes written by an older daemon carry no `anonymous` key; they must
    /// decode as named rather than becoming eligible for deletion.
    @Test func legacyVolumesAreTreatedAsNamed() throws {
        let legacy = #"{"id":"abc","name":"pgdata","mountpoint":"/x","driver":"local","labels":{},"createdAt":0}"#
        let vol = try JSONDecoder().decode(VolumeInfo.self, from: Data(legacy.utf8))
        #expect(vol.isAnonymous == false)
    }

    // MARK: - compose run / up

    @Test func composeRunCarriesTheCommandOverride() throws {
        let decoded = try roundTrip(
            ComposeRequest(composePath: "/x/compose.yml", services: ["web"],
                           command: ["npm", "run", "test"], removeAfterRun: true),
            as: ComposeRequest.self, through: .composeRun)
        #expect(decoded.command == ["npm", "run", "test"])
        #expect(decoded.removeAfterRun == true)
    }

    /// No override means "use the compose file's command" — distinct from an
    /// empty argv, which would blank it.
    @Test func absentCommandStaysNil() throws {
        let decoded = try roundTrip(ComposeRequest(composePath: "/x/compose.yml"),
                                    as: ComposeRequest.self, through: .composeRun)
        #expect(decoded.command == nil)
        #expect(decoded.removeAfterRun == false)
        #expect(decoded.removeOrphans == false)
    }

    @Test func composeUpCarriesRemoveOrphans() throws {
        let decoded = try roundTrip(
            ComposeRequest(composePath: "/x/compose.yml", removeOrphans: true),
            as: ComposeRequest.self, through: .composeUp)
        #expect(decoded.removeOrphans == true)
    }

    @Test func legacyComposeRequestStillDecodes() throws {
        let legacy = #"{"composePath":"/x/compose.yml","services":[],"detach":false,"removeVolumes":false,"follow":false,"tail":50,"forceBuild":false,"noCache":false}"#
        let decoded = try JSONDecoder().decode(ComposeRequest.self, from: Data(legacy.utf8))
        #expect(decoded.command == nil)
        #expect(decoded.removeAfterRun == false)
        #expect(decoded.removeOrphans == false)
    }

    // MARK: - network create --label

    @Test func networkCreateCarriesLabels() throws {
        let decoded = try roundTrip(
            NetworkCreateRequest(name: "mesh", labels: ["team": "infra"]),
            as: NetworkCreateRequest.self, through: .networkCreate)
        #expect(decoded.labels == ["team": "infra"])
    }

    @Test func networkStoresTheLabelsItWasGiven() {
        let net = NetworkInfo(name: "mesh", labels: ["team": "infra"])
        #expect(net.labelMap == ["team": "infra"])
        #expect(NetworkInfo(name: "bare").labelMap.isEmpty)
    }
}
