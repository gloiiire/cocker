import Foundation

public struct CockerContext: Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var description: String
    public var dockerHost: String  // "unix:///path/to/docker.sock" ou "tcp://host:port"
    public var isDefault: Bool
    public var createdAt: Date

    public init(name: String, description: String = "", dockerHost: String) {
        self.id = UUID().uuidString
        self.name = name
        self.description = description
        self.dockerHost = dockerHost
        self.isDefault = false
        self.createdAt = Date()
    }

    public var socketPath: String? {
        if dockerHost.hasPrefix("unix://") {
            let path = String(dockerHost.dropFirst(7))
            return path.hasPrefix("~") ? path.replacingOccurrences(of: "~", with: NSHomeDirectory()) : path
        }
        return nil
    }
}

public struct ContextStore: Codable, Sendable {
    public var contexts: [CockerContext] = []
    public var current: String = "default"  // nom du contexte actif

    private static var storeURL: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/.cocker/contexts.json")
    }

    public static func load() -> ContextStore {
        var store: ContextStore
        if let data = try? Data(contentsOf: storeURL),
           let loaded = try? JSONDecoder().decode(ContextStore.self, from: data) {
            store = loaded
        } else {
            store = ContextStore()
        }
        // S'assurer que le contexte default existe toujours
        if !store.contexts.contains(where: { $0.name == "default" }) {
            var def = CockerContext(
                name: "default",
                description: "Current COCKER_HOST",
                dockerHost: "unix://\(NSHomeDirectory())/.cocker/cocker.sock"
            )
            def.isDefault = true
            store.contexts.insert(def, at: 0)
        }
        return store
    }

    public func save() throws {
        let dir = URL(fileURLWithPath: "\(NSHomeDirectory())/.cocker")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.storeURL, options: .atomic)
    }

    public var currentContext: CockerContext? {
        contexts.first { $0.name == current }
    }

    public var currentSocketPath: String {
        currentContext?.socketPath ?? "\(NSHomeDirectory())/.cocker/cocker.sock"
    }
}
