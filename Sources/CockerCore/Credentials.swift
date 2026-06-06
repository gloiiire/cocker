import Foundation

public struct CredentialStore: Codable, Sendable {
    public var credentials: [String: Credential] = [:]

    public struct Credential: Codable, Sendable {
        public let username: String
        public let password: String
        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    private static var storeURL: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/.cocker/credentials.json")
    }

    public static func load() -> CredentialStore {
        load(from: storeURL)
    }

    /// Load a store from an arbitrary URL. Returns an empty store if the file
    /// doesn't exist or fails to decode (no error surfaced — credentials are
    /// optional, missing file is normal on first run).
    public static func load(from url: URL) -> CredentialStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(CredentialStore.self, from: data)
        else { return CredentialStore() }
        return store
    }

    public func save() throws {
        try save(to: Self.storeURL)
    }

    /// Atomic write with 0o600 perms (owner read/write only). Creates parent
    /// dir if needed. Same secrecy contract as ~/.docker/config.json.
    public func save(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func get(for registry: String) -> Credential? {
        credentials[registry] ?? credentials[registry.components(separatedBy: "/").first ?? registry]
    }

    public init() {}
}
