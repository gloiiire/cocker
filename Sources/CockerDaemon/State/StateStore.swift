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

    init(rootDir: URL) throws {
        self.stateFile = rootDir.appendingPathComponent("state.json")
        try load()
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

    private func load() throws {
        guard FileManager.default.fileExists(atPath: stateFile.path),
              let data = try? Data(contentsOf: stateFile)
        else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode(State.self, from: data) else {
            // Corrupted / truncated state.json — preserve the broken file
            // for forensics and start fresh instead of silently wiping
            // every container the user had.
            let backup = stateFile.appendingPathExtension("corrupted.\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: stateFile, to: backup)
            fputs("[state] WARN : state.json failed to decode ; preserved as \(backup.path) and starting empty\n", stderr)
            return
        }
        // Refuse to load future versions — we don't know the new fields'
        // invariants and silently downgrading them could corrupt data.
        if loaded.schemaVersion > Self.currentSchemaVersion {
            fputs("[state] FATAL : state.json schemaVersion=\(loaded.schemaVersion) exceeds this cockerd's max (\(Self.currentSchemaVersion)). Upgrade cockerd or roll back the file.\n", stderr)
            exit(64)  // EX_USAGE — operator must intervene
        }
        state = loaded
        // Migrate older files in-memory. The next save() writes back at
        // currentSchemaVersion.
        if state.schemaVersion < Self.currentSchemaVersion {
            fputs("[state] migrating state.json from v\(state.schemaVersion) → v\(Self.currentSchemaVersion)\n", stderr)
            state.schemaVersion = Self.currentSchemaVersion
        }
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(state)
        try data.write(to: stateFile, options: .atomic)
        // state.json carries container labels + env vars + restart policy.
        // env can hold secrets (DB passwords, API tokens) — make the file
        // owner-only readable so other local users can't enumerate them.
        // 0o600 mirrors the credentials.json secrecy contract we already
        // enforce in CredentialStore.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: stateFile.path)
    }

    // MARK: - Containers

    func container(id: String) -> Container? {
        // Exact match
        if let c = state.containers[id] { return c }
        // Prefix match
        return state.containers.values.first { $0.id.hasPrefix(id) || $0.name == id }
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

    func updateContainer(id: String, update: (inout Container) -> Void) throws {
        guard var container = container(id: id) else { throw CockerError.containerNotFound(id) }
        update(&container)
        state.containers[container.id] = container
        try save()
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
        var name: String
        repeat {
            name = "\(adjectives.randomElement()!)_\(nouns.randomElement()!)"
        } while nameExists(name)
        return name
    }

    // MARK: - Networks

    func network(id: String) -> NetworkInfo? {
        if let n = state.networks[id] { return n }
        return state.networks.values.first { $0.name == id || $0.id.hasPrefix(id) }
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
        return state.volumes.values.first { $0.name == id || $0.id.hasPrefix(id) }
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
        let unused = state.volumes.values.filter { !usedVolumes.contains($0.name) && !usedVolumes.contains($0.mountpoint) }
        let names = unused.map { $0.name }
        for n in names { state.volumes.removeValue(forKey: n) }
        try save()
        return names
    }
}
