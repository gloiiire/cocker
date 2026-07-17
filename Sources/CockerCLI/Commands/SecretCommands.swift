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
        do {
            try ResourceName.validate(name, kind: "secret")
            if file == "-" {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                data = try Data(contentsOf: URL(fileURLWithPath: file))
            }
            let path = secretsDir().appendingPathComponent(name)
            try data.write(to: path)
            // 0600 — host root + this user only. Secrets should never be world-readable.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            UX.printCreated(.secret, name)
        } catch {
            UX.Failure.emit(
                headline: "Cannot create secret \(name)",
                reason: error.localizedDescription,
                hint: "verify the source file exists and is readable"
            )
            throw ExitCode.failure
        }
    }
}

struct SecretLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List secrets")

    mutating func run() async throws {
        let dir = secretsDir()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let rows: [UX.Table.Row] = files.sorted().compactMap { name in
            let path = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else { return nil }
            let created = (attrs[.creationDate] as? Date).map(relativeTime(from:)) ?? "-"
            let size = (attrs[.size] as? Int).map { UX.formatBytes(Int64($0)) } ?? "-"
            let id = String(name.hash.magnitude, radix: 16).prefix(12).padding(toLength: 12, withPad: "0", startingAt: 0)
            return .init([
                .init(String(id), color: .accent),
                .init(name),
                .init(created, color: .dim),
                .init(size, color: .dim),
            ])
        }
        let table = UX.Table(
            columns: [
                .init("ID"),
                .init("NAME"),
                .init("CREATED"),
                .init("SIZE", align: .right),
            ],
            rows: rows,
            emptyMessage: "no secrets — run `cocker secret create <name> <file>` to add one"
        )
        print(table.render())
    }
}

struct SecretRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more secrets")

    @Argument(help: "Secret name(s)")
    var names: [String]

    mutating func run() async throws {
        var failed = false
        for name in names {
            let path = secretsDir().appendingPathComponent(name)
            do {
                try ResourceName.validate(name, kind: "secret")
                try FileManager.default.removeItem(at: path)
                UX.printResult(.secret, name, verb: .remove)
            } catch {
                failed = true
                UX.Failure.emit(
                    headline: "Cannot remove secret \(name)",
                    reason: error.localizedDescription,
                    hint: "check `cocker secret ls` to see what's stored"
                )
            }
        }
        if failed { throw ExitCode.failure }
    }
}

struct SecretInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more secrets")

    @Argument(help: "Secret name")
    var names: [String]

    mutating func run() async throws {
        let dir = secretsDir()
        var entries: [[String: Any]] = []
        var failed = false
        for name in names {
            do {
                try ResourceName.validate(name, kind: "secret")
            } catch {
                failed = true
                UX.Failure.emit(
                    headline: "Cannot inspect secret \(name)",
                    reason: error.localizedDescription,
                    hint: "list available secrets with `cocker secret ls`"
                )
                continue
            }
            let path = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else {
                failed = true
                UX.Failure.emit(
                    headline: "Cannot inspect secret \(name)",
                    reason: "secret not found",
                    hint: "list available secrets with `cocker secret ls`"
                )
                continue
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
        if failed { throw ExitCode.failure }
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
        do {
            try ResourceName.validate(name, kind: "config")
            let data: Data
            if file == "-" {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                data = try Data(contentsOf: URL(fileURLWithPath: file))
            }
            let path = configsDir().appendingPathComponent(name)
            try data.write(to: path)
            UX.printCreated(.config, name)
        } catch {
            UX.Failure.emit(
                headline: "Cannot create config \(name)",
                reason: error.localizedDescription,
                hint: "verify the source file exists and is readable"
            )
            throw ExitCode.failure
        }
    }
}

struct ConfigLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List configs")

    mutating func run() async throws {
        let dir = configsDir()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let rows: [UX.Table.Row] = files.sorted().compactMap { name in
            let path = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else { return nil }
            let created = (attrs[.creationDate] as? Date).map(relativeTime(from:)) ?? "-"
            let size = (attrs[.size] as? Int).map { UX.formatBytes(Int64($0)) } ?? "-"
            let id = String(name.hash.magnitude, radix: 16).prefix(12).padding(toLength: 12, withPad: "0", startingAt: 0)
            return .init([
                .init(String(id), color: .accent),
                .init(name),
                .init(created, color: .dim),
                .init(size, color: .dim),
            ])
        }
        let table = UX.Table(
            columns: [
                .init("ID"),
                .init("NAME"),
                .init("CREATED"),
                .init("SIZE", align: .right),
            ],
            rows: rows,
            emptyMessage: "no configs — run `cocker config create <name> <file>` to add one"
        )
        print(table.render())
    }
}

struct ConfigRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more configs")

    @Argument(help: "Config name(s)")
    var names: [String]

    mutating func run() async throws {
        var failed = false
        for name in names {
            let path = configsDir().appendingPathComponent(name)
            do {
                try ResourceName.validate(name, kind: "config")
                try FileManager.default.removeItem(at: path)
                UX.printResult(.config, name, verb: .remove)
            } catch {
                failed = true
                UX.Failure.emit(
                    headline: "Cannot remove config \(name)",
                    reason: error.localizedDescription,
                    hint: "check `cocker config ls` to see what's stored"
                )
            }
        }
        if failed { throw ExitCode.failure }
    }
}

struct ConfigInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more configs")

    @Argument(help: "Config name")
    var names: [String]

    mutating func run() async throws {
        let dir = configsDir()
        var entries: [[String: Any]] = []
        var failed = false
        for name in names {
            do {
                try ResourceName.validate(name, kind: "config")
            } catch {
                failed = true
                UX.Failure.emit(
                    headline: "Cannot inspect config \(name)",
                    reason: error.localizedDescription,
                    hint: "list available configs with `cocker config ls`"
                )
                continue
            }
            let path = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else {
                failed = true
                UX.Failure.emit(
                    headline: "Cannot inspect config \(name)",
                    reason: "config not found",
                    hint: "list available configs with `cocker config ls`"
                )
                continue
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
        if failed { throw ExitCode.failure }
    }
}
