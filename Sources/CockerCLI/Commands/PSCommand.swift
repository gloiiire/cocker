import ArgumentParser
import CockerCore
import Foundation

struct PSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "List containers"
    )

    @Flag(name: [.short, .customLong("all")], help: "Show all containers (default shows just running)")
    var all = false

    @Option(name: [.short, .customLong("filter")], help: "Filter by field (key=value)")
    var filter: [String] = []

    @Flag(name: .customLong("json"), help: "Output in JSON format")
    var json = false

    mutating func run() async throws {
        let client = IPCClient()
        var filters: [String: String] = [:]
        for f in filter {
            let parts = f.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { filters[String(parts[0])] = String(parts[1]) }
        }

        let payload = PSRequest(all: all, filter: filters)
        let request = try IPCRequest(type: .ps, payload: payload)
        let response = try await client.send(request)
        let result = try response.decode(PSResponse.self)

        if json {
            let data = try JSONEncoder().encode(result.containers)
            print(String(data: data, encoding: .utf8) ?? "")
            return
        }

        let columns: [TableFormatter.Column] = [
            .init("CONTAINER ID", min: 12, max: 12),
            .init("IMAGE", min: 20, max: 40),
            .init("COMMAND", min: 20, max: 30),
            .init("CREATED", min: 16),
            .init("STATUS", min: 12),
            .init("PORTS", min: 20),
            .init("NAMES", min: 16),
        ]

        let rows = result.containers.map { c -> [String] in
            let cmd = c.command.isEmpty ? "" : c.command.joined(separator: " ")
            let ports = c.ports.map { $0.description }.joined(separator: ", ")
            let status = statusString(c)
            return [
                String(c.id.prefix(12)),
                c.image,
                cmd.isEmpty ? "" : "\"\(cmd)\"",
                relativeTime(from: c.createdAt),
                status,
                ports,
                c.name,
            ]
        }

        if result.containers.isEmpty {
            return
        }
        print(TableFormatter.format(columns: columns, rows: rows))
    }

    private func statusString(_ c: Container) -> String {
        switch c.status {
        case .running:
            let uptime = c.startedAt.map { relativeTime(from: $0).replacingOccurrences(of: " ago", with: "") } ?? "unknown"
            return ANSI.colored("Up \(uptime)", ANSI.green)
        case .stopped:
            let code = c.exitCode.map { " (\($0))" } ?? ""
            return ANSI.colored("Exited\(code)", ANSI.red)
        case .created:
            return ANSI.colored("Created", ANSI.yellow)
        case .paused:
            return ANSI.colored("Paused", ANSI.yellow)
        case .restarting:
            return ANSI.colored("Restarting", ANSI.yellow)
        case .dead:
            return ANSI.colored("Dead", ANSI.red)
        }
    }
}

struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Return detailed information on one or more containers"
    )

    @Argument(help: "Container ID or name", completion: .none)
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        var results: [Container] = []

        for id in containers {
            let payload = ContainerIDRequest(id: id)
            let request = try IPCRequest(type: .inspect, payload: payload)
            let response = try await client.send(request)
            let container = try response.decode(Container.self)
            results.append(container)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(results)
        print(String(data: data, encoding: .utf8) ?? "")
    }
}

struct TopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top",
        abstract: "Display running processes in a container"
    )

    @Argument(help: "Container ID or name")
    var container: String

    mutating func run() async throws {
        let client = IPCClient()
        let payload = ContainerIDRequest(id: container)
        let request = try IPCRequest(type: .top, payload: payload)
        let response = try await client.send(request)
        let output = try response.decode(String.self)
        print(output)
    }
}

struct StatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Display resource usage statistics"
    )

    @Flag(name: .customLong("no-stream"), help: "Display a single snapshot")
    var noStream = false

    @Flag(name: [.short, .customLong("all")], help: "Show all containers (not just running)")
    var all = false

    @Argument(help: "Container IDs or names (default: all running)")
    var containers: [String] = []

    mutating func run() async throws {
        let client = IPCClient()
        let payload = PSRequest(all: all || !containers.isEmpty)
        let request = try IPCRequest(type: .ps, payload: payload)
        let response = try await client.send(request)
        var allContainers = try response.decode(PSResponse.self).containers

        if !containers.isEmpty {
            allContainers = allContainers.filter { c in
                containers.contains(c.id) || containers.contains(String(c.id.prefix(12))) || containers.contains(c.name)
            }
        } else {
            allContainers = allContainers.filter { $0.status == .running }
        }

        if allContainers.isEmpty {
            print("No containers found.")
            return
        }

        let columns: [TableFormatter.Column] = [
            .init("CONTAINER ID", min: 12, max: 12),
            .init("NAME", min: 20, max: 30),
            .init("CPU %", min: 8),
            .init("MEM USAGE / LIMIT", min: 22),
            .init("MEM %", min: 8),
        ]

        let rows = allContainers.map { c -> [String] in
            let memUsage = c.memoryMB * 1024 * 1024  // approximate: configured limit as proxy
            let memLimit = memUsage
            let memPct = memLimit > 0 ? "100.00%" : "0.00%"
            return [
                String(c.id.prefix(12)),
                c.name,
                "0.00%",
                "\(formatBytes(memUsage)) / \(formatBytes(memLimit))",
                memPct,
            ]
        }

        print(TableFormatter.format(columns: columns, rows: rows))
    }
}

struct PortCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "port",
        abstract: "List port mappings or a specific mapping for a container"
    )

    @Argument(help: "Container ID or name")
    var container: String

    @Argument(help: "Private port (e.g. 80 or 80/tcp)")
    var privatePort: String?

    mutating func run() async throws {
        let client = IPCClient()
        let payload = ContainerIDRequest(id: container)
        let request = try IPCRequest(type: .inspect, payload: payload)
        let response = try await client.send(request)
        let c = try response.decode(Container.self)

        guard !c.ports.isEmpty else {
            fputs("Error: No ports published for \(container)\n", stderr)
            throw ExitCode.failure
        }

        if let portSpec = privatePort {
            // Parse "80" or "80/tcp"
            let parts = portSpec.split(separator: "/")
            let portNum = UInt16(parts[0]) ?? 0
            let proto = parts.count > 1 ? String(parts[1]) : "tcp"

            let matches = c.ports.filter { $0.containerPort == portNum && $0.proto.rawValue == proto }
            guard !matches.isEmpty else {
                fputs("Error: No public port '\(portSpec)' published for '\(container)'\n", stderr)
                throw ExitCode.failure
            }
            for m in matches {
                print("0.0.0.0:\(m.hostPort)")
            }
        } else {
            for m in c.ports {
                print("\(m.containerPort)/\(m.proto.rawValue) -> 0.0.0.0:\(m.hostPort)")
            }
        }
    }
}

struct DiffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Inspect changes to files or directories on a container's filesystem"
    )

    @Argument(help: "Container ID or name")
    var container: String

    mutating func run() async throws {
        let client = IPCClient()
        let payload = ContainerIDRequest(id: container)
        let request = try IPCRequest(type: .diff, payload: payload)
        let response = try await client.send(request)
        let result = try response.decode(DiffResponse.self)

        for entry in result.entries {
            print("\(entry.kind) \(entry.path)")
        }
    }
}
