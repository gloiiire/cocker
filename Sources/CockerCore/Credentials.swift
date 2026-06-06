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
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(CredentialStore.self, from: data)
        else { return CredentialStore() }
        return store
    }

    public func save() throws {
        let dir = Self.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.storeURL, options: .atomic)
        // Restrict permissions to owner-only
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.storeURL.path)
    }

    public func get(for registry: String) -> Credential? {
        credentials[registry] ?? credentials[registry.components(separatedBy: "/").first ?? registry]
    }

    public init() {}
}
