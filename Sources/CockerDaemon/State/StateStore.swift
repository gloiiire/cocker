import Foundation
import CockerCore

// Persistent state for containers, networks, volumes
// Stored in ~/.cocker/state.json

actor StateStore {
    struct State: Codable {
        var containers: [String: Container] = [:]
        var networks: [String: NetworkInfo] = [:]
        var volumes: [String: VolumeInfo] = [:]
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
        state = (try? decoder.decode(State.self, from: data)) ?? State()
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(state)
        try data.write(to: stateFile, options: .atomic)
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
