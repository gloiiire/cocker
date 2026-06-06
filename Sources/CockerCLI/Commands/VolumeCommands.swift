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

        let columns: [TableFormatter.Column] = [
            .init("DRIVER", min: 10),
            .init("VOLUME NAME", min: 24),
            .init("CREATED", min: 16),
            .init("MOUNTPOINT", min: 30),
        ]

        let rows = result.volumes.map { v -> [String] in [
            v.driver,
            v.name,
            relativeTime(from: v.createdAt),
            v.mountpoint,
        ]}

        if !rows.isEmpty { print(TableFormatter.format(columns: columns, rows: rows)) }
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
        let payload = VolumeCreateRequest(name: String(volumeName), driver: driver)
        let client = IPCClient()
        let request = try IPCRequest(type: .volumeCreate, payload: payload)
        let response = try await client.send(request)
        let vol = try response.decode(VolumeInfo.self)
        print(vol.name)
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
        for name in volumes {
            let payload = ContainerIDRequest(id: name)
            let request = try IPCRequest(type: .volumeRm, payload: payload)
            do {
                _ = try await client.send(request)
                print(name)
            } catch let error as CockerError {
                fputs("Error: \(error.description)\n", stderr)
                if !force { throw error }
            }
        }
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
        if !force {
            print("WARNING! This will remove all volumes not used by at least one container.")
            print("Are you sure you want to continue? [y/N] ", terminator: "")
            let answer = readLine()?.lowercased() ?? "n"
            guard answer == "y" || answer == "yes" else { return }
        }

        let client = IPCClient()
        let payload = PruneRequest(volumes: true)
        let request = try IPCRequest(type: .prune, payload: payload)
        let response = try await client.send(request)
        let result = try response.decode(PruneResponse.self)

        if result.volumesDeleted.isEmpty {
            print("Total reclaimed space: 0 B")
        } else {
            result.volumesDeleted.forEach { print("Deleted volumes: \($0)") }
            print("Total reclaimed space: \(formatBytes(result.spaceReclaimed))")
        }
    }
}
