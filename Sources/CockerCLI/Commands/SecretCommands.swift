import ArgumentParser
import CockerCore
import Foundation

// MARK: - Secret (host-side store)

/// `cocker secret` — manages opaque, sensitive blobs cocker stores at
/// `~/.cocker/secrets/<name>` with 0600 perms. Mount-into-container
/// integration (`cocker run --secret`) requires a virtiofs share rewire
/// per container — wired separately. The CRUD primitives here are
/// Docker-compatible enough for compose files that declare a `secrets:`
/// block to load without erroring.

struct SecretCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Manage cocker secrets",
        subcommands: [
            SecretCreateCommand.self,
            SecretLsCommand.self,
            SecretRmCommand.self,
            SecretInspectCommand.self,
        ]
    )
}

private func secretsDir() -> URL {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cocker/secrets")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    return url
}

struct SecretCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a secret from a file or STDIN")

    @Argument(help: "Secret name")
    var name: String

    @Argument(help: "Source file (- for STDIN)")
    var file: String

    mutating func run() async throws {
        let data: Data
        if file == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: file))
        }
        let path = secretsDir().appendingPathComponent(name)
        try data.write(to: path)
        // 0600 — host root + this user only. Secrets should never be world-readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        print(name)
    }
}

struct SecretLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List secrets")

    mutating func run() async throws {
        let dir = secretsDir()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        print("ID                          NAME             CREATED              SIZE")
        for name in files.sorted() {
            let path = dir.appendingPathComponent(name)
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            let created = (attrs[.creationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "-"
            let size = (attrs[.size] as? Int).map { "\($0)" } ?? "-"
            let id = String(name.hash.magnitude, radix: 16).padding(toLength: 25, withPad: "0", startingAt: 0)
            print("\(id)  \(name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(created.padding(toLength: 20, withPad: " ", startingAt: 0)) \(size)")
        }
    }
}

struct SecretRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more secrets")

    @Argument(help: "Secret name(s)")
    var names: [String]

    mutating func run() async throws {
        for name in names {
            let path = secretsDir().appendingPathComponent(name)
            try FileManager.default.removeItem(at: path)
            print(name)
        }
    }
}

struct SecretInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more secrets")

    @Argument(help: "Secret name")
    var names: [String]

    mutating func run() async throws {
        let dir = secretsDir()
        var entries: [[String: Any]] = []
        for name in names {
            let path = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else {
                fputs("Error: secret not found: \(name)\n", stderr); continue
            }
            entries.append([
                "Name": name,
                "CreatedAt": (attrs[.creationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "Size": (attrs[.size] as? Int) ?? 0,
                "Path": path.path,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: entries, options: .prettyPrinted)
        print(String(data: data, encoding: .utf8) ?? "[]")
    }
}

// MARK: - Config

/// `cocker config` — same shape as `secret` but stores at
/// `~/.cocker/configs/<name>` with 0644 perms (non-sensitive). Compose
/// `configs:` blocks load without erroring.

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage cocker configs",
        subcommands: [
            ConfigCreateCommand.self,
            ConfigLsCommand.self,
            ConfigRmCommand.self,
            ConfigInspectCommand.self,
        ]
    )
}

private func configsDir() -> URL {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cocker/configs")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct ConfigCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a config from a file or STDIN")

    @Argument(help: "Config name")
    var name: String

    @Argument(help: "Source file (- for STDIN)")
    var file: String

    mutating func run() async throws {
        let data: Data
        if file == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: file))
        }
        let path = configsDir().appendingPathComponent(name)
        try data.write(to: path)
        print(name)
    }
}

struct ConfigLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List configs")

    mutating func run() async throws {
        let dir = configsDir()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        print("ID                          NAME             CREATED              SIZE")
        for name in files.sorted() {
            let path = dir.appendingPathComponent(name)
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            let created = (attrs[.creationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "-"
            let size = (attrs[.size] as? Int).map { "\($0)" } ?? "-"
            let id = String(name.hash.magnitude, radix: 16).padding(toLength: 25, withPad: "0", startingAt: 0)
            print("\(id)  \(name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(created.padding(toLength: 20, withPad: " ", startingAt: 0)) \(size)")
        }
    }
}

struct ConfigRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more configs")

    @Argument(help: "Config name(s)")
    var names: [String]

    mutating func run() async throws {
        for name in names {
            let path = configsDir().appendingPathComponent(name)
            try FileManager.default.removeItem(at: path)
            print(name)
        }
    }
}

struct ConfigInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more configs")

    @Argument(help: "Config name")
    var names: [String]

    mutating func run() async throws {
        let dir = configsDir()
        var entries: [[String: Any]] = []
        for name in names {
            let path = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else {
                fputs("Error: config not found: \(name)\n", stderr); continue
            }
            entries.append([
                "Name": name,
                "CreatedAt": (attrs[.creationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "Size": (attrs[.size] as? Int) ?? 0,
                "Path": path.path,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: entries, options: .prettyPrinted)
        print(String(data: data, encoding: .utf8) ?? "[]")
    }
}
