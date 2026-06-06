import ArgumentParser
import CockerCore
import Foundation

struct ComposeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Define and run multi-container applications",
        subcommands: [
            ComposeUpCommand.self,
            ComposeDownCommand.self,
            ComposeLsCommand.self,
            ComposeLogsCommand.self,
            ComposePsCommand.self,
            ComposeExecCommand.self,
            ComposeRunCommand.self,
            ComposeBuildCommand.self,
            ComposePullCommand.self,
            ComposeRestartCommand.self,
            ComposePauseCommand.self,
            ComposeUnpauseCommand.self,
            ComposeConfigCommand.self,
            ComposeKillCommand.self,
            ComposeTopCommand.self,
            ComposePortCommand.self,
            ComposeImagesCommand.self,
            ComposeEventsCommand.self,
        ]
    )
}

struct ComposeUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up", abstract: "Create and start containers")

    @Flag(name: [.short, .customLong("detach")], help: "Run in background")
    var detach = false

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Flag(name: .customLong("build"), help: "Build images before starting")
    var build = false

    @Flag(name: .customLong("remove-orphans"), help: "Remove containers for services not in compose file")
    var removeOrphans = false

    @Argument(help: "Services to start (default: all)", completion: .none)
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        guard FileManager.default.fileExists(atPath: composePath) else {
            throw CockerError.invalidComposeFile("File not found: \(composePath)")
        }

        let client = IPCClient()
        let payload = ComposeRequest(composePath: composePath, projectName: projectName, services: services, detach: detach)
        let request = try IPCRequest(type: .composeUp, payload: payload)

        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status: print(ANSI.colored(event.data, ANSI.cyan))
            case .error: fputs("Error: \(event.data)\n", stderr)
            }
        }
    }
}

struct ComposeDownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Stop and remove containers, networks")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Flag(name: .customLong("volumes"), help: "Remove named volumes")
    var removeVolumes = false

    @Flag(name: .customLong("remove-orphans"), help: "Remove orphaned containers")
    var removeOrphans = false

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let client = IPCClient()
        let payload = ComposeRequest(composePath: composePath, projectName: projectName)
        let request = try IPCRequest(type: .composeDown, payload: payload)
        _ = try await client.send(request)
        print("Compose project stopped and removed.")
    }
}

struct ComposeLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List running compose projects")

    mutating func run() async throws {
        let client = IPCClient()
        let request = try IPCRequest(type: .composeLs, payload: EmptyPayload())
        let response = try await client.send(request)
        let result = try response.decode(ComposeLsResponse.self)

        if result.projects.isEmpty {
            return
        }

        let columns: [TableFormatter.Column] = [
            .init("NAME", min: 20),
            .init("STATUS", min: 12),
            .init("CONFIG FILES", min: 30),
            .init("SERVICES", min: 10),
        ]
        let rows = result.projects.map { p -> [String] in [
            p.name, p.status, p.configFiles, "\(p.servicesCount)"
        ]}
        print(TableFormatter.format(columns: columns, rows: rows))
    }
}

struct ComposeLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "View output from containers")

    @Flag(name: [.short, .customLong("follow")], help: "Follow log output")
    var follow = false

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Services to show logs for (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let client = IPCClient()
        let payload = ComposeRequest(composePath: composePath, projectName: projectName, services: services)
        let request = try IPCRequest(type: .composeLogs, payload: payload)

        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            default: break
            }
        }
    }
}

struct ComposePsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List containers in compose project")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    mutating func run() async throws {
        // Détermine le project name : argument explicite, ou dossier du compose file
        let project = projectName ?? URL(fileURLWithPath: resolvePath(file))
            .deletingLastPathComponent().lastPathComponent

        let client = IPCClient()
        // Utilise `ps` avec filter label pour récupérer les containers du projet
        let payload = PSRequest(all: true, filter: ["label": "com.cocker.project=\(project)"])
        let request = try IPCRequest(type: .ps, payload: payload)
        let response = try await client.send(request)
        let containers = try response.decode(PSResponse.self).containers

        let columns: [TableFormatter.Column] = [
            .init("NAME", min: 24),
            .init("IMAGE", min: 20),
            .init("STATUS", min: 12),
            .init("PORTS", min: 20),
        ]
        let rows = containers.map { c -> [String] in [
            c.name, c.image, c.status.rawValue,
            c.ports.map { $0.description }.joined(separator: ", "),
        ]}
        if !rows.isEmpty { print(TableFormatter.format(columns: columns, rows: rows)) }
    }
}

struct ComposeExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "exec", abstract: "Execute a command in a running service container")

    @Flag(name: .customShort("T"), help: "Disable pseudo-TTY allocation")
    var noTTY = false

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Service name")
    var service: String

    @Argument(parsing: .remaining, help: "Command to execute")
    var command: [String]

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let pName = projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent
        let containerName = "\(pName)_\(service)_1"

        let client = IPCClient()
        // Find the container by name
        let psPayload = PSRequest(all: false, filter: ["name": containerName])
        let psRequest = try IPCRequest(type: .ps, payload: psPayload)
        let psResponse = try await client.send(psRequest)
        let containers = try psResponse.decode(PSResponse.self).containers

        guard let container = containers.first else {
            fputs("Error: No container found for service '\(service)' in project '\(pName)'\n", stderr)
            throw ExitCode.failure
        }

        var config = ExecConfig(containerID: container.id, command: command)
        config.tty = !noTTY
        let payload = ExecRequest(config: config)
        let request = try IPCRequest(type: .exec, payload: payload)

        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            default: break
            }
        }
    }
}

struct ComposeRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run a one-off command on a service")

    @Flag(name: [.short, .customLong("detach")], help: "Run in background")
    var detach = false

    @Flag(name: .customLong("rm"), help: "Remove container after run")
    var rm = false

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Service name")
    var service: String

    @Argument(parsing: .remaining, help: "Command override")
    var command: [String]

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let client = IPCClient()
        let payload = ComposeRequest(composePath: composePath, projectName: projectName, services: [service], detach: detach)
        let request = try IPCRequest(type: .composeRun, payload: payload)

        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status: print(ANSI.colored(event.data, ANSI.cyan))
            case .error: fputs("Error: \(event.data)\n", stderr)
            }
        }
    }
}

struct ComposeBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build or rebuild services")

    @Flag(name: .customLong("no-cache"), help: "Do not use cache when building")
    var noCache = false

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Services to build (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let client = IPCClient()
        let payload = ComposeRequest(composePath: composePath, projectName: projectName, services: services)
        let request = try IPCRequest(type: .composeBuild, payload: payload)

        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status: print(ANSI.colored(event.data, ANSI.cyan))
            case .error: fputs("Error: \(event.data)\n", stderr)
            }
        }
    }
}

struct ComposePullCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Pull service images")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Services to pull (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let client = IPCClient()
        let payload = ComposeRequest(composePath: composePath, projectName: projectName, services: services)
        let request = try IPCRequest(type: .composePull, payload: payload)

        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status: print(ANSI.colored(event.data, ANSI.cyan))
            case .error: fputs("Error: \(event.data)\n", stderr)
            }
        }
    }
}

struct ComposeRestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart service containers")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Services to restart (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let client = IPCClient()
        let payload = ComposeRequest(composePath: composePath, projectName: projectName, services: services)
        let request = try IPCRequest(type: .composeRestart, payload: payload)
        _ = try await client.send(request)
        print("Services restarted.")
    }
}

struct ComposePauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Pause services")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Services to pause (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let pName = projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent
        let client = IPCClient()

        let svcNames = services.isEmpty ? nil : services
        let allContainers: [Container]
        let psPayload = PSRequest(all: false)
        let psReq = try IPCRequest(type: .ps, payload: psPayload)
        let psResp = try await client.send(psReq)
        allContainers = try psResp.decode(PSResponse.self).containers

        let toProcess = allContainers.filter { c in
            c.labels["com.cocker.project"] == pName &&
            (svcNames == nil || svcNames!.contains(c.labels["com.cocker.service"] ?? ""))
        }

        for c in toProcess {
            let payload = ContainerIDRequest(id: c.id)
            let req = try IPCRequest(type: .pause, payload: payload)
            _ = try? await client.send(req)
            print(c.name)
        }
    }
}

struct ComposeUnpauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unpause", abstract: "Unpause services")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Services to unpause (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let pName = projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent
        let client = IPCClient()

        let svcNames = services.isEmpty ? nil : services
        let psPayload = PSRequest(all: false)
        let psReq = try IPCRequest(type: .ps, payload: psPayload)
        let psResp = try await client.send(psReq)
        let allContainers = try psResp.decode(PSResponse.self).containers

        let toProcess = allContainers.filter { c in
            c.labels["com.cocker.project"] == pName &&
            c.status == .paused &&
            (svcNames == nil || svcNames!.contains(c.labels["com.cocker.service"] ?? ""))
        }

        for c in toProcess {
            let payload = ContainerIDRequest(id: c.id)
            let req = try IPCRequest(type: .unpause, payload: payload)
            _ = try? await client.send(req)
            print(c.name)
        }
    }
}

struct ComposeConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Parse and display the resolved compose file")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    mutating func run() async throws {
        let composePath = resolvePath(file)
        guard FileManager.default.fileExists(atPath: composePath) else {
            fputs("Error: compose file not found: \(composePath)\n", stderr)
            throw ExitCode.failure
        }
        let content = try String(contentsOfFile: composePath, encoding: .utf8)
        // Interpolate ${VAR} and $VAR from environment
        var resolved = content
        for (key, value) in ProcessInfo.processInfo.environment {
            resolved = resolved.replacingOccurrences(of: "${\(key)}", with: value)
            resolved = resolved.replacingOccurrences(of: "$\(key)", with: value)
        }
        print(resolved)
    }
}

struct ComposeKillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "kill", abstract: "Force stop service containers")

    @Option(name: [.short, .customLong("signal")], help: "Signal to send (default SIGKILL)")
    var signal: String = "SIGKILL"

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Services to kill (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let pName = projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent
        let client = IPCClient()

        let psPayload = PSRequest(all: true)
        let psReq = try IPCRequest(type: .ps, payload: psPayload)
        let psResp = try await client.send(psReq)
        let allContainers = try psResp.decode(PSResponse.self).containers

        let toKill = allContainers.filter { c in
            c.labels["com.cocker.project"] == pName &&
            (services.isEmpty || services.contains(c.labels["com.cocker.service"] ?? ""))
        }

        for c in toKill {
            let payload = ContainerIDRequest(id: c.id, signal: signal)
            let req = try IPCRequest(type: .kill, payload: payload)
            _ = try? await client.send(req)
            print(c.name)
        }
    }
}

struct ComposeTopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "top", abstract: "Display the running processes of service containers")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Services to show (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let pName = projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent
        let client = IPCClient()

        let psPayload = PSRequest(all: false)
        let psReq = try IPCRequest(type: .ps, payload: psPayload)
        let psResp = try await client.send(psReq)
        let allContainers = try psResp.decode(PSResponse.self).containers

        let toShow = allContainers.filter { c in
            c.labels["com.cocker.project"] == pName &&
            (services.isEmpty || services.contains(c.labels["com.cocker.service"] ?? ""))
        }

        for c in toShow {
            print("\(c.name)")
            let payload = ContainerIDRequest(id: c.id)
            let req = try IPCRequest(type: .top, payload: payload)
            let resp = try? await client.send(req)
            let result = (try? resp?.decode(String.self)) ?? "PID   USER   COMMAND\n1     root   /sbin/init"
            print(result)
            print("")
        }
    }
}

struct ComposePortCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "port", abstract: "Print the public port for a port binding")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Option(name: .customLong("protocol"), help: "Protocol (tcp|udp)")
    var proto: String = "tcp"

    @Argument(help: "Service name")
    var service: String

    @Argument(help: "Private port")
    var privatePort: String

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let pName = projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent
        let client = IPCClient()

        let psPayload = PSRequest(all: false, filter: ["label": "com.cocker.project=\(pName)"])
        let psReq = try IPCRequest(type: .ps, payload: psPayload)
        let psResp = try await client.send(psReq)
        let allContainers = try psResp.decode(PSResponse.self).containers

        guard let container = allContainers.first(where: { $0.labels["com.cocker.service"] == service }) else {
            fputs("Error: no running container for service '\(service)' in project '\(pName)'\n", stderr)
            throw ExitCode.failure
        }

        guard let port = UInt16(privatePort) else {
            fputs("Error: invalid port: \(privatePort)\n", stderr)
            throw ExitCode.failure
        }

        if let mapping = container.ports.first(where: { $0.containerPort == port && $0.proto.rawValue == proto }) {
            print("0.0.0.0:\(mapping.hostPort)")
        } else {
            fputs("Error: port \(privatePort)/\(proto) not published for service '\(service)'\n", stderr)
            throw ExitCode.failure
        }
    }
}

struct ComposeImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "images", abstract: "List images used by the compose project services")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Argument(help: "Services to show (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let pName = projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent
        let client = IPCClient()

        let psPayload = PSRequest(all: true, filter: ["label": "com.cocker.project=\(pName)"])
        let psReq = try IPCRequest(type: .ps, payload: psPayload)
        let psResp = try await client.send(psReq)
        let allContainers = try psResp.decode(PSResponse.self).containers

        let filtered = services.isEmpty ? allContainers : allContainers.filter {
            services.contains($0.labels["com.cocker.service"] ?? "")
        }

        let columns: [TableFormatter.Column] = [
            .init("CONTAINER", min: 24),
            .init("REPOSITORY", min: 20),
            .init("TAG", min: 12),
            .init("IMAGE ID", min: 12),
        ]

        let imagesReq = try IPCRequest(type: .images, payload: EmptyPayload())
        let imagesResp = try await client.send(imagesReq)
        let allImages = try imagesResp.decode(ImagesResponse.self).images

        var rows: [[String]] = []
        for c in filtered {
            let img = allImages.first { $0.reference == c.image || $0.id.hasPrefix(c.image) }
            let repo = img?.repository ?? c.image
            let tag = img?.tag ?? "latest"
            let imgID = String((img?.id ?? "").prefix(12))
            rows.append([c.name, repo, tag, imgID])
        }

        if !rows.isEmpty { print(TableFormatter.format(columns: columns, rows: rows)) }
    }
}

struct ComposeEventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "events", abstract: "Receive real-time events from containers")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Flag(name: .customLong("json"), help: "Output events as JSON objects")
    var json = false

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let pName = projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent
        let client = IPCClient()
        let request = try IPCRequest(type: .events, payload: EmptyPayload())
        let outputJSON = json

        try await client.sendStreaming(request) { event in
            let ts = ISO8601DateFormatter().string(from: event.timestamp)
            // Filter events relevant to this project
            if event.data.contains(pName) || event.stream == .status {
                if outputJSON {
                    let obj = ["time": ts, "type": "container", "action": event.data, "project": pName]
                    if let data = try? JSONSerialization.data(withJSONObject: obj),
                       let str = String(data: data, encoding: .utf8) {
                        print(str)
                    }
                } else {
                    print("\(ts) container \(event.data)")
                }
            }
        }
    }
}

private func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    return FileManager.default.currentDirectoryPath + "/" + path
}
