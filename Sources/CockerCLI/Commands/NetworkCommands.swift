import ArgumentParser
import CockerCore
import Foundation

struct NetworkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Manage networks",
        subcommands: [
            NetworkLsCommand.self,
            NetworkCreateCommand.self,
            NetworkRmCommand.self,
            NetworkInspectCommand.self,
            NetworkConnectCommand.self,
            NetworkDisconnectCommand.self,
        ]
    )
}

struct NetworkLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List networks")

    @Flag(name: [.short, .customLong("quiet")], help: "Only display IDs")
    var quiet = false

    mutating func run() async throws {
        let client = IPCClient()
        let request = try IPCRequest(type: .networkLs, payload: EmptyPayload())
        let response = try await client.send(request)
        let result = try response.decode(NetworksResponse.self)

        if quiet { result.networks.forEach { print($0.id) }; return }

        let columns: [TableFormatter.Column] = [
            .init("NETWORK ID", min: 12, max: 12),
            .init("NAME", min: 16, max: 30),
            .init("DRIVER", min: 10),
            .init("SCOPE", min: 8),
            .init("SUBNET", min: 18),
        ]

        let rows = result.networks.map { n -> [String] in [
            String(n.id.prefix(12)),
            n.name,
            n.driver.rawValue,
            "local",
            n.subnet,
        ]}

        if !rows.isEmpty { print(TableFormatter.format(columns: columns, rows: rows)) }
    }
}

struct NetworkCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a network")

    @Option(name: .customShort("d"), help: "Driver (bridge|host|none|overlay)")
    var driver: String = "bridge"

    @Option(name: .customLong("subnet"), help: "Subnet in CIDR format (e.g. 172.20.0.0/16)")
    var subnet: String?

    @Option(name: .customLong("gateway"), help: "IPv4 or IPv6 gateway")
    var gateway: String?

    @Option(name: .customLong("label"), help: "Set metadata on a network")
    var labels: [String] = []

    @Argument(help: "Network name")
    var name: String

    mutating func run() async throws {
        let driver = NetworkDriver(rawValue: self.driver) ?? .bridge
        let payload = NetworkCreateRequest(name: name, driver: driver, subnet: subnet, gateway: gateway)
        let client = IPCClient()
        let start = Date()
        do {
            let request = try IPCRequest(type: .networkCreate, payload: payload)
            let response = try await client.send(request)
            let network = try response.decode(NetworkInfo.self)
            if UX.TTY.current.isInteractive {
                let trailing = UX.TTY.paint(String(network.id.prefix(12)), .accent) + " · " + UX.formatElapsed(Date().timeIntervalSince(start))
                print(UX.ActionLine(
                    icon: .success, type: .network, name: network.name,
                    status: "Created", trailing: trailing
                ).render())
            } else {
                print(network.id)
            }
        } catch let error as CockerError {
            UX.Failure.emit(
                headline: "Cannot create network \(name)",
                reason: error.description,
                hint: "another network may already be named `\(name)` — `cocker network ls`"
            )
            throw ExitCode.failure
        }
    }
}

struct NetworkRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more networks")

    @Argument(help: "Network ID(s) or name(s)")
    var networks: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for name in networks {
            let start = Date()
            do {
                let request = try IPCRequest(type: .networkRm, payload: ContainerIDRequest(id: name))
                _ = try await client.send(request)
                UX.printResult(.network, name, verb: .remove, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                UX.Failure.emit(
                    headline: "Cannot remove network \(name)",
                    reason: error.description,
                    hint: "disconnect attached containers first — `cocker network inspect \(name)`"
                )
            }
        }
    }
}

struct NetworkInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed network information")

    @Argument(help: "Network ID(s) or name(s)")
    var networks: [String]

    mutating func run() async throws {
        let client = IPCClient()
        var results: [NetworkInfo] = []
        for name in networks {
            let payload = ContainerIDRequest(id: name)
            let request = try IPCRequest(type: .networkInspect, payload: payload)
            let response = try await client.send(request)
            results.append(try response.decode(NetworkInfo.self))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(results), encoding: .utf8) ?? "")
    }
}

struct NetworkConnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "connect", abstract: "Connect a container to a network")

    @Argument(help: "Network name")
    var network: String

    @Argument(help: "Container ID or name")
    var container: String

    mutating func run() async throws {
        struct Payload: Codable, Sendable { let network, container: String }
        let client = IPCClient()
        let start = Date()
        do {
            let request = try IPCRequest(type: .networkConnect, payload: Payload(network: network, container: container))
            _ = try await client.send(request)
            if UX.TTY.current.isInteractive {
                let trailing = "→ " + UX.TTY.paint(network, .accent) + " · " + UX.formatElapsed(Date().timeIntervalSince(start))
                print(UX.ActionLine(
                    icon: .success, type: .container, name: container,
                    status: "Connected", trailing: trailing
                ).render())
            }
        } catch let error as CockerError {
            UX.Failure.emit(
                headline: "Cannot connect \(container) to \(network)",
                reason: error.description
            )
            throw ExitCode.failure
        }
    }
}

struct NetworkDisconnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disconnect", abstract: "Disconnect a container from a network")

    @Flag(name: [.short, .customLong("force")], help: "Force disconnect")
    var force = false

    @Argument(help: "Network name")
    var network: String

    @Argument(help: "Container ID or name")
    var container: String

    mutating func run() async throws {
        struct Payload: Codable, Sendable { let network, container: String }
        let client = IPCClient()
        let start = Date()
        do {
            let request = try IPCRequest(type: .networkDisconnect, payload: Payload(network: network, container: container))
            _ = try await client.send(request)
            if UX.TTY.current.isInteractive {
                let trailing = "from " + UX.TTY.paint(network, .accent) + " · " + UX.formatElapsed(Date().timeIntervalSince(start))
                print(UX.ActionLine(
                    icon: .success, type: .container, name: container,
                    status: "Disconnected", trailing: trailing
                ).render())
            }
        } catch let error as CockerError {
            UX.Failure.emit(
                headline: "Cannot disconnect \(container) from \(network)",
                reason: error.description,
                hint: force ? nil : "use `--force` (-f) if the container is unresponsive"
            )
            throw ExitCode.failure
        }
    }
}
