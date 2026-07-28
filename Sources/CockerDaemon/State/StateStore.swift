import Foundation
import CockerCore

// Persistent state for containers, networks, volumes
// Stored in ~/.cocker/state.json

actor StateStore {
    /// Schema version persisted alongside the state payload. Bumping
    /// it is a hard contract : older cockerd binaries must refuse to
    /// load newer files (forward-compat is unsafe — they don't know
    /// the new fields' invariants), and newer cockerd binaries must
    /// migrate older files into the current shape during load. v1 is
    /// the legacy unversioned shape (pre-0.4.x, no `schemaVersion`
    /// key in JSON) ; v2 introduced after 0.4.1 to carry the new
    /// `stopSignal` field and any future Container additions
    /// behind an explicit migration story.
    static let currentSchemaVersion: Int = 2

    struct State: Codable {
        var schemaVersion: Int = StateStore.currentSchemaVersion
        var containers: [String: Container] = [:]
        var networks: [String: NetworkInfo] = [:]
        var volumes: [String: VolumeInfo] = [:]

        enum CodingKeys: String, CodingKey {
            case schemaVersion, containers, networks, volumes
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Older files (pre-0.4.2) didn't write schemaVersion — assume v1.
            self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            self.containers = try c.decodeIfPresent([String: Container].self, forKey: .containers) ?? [:]
            self.networks = try c.decodeIfPresent([String: NetworkInfo].self, forKey: .networks) ?? [:]
            self.volumes = try c.decodeIfPresent([String: VolumeInfo].self, forKey: .volumes) ?? [:]
        }
    }

    private let stateFile: URL
    private var state: State = State()

    /// Cached encoder/decoder. Recreating them per call cost a per-update
    /// allocation that shows up as multi-millisecond CPU spikes under
    /// healthcheck churn (one save per probe × N running containers). Both
    /// are configured once with the project's ISO-8601 date strategy.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(rootDir: URL) throws {
        self.stateFile = rootDir.appendingPathComponent("state.json")
        // Load synchronously inside the actor's init — Swift 6 forbids
        // calling actor-isolated methods (like `load()`) from a
        // nonisolated init, but a self-contained load function that
        // returns a new State and gets assigned right here is fine.
        self.state = try Self.readState(from: stateFile)
    }

    /// Pure read helper used by `init`. Doesn't touch actor state, so
    /// it can be called from the nonisolated init context that Swift 6
    /// strict concurrency enforces.
    private static func readState(from stateFile: URL) throws -> State {
        guard FileManager.default.fileExists(atPath: stateFile.path),
              let data = try? Data(contentsOf: stateFile)
        else { return State() }

        guard let loaded = try? Self.decoder.decode(State.self, from: data) else {
            let backup = stateFile.appendingPathExtension("corrupted.\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: stateFile, to: backup)
            CockerLog.shared.warn("state", "state.json failed to decode ; preserved as \(backup.path) and starting empty")
            return State()
        }
        if loaded.schemaVersion > Self.currentSchemaVersion {
            // Refuse to load a file written by a newer cockerd — but by
            // THROWING, not by exit()ing. A persistence layer must never
            // decide process death : main() catches this, prints the
            // actionable message and exits with EX_USAGE itself. Keeps
            // the store testable and embeddable.
            throw CockerError.stateSchemaTooNew(found: loaded.schemaVersion,
                                                supported: Self.currentSchemaVersion)
        }
        var migrated = loaded
        if migrated.schemaVersion < Self.currentSchemaVersion {
            CockerLog.shared.debug("state", "migrating state.json from v\(migrated.schemaVersion) → v\(Self.currentSchemaVersion)")
            migrated.schemaVersion = Self.currentSchemaVersion
        }
        return migrated
    }

    /// Reconcile persisted state with reality. cockerd loses its VM handles
    /// every time the daemon restarts (kill -9 from a launchd reload, a
    /// crash, sleep/wake, the user running `pkill cockerd`…). The container
    /// records left in state.json then claim to be "running" even though no
    /// VM exists. `cocker ps` shows phantom rows ; `cocker stop` fails with
    /// "container is not running" ; `cocker rm` can't free the name. This
    /// scrubs them at startup : every container marked .running or .paused
    /// becomes .stopped with an exit code of -1 and a finishedAt timestamp.
    /// Operators can `cocker rm` them or restart them normally.
    func reconcileAfterRestart() throws {
        var dirty = false
        let now = Date()
        for (id, container) in state.containers
            where container.status == .running || container.status == .paused {
            var c = container
            c.status = .stopped
            c.finishedAt = now
            if c.exitCode == nil { c.exitCode = -1 }
            // Healthcheck loop died with the previous daemon. Reset the
            // persisted failing-streak ; auto-restart (if policy says so)
            // will spawn a fresh loop and walk from "starting" through to
            // the next outcome. We preserve `healthStatus` itself to match
            // Docker, which freezes the last known status on a stopped
            // container — a container that was healthy before the daemon
            // bounce keeps reporting "healthy" until it actually runs and
            // probes again.
            c.healthFailingStreak = 0
            state.containers[id] = c
            dirty = true
        }
        if dirty { try save() }
    }

    // MARK: - Persistence

    /// How urgently a mutation must reach disk.
    ///
    /// `state.json` is a single file rewritten IN FULL on every save —
    /// classic write amplification. That's fine for rare lifecycle events
    /// (create/remove/start/stop) but the healthcheck loop mutates state
    /// 3-4× per probe per container ; with N probed containers that used
    /// to mean hundreds of full-file rewrites per minute, most of them
    /// carrying nothing an operator would miss after a crash.
    enum Durability {
        /// Flush before returning. For state a crash must not lose :
        /// container existence, status transitions, names, networks…
        case immediate
        /// Mark dirty and let the debounce task flush within
        /// `coalesceWindowNanos`. For high-frequency low-value churn
        /// (healthLog ring buffer, failing-streak counters). Worst case
        /// a crash loses <1 s of probe history — which
        /// `reconcileAfterRestart` resets anyway.
        case coalesced
    }

    /// Debounce window for `.coalesced` saves. 500 ms folds a healthcheck
    /// burst (log append + streak + status for several containers landing
    /// together) into one disk write without letting the on-disk view go
    /// meaningfully stale.
    private static let coalesceWindowNanos: UInt64 = 500_000_000
    private var flushTask: Task<Void, Never>?

    /// Coalesced-save scheduler : first `.coalesced` mutation arms a
    /// single timer ; every further mutation inside the window rides
    /// along for free. The actor guarantees `flushTask` accesses are
    /// serialized.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(nanoseconds: Self.coalesceWindowNanos)
            guard !Task.isCancelled else { return }
            self.flushTask = nil
            try? self.save()
        }
    }

    /// Force any pending coalesced write to disk NOW. Called on daemon
    /// shutdown so the last probe results aren't lost, and available to
    /// tests that need deterministic on-disk state.
    func flushPending() {
        guard let task = flushTask else { return }
        task.cancel()
        flushTask = nil
        try? save()
    }

    func save() throws {
        let data = try Self.encoder.encode(state)
        // Atomic write goes through a temp file — chmod the temp before the
        // rename so the window during which a passer-by could open the new
        // file at 0o644 is zero (Foundation's `.atomic` does
        // open(tmp)/write/close(tmp)/rename(tmp,dst)). state.json carries
        // container labels + env vars + restart policy ; env can hold
        // secrets (DB passwords, API tokens) so the contract is owner-only.
        let tmp = stateFile.appendingPathExtension("tmp.\(getpid()).\(UInt32.random(in: 0..<UInt32.max))")
        try data.write(to: tmp)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: tmp.path)
        do {
            // Replace existing atomically. macOS rename(2) is atomic between
            // paths on the same volume — both tmp and stateFile live in
            // ~/.cocker/ so we're safe.
            _ = try FileManager.default.replaceItemAt(stateFile, withItemAt: tmp)
        } catch {
            // Fallback : straight move. The temp still has 0o600 perms.
            try? FileManager.default.removeItem(at: stateFile)
            try FileManager.default.moveItem(at: tmp, to: stateFile)
        }
        // Belt + suspenders : re-assert perms on the final path. Some
        // FileManager.replaceItemAt implementations copy perms from the
        // destination, which can be wider than we want.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: stateFile.path)
    }

    // MARK: - Containers

    func container(id: String) -> Container? {
        // Exact id match wins immediately.
        if let c = state.containers[id] { return c }
        // Then full-name match (always valid regardless of length).
        if let byName = state.containers.values.first(where: { $0.name == id }) {
            return byName
        }
        // Prefix-id match only when the supplied prefix is unambiguous. Docker
        // uses 12 chars as the minimum short id ; we mirror that to dodge the
        // class of bug fixed in `volume(id:)` — a lookup like "a"/"b" would
        // otherwise match any container whose UUID happens to start with that
        // letter and pick one non-deterministically.
        guard id.count >= 12 else { return nil }
        return state.containers.values.first { $0.id.hasPrefix(id) }
    }

    func allContainers(includeAll: Bool = false) -> [Container] {
        let all = Array(state.containers.values)
        if includeAll { return all.sorted { $0.createdAt > $1.createdAt } }
        return all.filter { $0.status == .running }.sorted { $0.createdAt > $1.createdAt }
    }

    func store(container: Container) throws {
        state.containers[container.id] = container
        try save()
    }

    func updateContainer(id: String,
                         durability: Durability = .immediate,
                         update: (inout Container) -> Void) throws {
        guard var container = container(id: id) else { throw CockerError.containerNotFound(id) }
        update(&container)
        state.containers[container.id] = container
        switch durability {
        case .immediate: try save()
        case .coalesced: scheduleFlush()
        }
    }

    func removeContainer(id: String) throws {
        guard let c = container(id: id) else { throw CockerError.containerNotFound(id) }
        state.containers.removeValue(forKey: c.id)
        try save()
    }

    func nameExists(_ name: String) -> Bool {
        state.containers.values.contains { $0.name == name }
    }

    func generateName() -> String {
        let adjectives = ["happy", "sad", "brave", "bold", "calm", "cool", "fast", "keen", "wild", "wise"]
        let nouns = ["newton", "turing", "ritchie", "woz", "knuth", "hopper", "lovelace", "babbage", "von_neumann"]
        // 10 × 9 = 90 base combinations. Past that, blindly retrying would
        // spin the actor forever and lock the entire state store ; the prior
        // `repeat { ... } while nameExists` was a trivial DoS for anyone
        // running >90 containers. We try a bounded number of fresh draws,
        // then escalate to "<adjective>_<noun>_<counter>" with a probing loop
        // that's guaranteed to terminate.
        for _ in 0..<32 {
            let base = "\(adjectives.randomElement()!)_\(nouns.randomElement()!)"
            if !nameExists(base) { return base }
        }
        let base = "\(adjectives.randomElement()!)_\(nouns.randomElement()!)"
        var counter = 2
        while nameExists("\(base)_\(counter)") { counter += 1 }
        return "\(base)_\(counter)"
    }

    // MARK: - Networks

    func network(id: String) -> NetworkInfo? {
        if let n = state.networks[id] { return n }
        if let byName = state.networks.values.first(where: { $0.name == id }) {
            return byName
        }
        // 12-char minimum on prefix-id match : same rationale as
        // `container(id:)` and `volume(id:)` above — a 1-char query would
        // otherwise match any UUID starting with that hex digit (~6 % chance
        // per existing network) and pick one arbitrarily.
        guard id.count >= 12 else { return nil }
        return state.networks.values.first { $0.id.hasPrefix(id) }
    }

    func allNetworks() -> [NetworkInfo] {
        Array(state.networks.values).sorted { $0.name < $1.name }
    }

    func store(network: NetworkInfo) throws {
        state.networks[network.id] = network
        try save()
    }

    func removeNetwork(id: String) throws {
        guard let n = network(id: id) else { throw CockerError.networkNotFound(id) }
        state.networks.removeValue(forKey: n.id)
        try save()
    }

    // MARK: - Volumes

    func volume(id: String) -> VolumeInfo? {
        if let v = state.volumes[id] { return v }
        // Prefix match falls back to the Docker convention : a 12-char
        // short ID is the minimum that's safe to disambiguate. Without
        // this minimum, a 1-char lookup like "c" would match any volume
        // whose UUID happens to start with "c" (~6 % per existing
        // volume) and short-named volumes would silently collide. The
        // VolumeManagerPruneTests suite hit this intermittently with
        // names "a"/"b"/"c" — 12 % failure rate in CI.
        return state.volumes.values.first {
            $0.name == id || (id.count >= 12 && $0.id.hasPrefix(id))
        }
    }

    func allVolumes() -> [VolumeInfo] {
        Array(state.volumes.values).sorted { $0.name < $1.name }
    }

    func store(volume: VolumeInfo) throws {
        state.volumes[volume.id] = volume
        try save()
    }

    func removeVolume(id: String) throws {
        guard let v = volume(id: id) else { throw CockerError.volumeNotFound(id) }
        state.volumes.removeValue(forKey: v.id)
        try save()
    }

    // MARK: - Prune

    func pruneStopped() throws -> [String] {
        let stopped = state.containers.values.filter { $0.status == .stopped || $0.status == .dead }
        let ids = stopped.map { $0.id }
        for id in ids { state.containers.removeValue(forKey: id) }
        try save()
        return ids
    }

    func pruneUnusedVolumes() throws -> [String] {
        let usedVolumes = Set(state.containers.values.flatMap { $0.volumes.map { $0.source } })
        let unused = state.volumes.values.filter {
            !usedVolumes.contains($0.name) && !usedVolumes.contains($0.mountpoint)
        }
        let names = unused.map { $0.name }
        // The dict is keyed by `volume.id` (see `store(volume:)`), NOT by
        // name : the prior `removeValue(forKey: n)` silently did nothing
        // whenever id != name (i.e. for every non-trivial volume) and the
        // returned `names` list lied about what got removed.
        for v in unused { state.volumes.removeValue(forKey: v.id) }
        try save()
        return names
    }
}
