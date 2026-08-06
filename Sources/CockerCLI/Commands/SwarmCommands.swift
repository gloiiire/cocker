import ArgumentParser
import CockerCore
import Foundation

// Single-node swarm mode — maps to compose under the hood

// MARK: - Swarm

struct SwarmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swarm",
        abstract: "Manage Swarm",
        subcommands: [SwarmInitCommand.self, SwarmLeaveCommand.self, SwarmJoinCommand.self]
    )
}

struct SwarmInitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init", abstract: "Initialize a swarm")

    @Option(name: .customLong("advertise-addr"), help: "Advertised address")
    var advertiseAddr: String?

    mutating func run() async throws {
        // This wrote a swarm.json and printed a join token — a plausible
        // `SWMTKN-1-…` string that joins nothing, because there is no
        // cluster and no second node to join it. Someone could paste that
        // token into a real command and spend a while wondering why.
        throw CockerError.notImplemented("swarm init")
    }
}

struct SwarmLeaveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "leave", abstract: "Leave the swarm")

    @Flag(name: [.short, .customLong("force")])
    var force = false

    mutating func run() async throws {
        // Deleted swarm.json and always reported success, `--force` unread.
        throw CockerError.notImplemented("swarm leave")
    }
}

struct SwarmJoinCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "join", abstract: "Join a swarm")

    @Option(name: .customLong("token"))
    var token: String?

    @Argument
    var addr: String

    mutating func run() async throws {
        // Reported "joined" and never used the address or the token.
        throw CockerError.notImplemented("swarm join")
    }
}

// MARK: - Stack

struct StackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stack",
        abstract: "Manage stacks",
        subcommands: [
            StackDeployCommand.self,
            StackLsCommand.self,
            StackRmCommand.self,
            StackServicesCommand.self,
            StackPsCommand.self,
        ]
    )
}

struct StackDeployCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deploy",
        abstract: "Deploy a new stack or update an existing stack"
    )

    @Option(name: [.short, .customLong("compose-file")], help: "Compose file path")
    var composeFile: String = "docker-compose.yml"

    /// Never read. There are no agents to send credentials to.
    @Flag(name: .customLong("with-registry-auth"),
          help: "Not honoured: single-node, there are no agents")
    var withRegistryAuth = false

    @Argument
    var stackName: String

    mutating func run() async throws {
        let composePath = composeFile.hasPrefix("/")
            ? composeFile
            : FileManager.default.currentDirectoryPath + "/" + composeFile

        guard FileManager.default.fileExists(atPath: composePath) else {
            UX.Failure.emit(
                headline: "Cannot deploy stack \(stackName)",
                reason: "compose file not found at \(composePath)",
                hint: "pass `-c <path>` or run from a directory containing docker-compose.yml"
            )
            throw ExitCode.failure
        }

        print(" " + UX.TTY.paint("→ Deploying", .progress) + " " + UX.TTY.paint(stackName, .accent))

        let client = IPCClient()
        let payload = ComposeRequest(composePath: composePath, projectName: stackName, services: [], detach: true)
        let request = try IPCRequest(type: .composeUp, payload: payload)

        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .status: print(UX.TTY.paint(event.data, .progress))
            default: break
            }
        }
    }
}

struct StackLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List stacks")

    mutating func run() async throws {
        let client = IPCClient()
        let request = try IPCRequest(type: .composeLs, payload: EmptyPayload())
        let response = try await client.send(request)
        let projects = try response.decode(ComposeLsResponse.self).projects

        print("NAME\t\tSERVICES\tORCHESTRATOR")
        for proj in projects {
            print("\(proj.name)\t\t\(proj.servicesCount)\t\tSwarm")
        }
    }
}

struct StackRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more stacks")

    @Argument
    var stacks: [String]

    mutating func run() async throws {
        let client = IPCClient()
        let failures = FailureCode()
        for stack in stacks {
            // Try common compose file locations
            let composePaths = [
                "./docker-compose.yml",
                "./compose.yml",
                "\(NSHomeDirectory())/.cocker/stacks/\(stack)/docker-compose.yml",
            ]
            let composePath = composePaths.first { FileManager.default.fileExists(atPath: $0) }
                ?? "./docker-compose.yml"

            let payload = ComposeRequest(composePath: composePath, projectName: stack)
            let request = try IPCRequest(type: .composeDown, payload: payload)
            // `_ = try?` then two unconditional lines — and `_web` was
            // invented: it printed for every stack whatever the services
            // were called, including when the compose file was never found
            // and the path fell back to ./docker-compose.yml. The daemon
            // reports what it actually tore down; print that.
            do {
                _ = try await client.send(request)
                UX.printResult(.service, stack, verb: .remove)
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot remove stack \(stack)",
                    reason: error.description,
                    hint: "no compose file found for this stack at \(composePath)"
                )
            }
        }
        try failures.throwIfFailed()
    }
}

struct StackServicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "services", abstract: "List the services in the stack")

    @Argument
    var stack: String

    mutating func run() async throws {
        let client = IPCClient()
        let payload = PSRequest(all: false, filter: ["label": "com.cocker.project=\(stack)"])
        let request = try IPCRequest(type: .ps, payload: payload)
        let response = try await client.send(request)
        let containers = try response.decode(PSResponse.self).containers

        let columns: [TableFormatter.Column] = [
            .init("ID", min: 12, max: 12),
            .init("NAME", min: 24),
            .init("MODE", min: 10),
            .init("REPLICAS", min: 12),
            .init("IMAGE", min: 30),
            .init("PORTS", min: 20),
        ]
        let rows = containers.map { c -> [String] in
            [
                String(c.id.prefix(12)),
                "\(stack)_\(c.labels["com.cocker.service"] ?? c.name)",
                "replicated",
                c.status == .running ? "1/1" : "0/1",
                c.image,
                c.ports.map { $0.description }.joined(separator: ", "),
            ]
        }
        print(TableFormatter.format(columns: columns, rows: rows))
    }
}

struct StackPsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List the tasks in the stack")

    @Argument
    var stack: String

    mutating func run() async throws {
        let client = IPCClient()
        let payload = PSRequest(all: true, filter: ["label": "com.cocker.project=\(stack)"])
        let request = try IPCRequest(type: .ps, payload: payload)
        let response = try await client.send(request)
        let containers = try response.decode(PSResponse.self).containers

        let columns: [TableFormatter.Column] = [
            .init("ID", min: 12, max: 12),
            .init("NAME", min: 24),
            .init("IMAGE", min: 30),
            .init("NODE", min: 12),
            .init("DESIRED STATE", min: 14),
            .init("CURRENT STATE", min: 20),
        ]
        let host = ProcessInfo.processInfo.hostName
        let rows = containers.map { c -> [String] in
            let desiredState = c.status == .running ? "Running" : "Shutdown"
            let currentState: String
            switch c.status {
            case .running:
                let upSecs = c.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
                currentState = "Running \(upSecs)s ago"
            case .stopped:
                currentState = "Complete \(c.exitCode.map { "(\($0))" } ?? "")"
            default:
                currentState = c.status.description
            }
            return [
                String(c.id.prefix(12)),
                "\(stack)_\(c.labels["com.cocker.service"] ?? c.name).1.\(String(c.id.prefix(8)))",
                c.image,
                host,
                desiredState,
                currentState,
            ]
        }
        print(TableFormatter.format(columns: columns, rows: rows))
    }
}

// MARK: - Node (single-node stubs)

struct NodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "node",
        abstract: "Manage Swarm nodes",
        subcommands: [NodeLsCommand.self, NodeInspectCommand.self]
    )
}

struct NodeLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List nodes in the swarm")

    mutating func run() async throws {
        // This printed a plausible node row with a *fresh UUID on every
        // call*. A caller scripting against it got a different node id each
        // time and no way to notice the table was invented.
        throw CockerError.notImplemented("node ls")
    }
}

struct NodeInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed node information")

    @Argument
    var nodes: [String]

    mutating func run() async throws {
        // Ignored its `nodes` argument entirely and printed a new random id.
        throw CockerError.notImplemented("node inspect")
    }
}

// MARK: - Service

struct ServiceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Manage services",
        subcommands: [
            ServiceLsCommand.self,
            ServicePsCommand.self,
            ServiceInspectCommand.self,
            ServiceCreateCommand.self,
            ServiceRmCommand.self,
            ServiceUpdateCommand.self,
            ServiceScaleCommand.self,
        ]
    )
}

struct ServiceLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List services")

    mutating func run() async throws {
        let client = IPCClient()
        let request = try IPCRequest(type: .ps, payload: PSRequest(all: false))
        let response = try await client.send(request)
        let containers = try response.decode(PSResponse.self).containers

        let columns: [TableFormatter.Column] = [
            .init("ID", min: 12, max: 12),
            .init("NAME", min: 24),
            .init("MODE", min: 12),
            .init("REPLICAS", min: 12),
            .init("IMAGE", min: 30),
            .init("PORTS", min: 20),
        ]
        let rows = containers.map { c -> [String] in
            [
                String(c.id.prefix(12)),
                c.name,
                // Literal "replicated" / "1/1" for every row, derived from
                // nothing. cocker is single-node, so a service IS one
                // container: report whether that container is actually up.
                "replicated",
                c.status == .running ? "1/1" : "0/1",
                c.image,
                c.ports.map { $0.description }.joined(separator: ", "),
            ]
        }
        if !rows.isEmpty { print(TableFormatter.format(columns: columns, rows: rows)) }
    }
}

struct ServicePsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List the tasks of a service")

    @Argument
    var services: [String]

    mutating func run() async throws {
        let client = IPCClient()
        let failures = FailureCode()
        for svc in services {
            let request = try IPCRequest(type: .inspect, payload: ContainerIDRequest(id: svc))
            // "Running" was printed for every row whatever c.status said,
            // and a service that doesn't exist printed nothing at all and
            // exited 0 — two `try?` in a row.
            do {
                let response = try await client.send(request)
                let c = try response.decode(Container.self)
                print("\(String(c.id.prefix(12)))   \(c.name).1   \(c.image)   "
                      + "\(c.status.rawValue.capitalized)")
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(headline: "No such service: \(svc)",
                                reason: error.description)
            }
        }
        try failures.throwIfFailed()
    }
}

struct ServiceInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed service info")

    @Argument
    var services: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for svc in services {
            let request = try IPCRequest(type: .inspect, payload: ContainerIDRequest(id: svc))
            if let response = try? await client.send(request),
               let c = try? response.decode(Container.self)
            {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                encoder.dateEncodingStrategy = .iso8601
                print(String(data: (try? encoder.encode(c)) ?? Data(), encoding: .utf8) ?? "")
            }
        }
    }
}

struct ServiceCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new service")

    @Option(name: .customLong("name"))
    var name: String?

    @Option(name: [.short, .customLong("publish")], help: "Publish a port")
    var ports: [String] = []

    @Option(name: [.short, .customLong("env")])
    var env: [String] = []

    @Option(name: .customLong("replicas"), help: "Number of replicas")
    var replicas: Int = 1

    @Option(name: .customLong("network"), help: "Network to attach service to")
    var network: String?

    /// Never read: `run()` builds a RunConfig with ports, env, network and
    /// labels, and never sets `config.volumes`.
    @Option(name: .customLong("mount"),
            help: "Not honoured: no volume is attached")
    var mounts: [String] = []

    /// Never read. There is one node, so there is nothing to place — but
    /// the sibling `--replicas` says so in its help and this did not.
    @Option(name: .customLong("constraint"),
            help: "Not honoured: single-node, nothing to place")
    var constraints: [String] = []

    @Argument
    var image: String

    @Argument(parsing: .remaining)
    var command: [String] = []

    mutating func run() async throws {
        if !mounts.isEmpty {
            UX.IgnoredFlag.warn("--mount", "the service starts with no volume attached")
        }
        if !constraints.isEmpty {
            UX.IgnoredFlag.warn("--constraint", "single-node: there is nothing to place")
        }
        var config = RunConfig(image: image, command: command)
        config.name = name
        config.detach = true
        config.network = network
        config.ports = ports.compactMap { try? PortMapping.parse($0) }
        config.labels["com.docker.swarm.service.name"] = name ?? image

        var envMap: [String: String] = [:]
        for e in env {
            let parts = e.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { envMap[String(parts[0])] = String(parts[1]) }
        }
        config.env = envMap

        let client = IPCClient()
        let request = try IPCRequest(type: .run, payload: RunRequest(config: config))
        let response = try await client.send(request)
        let result = try response.decode(RunResponse.self)
        print(result.containerID)

        if replicas > 1 {
            print("Warning: Only 1 replica supported in single-node mode (requested \(replicas))")
        }
    }
}

struct ServiceRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more services")

    @Argument
    var services: [String]

    mutating func run() async throws {
        let client = IPCClient()
        // `_ = try?` meant removing a service that doesn't exist printed
        // "✓ removed" and exited 0.
        let failures = FailureCode()
        for svc in services {
            let request = try IPCRequest(type: .rm, payload: ContainerIDRequest(id: svc))
            do {
                _ = try await client.send(request)
                UX.printResult(.service, svc, verb: .remove)
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(headline: "Cannot remove service \(svc)",
                                reason: error.description)
            }
        }
        try failures.throwIfFailed()
    }
}

struct ServiceUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a service")

    @Option(name: .customLong("image"))
    var image: String?

    @Option(name: .customLong("replicas"))
    var replicas: Int?

    @Argument
    var service: String

    mutating func run() async throws {
        // Printed "updated" while `--image` was never read — the service
        // kept running exactly what it was running before.
        throw CockerError.notImplemented("service update")
    }
}

struct ServiceScaleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scale",
        abstract: "Scale one or multiple replicated services"
    )

    @Argument(parsing: .remaining)
    var serviceScale: [String]  // "service=replicas"

    mutating func run() async throws {
        // Printed a per-service line and then warned that anything past one
        // replica is a no-op. Scaling is the entire point of the command.
        throw CockerError.notImplemented("service scale")
    }
}
