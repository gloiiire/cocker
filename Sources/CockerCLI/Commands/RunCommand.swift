import ArgumentParser
import CockerCore
import Foundation

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command in a new container"
    )

    @Flag(name: .shortAndLong, help: "Run container in the background")
    var detach = false

    @Flag(name: [.short, .customLong("interactive")], help: "Keep STDIN open")
    var interactive = false

    @Flag(name: .customShort("t"), help: "Allocate a pseudo-TTY")
    var tty = false

    @Flag(name: .customLong("rm"), help: "Automatically remove container when it exits")
    var rm = false

    @Option(name: .customLong("name"), help: "Assign a name to the container")
    var name: String?

    @Option(name: [.short, .customLong("publish")], help: "Publish ports (host:container)")
    var portSpecs: [String] = []

    @Option(name: [.short, .customLong("volume")], help: "Bind mount a volume (src:dst[:ro])")
    var volumeSpecs: [String] = []

    @Option(name: [.short, .customLong("env")], help: "Set environment variables (KEY=VALUE)")
    var env: [String] = []

    @Option(name: .customLong("label"), help: "Set metadata labels")
    var labels: [String] = []

    @Option(name: .customLong("network"), help: "Connect container to a network")
    var network: String?

    @Option(name: .customLong("cpus"), help: "Number of CPUs")
    var cpus: Int = 2

    @Option(name: .customShort("m"), help: "Memory limit in MB")
    var memory: UInt64 = 512

    @Option(name: .customLong("hostname"), help: "Container hostname")
    var hostname: String?

    @Option(name: [.short, .customLong("workdir")], help: "Working directory inside the container")
    var workdir: String?

    @Option(name: .customShort("u"), help: "Username or UID")
    var user: String?

    @Option(name: .customLong("restart"), help: "Restart policy (no|always|on-failure|unless-stopped)")
    var restart: String = "no"

    @Option(name: .customLong("cap-add"), help: "Add Linux capabilities")
    var capAdd: [String] = []

    @Option(name: .customLong("cap-drop"), help: "Drop Linux capabilities")
    var capDrop: [String] = []

    @Argument(help: "Image to run")
    var image: String

    @Argument(parsing: .remaining, help: "Command to run")
    var command: [String] = []

    mutating func run() async throws {
        var config = RunConfig(image: image, command: command)
        config.name = name
        config.detach = detach
        config.interactive = interactive
        config.tty = tty
        config.rm = rm
        config.ports = try portSpecs.map { try PortMapping.parse($0) }
        config.volumes = try volumeSpecs.map { try VolumeMount.parse($0) }
        config.env = try parseEnv(env)
        config.labels = try parseKV(labels)
        config.network = network
        config.cpuCount = cpus
        config.memoryMB = memory
        config.hostname = hostname
        config.workdir = workdir
        config.user = user
        config.restartPolicy = RestartPolicy(rawValue: restart) ?? .no
        config.capAdd = capAdd
        config.capDrop = capDrop

        let client = IPCClient()
        let request = try IPCRequest(type: .run, payload: RunRequest(config: config))
        let response = try await client.send(request)
        let result = try response.decode(RunResponse.self)

        if detach {
            print(result.containerID)
        } else {
            // Attach to container output
            let logsReq = LogsRequest(id: result.containerID, follow: true, tail: 0)
            let streamReq = try IPCRequest(type: .logs, payload: logsReq)
            try await client.sendStreaming(streamReq) { event in
                switch event.stream {
                case .stdout: print(event.data, terminator: "")
                case .stderr: fputs(event.data, stderr)
                default: break
                }
            }
        }
    }

    private func parseEnv(_ pairs: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
            } else if parts.count == 1 {
                // Inherit from current environment
                result[String(parts[0])] = ProcessInfo.processInfo.environment[String(parts[0])] ?? ""
            } else {
                throw CockerError.invalidEnvironmentVar(pair)
            }
        }
        return result
    }

    private func parseKV(_ pairs: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { throw CockerError.invalidEnvironmentVar(pair) }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }
}
