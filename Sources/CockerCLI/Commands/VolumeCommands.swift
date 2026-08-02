import ArgumentParser
import CockerCore
import Foundation

struct VolumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Manage volumes",
        subcommands: [
            VolumeLsCommand.self,
            VolumeCreateCommand.self,
            VolumeRmCommand.self,
            VolumeInspectCommand.self,
            VolumePruneCommand.self,
        ]
    )
}

struct VolumeLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List volumes")

    @Flag(name: [.short, .customLong("quiet")], help: "Only display volume names")
    var quiet = false

    mutating func run() async throws {
        let client = IPCClient()
        let request = try IPCRequest(type: .volumeLs, payload: EmptyPayload())
        let response = try await client.send(request)
        let result = try response.decode(VolumesResponse.self)

        if quiet { result.volumes.forEach { print($0.name) }; return }

        let rows: [UX.Table.Row] = result.volumes.map { v in
            .init([
                .init(v.driver, color: .dim),
                .init(v.name),
                .init(relativeTime(from: v.createdAt), color: .dim),
                .init(v.mountpoint, color: .dim),
            ])
        }
        let table = UX.Table(
            columns: [
                .init("DRIVER"),
                .init("VOLUME NAME"),
                .init("CREATED"),
                .init("MOUNTPOINT"),
            ],
            rows: rows,
            emptyMessage: "no volumes — run `cocker volume create <name>` to add one"
        )
        print(table.render())
    }
}

struct VolumeCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a volume")

    @Option(name: .shortAndLong, help: "Specify volume driver")
    var driver: String = "local"

    @Option(name: .customLong("label"), help: "Set metadata labels")
    var labels: [String] = []

    @Argument(help: "Volume name (optional)", completion: .none)
    var name: String?

    mutating func run() async throws {
        let volumeName = name ?? UUID().uuidString.prefix(12).lowercased()

        // `--label KEY=VALUE` arrives as raw "KEY=VALUE" strings ; turn them
        // into the dictionary the request actually carries. A bare `--label
        // KEY` (no `=`) maps to an empty value, matching Docker's behaviour.
        var labelMap: [String: String] = [:]
        for raw in labels {
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard !key.isEmpty else {
                UX.Failure.emit(
                    headline: "Invalid label \(raw)",
                    reason: "label key must not be empty",
                    hint: "use the form --label KEY=VALUE, e.g. --label env=prod"
                )
                throw ExitCode.failure
            }
            labelMap[key] = parts.count == 2 ? String(parts[1]) : ""
        }

        let payload = VolumeCreateRequest(name: String(volumeName), driver: driver, labels: labelMap)
        let client = IPCClient()
        let start = Date()
        do {
            let request = try IPCRequest(type: .volumeCreate, payload: payload)
            let response = try await client.send(request)
            let vol = try response.decode(VolumeInfo.self)
            UX.printCreated(.volume, vol.name, elapsed: Date().timeIntervalSince(start))
        } catch let error as CockerError {
            UX.Failure.emit(
                headline: "Cannot create volume",
                reason: error.description,
                hint: "another volume may already be named `\(volumeName)` — `cocker volume ls`"
            )
            throw ExitCode(error.exitCode)
        }
    }
}

struct VolumeRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more volumes")

    @Flag(name: [.short, .customLong("force")], help: "Force removal")
    var force = false

    @Argument(help: "Volume name(s)")
    var volumes: [String]

    mutating func run() async throws {
        let client = IPCClient()
        let failures = FailureCode()
        for name in volumes {
            let start = Date()
            do {
                // `force` used to be parsed and never sent, so `-f` did
                // nothing at all on the daemon side.
                let request = try IPCRequest(type: .volumeRm,
                                             payload: ContainerIDRequest(id: name, force: force))
                _ = try await client.send(request)
                UX.printResult(.volume, name, verb: .remove, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                // Report every failure, then fail. Previously `--force`
                // printed this block and still exited 0, so a script doing
                // `cocker volume rm -f x && …` continued as if the volume
                // were gone. `--force` relaxes *which* volumes may be
                // removed; it never turns a refusal into a success.
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot remove volume \(name)",
                    reason: error.description,
                    hint: "the volume may be in use — `cocker volume inspect \(name)`"
                )
            }
        }
        try failures.throwIfFailed()
    }
}

struct VolumeInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed volume information")

    @Argument(help: "Volume name(s)")
    var volumes: [String]

    mutating func run() async throws {
        let client = IPCClient()
        var results: [VolumeInfo] = []
        for name in volumes {
            let payload = ContainerIDRequest(id: name)
            let request = try IPCRequest(type: .volumeInspect, payload: payload)
            let response = try await client.send(request)
            results.append(try response.decode(VolumeInfo.self))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(results), encoding: .utf8) ?? "")
    }
}

struct VolumePruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Remove all unused local volumes")

    @Flag(name: [.short, .customLong("force")], help: "Do not prompt for confirmation")
    var force = false

    mutating func run() async throws {
        guard UX.Confirm.ask(
            summary: "This will remove all volumes not used by at least one container.",
            force: force
        ) else { return }

        let client = IPCClient()
        let payload = PruneRequest(volumes: true)
        let request = try IPCRequest(type: .prune, payload: payload)
        let response = try await client.send(request)
        let result = try response.decode(PruneResponse.self)

        if result.volumesDeleted.isEmpty {
            print(" " + UX.TTY.paint("nothing to prune — 0 B reclaimed", .dim, [.italic]))
        } else {
            for v in result.volumesDeleted {
                UX.printResult(.volume, v, verb: .remove)
            }
            print(" " + UX.TTY.paint("reclaimed \(UX.formatBytes(Int64(result.spaceReclaimed)))", .dim))
        }
    }
}
