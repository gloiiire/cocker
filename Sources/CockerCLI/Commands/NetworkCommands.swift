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

        let rows: [UX.Table.Row] = result.networks.map { n in
            .init([
                .init(String(n.id.prefix(12)), color: .accent),
                .init(n.name),
                .init(n.driver.rawValue, color: .dim),
                .init("local", color: .dim),
                .init(n.subnet, color: .dim),
            ])
        }
        let table = UX.Table(
            columns: [
                .init("NETWORK ID", maxWidth: 12),
                .init("NAME", maxWidth: 30),
                .init("DRIVER"),
                .init("SCOPE"),
                .init("SUBNET"),
            ],
            rows: rows,
            emptyMessage: "no networks — run `cocker network create <name>` to add one"
        )
        print(table.render())
    }
}

struct NetworkCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a network")

    @Option(name: .customShort("d"), help: "Driver (bridge|host|none)")
    var driver: String = "bridge"

    /// The runtime refuses this with exit 126. The help string described it
    /// as an ordinary option, so `--help` and the generated man page
    /// promised something the command rejects — the exact shape 1.0
    /// commitment #1 forbids, in the direction the code had already fixed.
    @Option(name: .customLong("subnet"),
            help: "Not implemented: refused. Networks isolate, but take no custom range yet")
    var subnet: String?

    @Option(name: .customLong("gateway"),
            help: "Not implemented: refused, same as --subnet")
    var gateway: String?

    @Option(name: .customLong("label"), help: "Set metadata on a network")
    var labels: [String] = []

    @Argument(help: "Network name")
    var name: String

    /// `--label k=v` repeated. A bare `k` records an empty value, matching
    /// Docker.
    static func parseLabels(_ pairs: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
            else if parts.count == 1 { out[String(parts[0])] = "" }
        }
        return out
    }

    mutating func run() async throws {
        // `overlay` is advertised in the help and stored on the network, but
        // nothing implements it — every driver behaves as a bridge. Accepting
        // it produced a network the user believed was multi-host and wasn't.
        // Refuse the ones we don't implement rather than coercing silently.
        guard let driver = NetworkDriver(rawValue: self.driver),
              driver != .overlay else {
            UX.Failure.emit(
                headline: "Cannot create network \(name)",
                reason: "unsupported driver '\(self.driver)'",
                hint: "cocker implements bridge, host and none. There is no overlay "
                    + "networking on a single Mac — use `apple/container` or Docker "
                    + "Desktop if you need it."
            )
            throw ExitCode.failure
        }
        // `--subnet` / `--gateway` were parsed, stored on the network, and
        // never used: addresses always came from the single 10.42.0.0/16
        // fabric no matter what the user asked for. Networks isolate now, but
        // they still share one address space, so honouring these would take a
        // per-network allocator that does not exist yet.
        //
        // Refusing beats recording a number that decides nothing — a user who
        // pins a subnet is usually matching something external, and silently
        // getting a different one is the kind of failure that surfaces hours
        // later as "why can't these two talk".
        if let unsupported = subnet != nil ? "--subnet" : (gateway != nil ? "--gateway" : nil) {
            UX.Failure.emit(
                headline: "Cannot create network \(name)",
                reason: "\(unsupported) is not implemented",
                hint: "containers always draw from the shared \(CockerSwitchAllocator.subnet) "
                    + "fabric. Networks do isolate traffic — they just don't take a "
                    + "custom range yet. Drop the flag to create the network."
            )
            throw ExitCode(rawValue: 126)
        }
        let payload = NetworkCreateRequest(name: name, driver: driver, subnet: subnet, gateway: gateway,
                                           labels: Self.parseLabels(labels))
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
            throw ExitCode(error.exitCode)
        }
    }
}

struct NetworkRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more networks")

    @Argument(help: "Network ID(s) or name(s)")
    var networks: [String]

    mutating func run() async throws {
        let client = IPCClient()
        let failures = FailureCode()
        for name in networks {
            let start = Date()
            do {
                let request = try IPCRequest(type: .networkRm, payload: ContainerIDRequest(id: name))
                _ = try await client.send(request)
                UX.printResult(.network, name, verb: .remove, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot remove network \(name)",
                    reason: error.description,
                    hint: "disconnect attached containers first — `cocker network inspect \(name)`"
                )
            }
        }
        try failures.throwIfFailed()
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
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Move a stopped container onto a network",
        discussion: """
        A container has one L2 switch port, so it is on exactly one network:
        this MOVES it rather than adding a second attachment, which is where
        it differs from docker.

        The port is keyed from the container's network when its VM boots and
        is never re-keyed, so the change applies at the next start. A running
        container is refused rather than reported as connected — stop it, run
        this, start it again.
        """
    )

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
                // "Moved", not "Connected": a container has one L2 switch
                // port, so this replaces its network rather than adding one.
                // And the port is keyed when the VM boots, so a container
                // that is already up would have to be restarted — which is
                // why the daemon refuses that case outright instead of
                // reporting a connection that never happened.
                let trailing = "→ " + UX.TTY.paint(network, .accent)
                    + " · applies at next start · "
                    + UX.formatElapsed(Date().timeIntervalSince(start))
                print(UX.ActionLine(
                    icon: .success, type: .container, name: container,
                    status: "Moved", trailing: trailing
                ).render())
            }
        } catch let error as CockerError {
            // Carry the error's own hint through — rebuilding the block here
            // used to drop it, so "stop the container first" never reached
            // the person who needed it.
            UX.Failure.emit(
                headline: "Cannot connect \(container) to \(network)",
                reason: error.description,
                // The error crosses the socket as `.daemon(msg, code)`, which
                // carries the message and the exit code but not the hint —
                // so supply the one that is always right here rather than
                // letting it arrive empty.
                hint: error.presentation.hint
                    ?? "stop the container, connect it, then start it again"
            )
            throw ExitCode(error.exitCode)
        }
    }
}

struct NetworkDisconnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disconnect",
        abstract: "Move a stopped container back to the default bridge",
        discussion: """
        A container is always on some network, so leaving one means returning
        to `bridge`. Applies at the next start, for the same reason `connect`
        does: the switch port is wired when the VM boots. A running container
        is refused rather than reported as disconnected.
        """
    )

    /// The payload has no force field; this only picks a hint string.
    @Flag(name: [.short, .customLong("force")],
          help: "Not honoured: the disconnect is the same either way")
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
                let trailing = "from " + UX.TTY.paint(network, .accent)
                    + " · back on bridge at next start · "
                    + UX.formatElapsed(Date().timeIntervalSince(start))
                print(UX.ActionLine(
                    icon: .success, type: .container, name: container,
                    status: "Disconnected", trailing: trailing
                ).render())
            }
        } catch let error as CockerError {
            UX.Failure.emit(
                headline: "Cannot disconnect \(container) from \(network)",
                reason: error.description,
                hint: error.presentation.hint
                    ?? "stop the container, disconnect it, then start it again"
            )
            throw ExitCode(error.exitCode)
        }
    }
}
