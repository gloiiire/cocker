import ArgumentParser
import CockerCore
import Foundation

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start one or more stopped containers"
    )

    @Flag(name: [.short, .customLong("attach")], help: "Attach STDOUT/STDERR")
    var attach = false

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for id in containers {
            let payload = ContainerIDRequest(id: id)
            let request = try IPCRequest(type: .start, payload: payload)
            _ = try await client.send(request)
            print(id)
        }
    }
}

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop one or more running containers"
    )

    @Option(name: .customShort("t"), help: "Seconds to wait before killing")
    var timeout: Int = 10

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for id in containers {
            let payload = ContainerIDRequest(id: id)
            let request = try IPCRequest(type: .stop, payload: payload)
            _ = try await client.send(request)
            print(id)
        }
    }
}

struct KillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Kill one or more running containers"
    )

    @Option(name: [.short, .customLong("signal")], help: "Signal to send (default SIGKILL)")
    var signal: String = "SIGKILL"

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for id in containers {
            let payload = ContainerIDRequest(id: id, signal: signal)
            let request = try IPCRequest(type: .kill, payload: payload)
            _ = try await client.send(request)
            print(id)
        }
    }
}

struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart one or more containers"
    )

    @Option(name: .customShort("t"), help: "Seconds to wait before killing")
    var timeout: Int = 10

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for id in containers {
            let payload = ContainerIDRequest(id: id)
            let request = try IPCRequest(type: .restart, payload: payload)
            _ = try await client.send(request)
            print(id)
        }
    }
}

struct PauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "Pause all processes within container(s)"
    )

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for id in containers {
            let payload = ContainerIDRequest(id: id)
            let request = try IPCRequest(type: .pause, payload: payload)
            _ = try await client.send(request)
            print(id)
        }
    }
}

struct UnpauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpause",
        abstract: "Unpause all processes within container(s)"
    )

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for id in containers {
            let payload = ContainerIDRequest(id: id)
            let request = try IPCRequest(type: .unpause, payload: payload)
            _ = try await client.send(request)
            print(id)
        }
    }
}

struct RmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove one or more containers"
    )

    @Flag(name: [.short, .customLong("force")], help: "Force removal of a running container")
    var force = false

    @Flag(name: [.short, .customLong("volumes")], help: "Remove anonymous volumes")
    var volumes = false

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        for id in containers {
            let payload = ContainerIDRequest(id: id, force: force)
            let request = try IPCRequest(type: .rm, payload: payload)
            do {
                _ = try await client.send(request)
                print(id)
            } catch let error as CockerError {
                fputs("Error: \(error.description)\n", stderr)
            }
        }
    }
}

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Fetch the logs of a container"
    )

    @Flag(name: [.short, .customLong("follow")], help: "Follow log output")
    var follow = false

    @Option(name: .customLong("tail"), help: "Number of lines to show from end (default 100)")
    var tail: Int = 100

    @Flag(name: [.short, .customLong("timestamps")], help: "Show timestamps")
    var timestamps = false

    @Option(name: .customLong("since"), help: "Show logs since timestamp (RFC3339)")
    var since: String?

    @Argument(help: "Container ID or name")
    var container: String

    mutating func run() async throws {
        let client = IPCClient()
        let sinceDate = since.flatMap { ISO8601DateFormatter().date(from: $0) }
        let payload = LogsRequest(id: container, follow: follow, tail: tail, timestamps: timestamps, since: sinceDate)
        let request = try IPCRequest(type: .logs, payload: payload)

        let showTimestamps = timestamps
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout:
                if showTimestamps {
                    let ts = ISO8601DateFormatter().string(from: event.timestamp)
                    print("\(ANSI.colored(ts, ANSI.dim)) \(event.data)", terminator: "")
                } else {
                    print(event.data, terminator: "")
                }
            case .stderr:
                if showTimestamps {
                    let ts = ISO8601DateFormatter().string(from: event.timestamp)
                    fputs("\(ts) \(event.data)", stderr)
                } else {
                    fputs(event.data, stderr)
                }
            default: break
            }
        }
    }
}

struct ExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a command in a running container"
    )

    @Flag(name: [.short, .customLong("interactive")], help: "Keep STDIN open")
    var interactive = false

    @Flag(name: .customShort("t"), help: "Allocate a pseudo-TTY")
    var tty = false

    @Option(name: .customShort("u"), help: "Username or UID")
    var user: String?

    @Option(name: [.short, .customLong("workdir")], help: "Working directory")
    var workdir: String?

    @Option(name: [.short, .customLong("env")], help: "Set environment variables")
    var env: [String] = []

    @Argument(help: "Container ID or name")
    var container: String

    /// Docker-style capture : everything after the container name belongs
    /// to the in-VM command. `.captureForPassthrough` prevents
    /// ArgumentParser from rejecting dashes like
    /// `cocker exec my-c sh -c "echo hi"` as unknown flags of `exec`.
    @Argument(parsing: .captureForPassthrough, help: "Command to execute inside the container")
    var command: [String]

    mutating func run() async throws {
        var config = ExecConfig(containerID: container, command: command)
        config.interactive = interactive
        config.tty = tty
        config.user = user
        config.workdir = workdir
        // Parse --env KEY=VALUE pairs into the config's env dict. Without
        // this, `cocker exec --env FOO=bar c sh -c 'echo $FOO'` silently
        // dropped the variable instead of injecting it into the child env.
        for entry in env {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                config.env[parts[0]] = parts[1]
            } else if parts.count == 1 {
                // Bare KEY passthrough — take the daemon's value.
                config.env[parts[0]] = ProcessInfo.processInfo.environment[parts[0]] ?? ""
            }
        }

        // Drain piped / redirected stdin into a one-shot blob the daemon
        // will forward onto the in-VM child. Three cases :
        //   1. `-i` set + stdin is NOT a TTY (pipe / file / heredoc) :
        //      slurp until EOF and stash in `config.stdin`. Caps at
        //      64 MiB to avoid runaway `< /dev/zero`.
        //   2. `-i` set + stdin IS a TTY (user typing) : we can't do
        //      real-time interactive yet (needs duplex IPC + PTY relay).
        //      Print a clear warning and leave stdin empty.
        //   3. `-i` not set : skip stdin handling entirely.
        if interactive {
            if isatty(fileno(stdin)) == 1 {
                fputs("Warning: live interactive stdin (TTY) isn't supported yet — pipe input via `echo … | cocker exec -i …` or file redirection. For now your typed input will not reach the container.\n",
                      stderr)
            } else {
                let maxBytes = 64 * 1024 * 1024
                var collected = Data()
                var buf = [UInt8](repeating: 0, count: 64 * 1024)
                while collected.count < maxBytes {
                    let n = read(fileno(stdin), &buf, buf.count)
                    if n <= 0 { break }
                    collected.append(contentsOf: buf.prefix(Int(n)))
                }
                if collected.count >= maxBytes {
                    fputs("Warning: stdin truncated at 64 MiB. Use `cocker cp` for larger inputs.\n",
                          stderr)
                }
                if !collected.isEmpty {
                    config.stdin = collected
                }
            }
        }

        let client = IPCClient()
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

struct CpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy files/folders between container and local filesystem"
    )

    @Argument(help: "Source path ([container:]path)")
    var source: String

    @Argument(help: "Destination path ([container:]path)")
    var destination: String

    mutating func run() async throws {
        func parseArg(_ arg: String) -> (String?, String) {
            let parts = arg.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { return (String(parts[0]), String(parts[1])) }
            return (nil, arg)
        }

        let (srcContainer, srcPath) = parseArg(source)
        let (dstContainer, dstPath) = parseArg(destination)

        let client = IPCClient()

        if let src = srcContainer {
            // Container -> host
            let payload = CpRequest(containerID: src, containerPath: srcPath, hostPath: dstPath, toContainer: false)
            let request = try IPCRequest(type: .cp, payload: payload)
            _ = try await client.send(request)
        } else if let dst = dstContainer {
            // Host -> container
            let payload = CpRequest(containerID: dst, containerPath: dstPath, hostPath: srcPath, toContainer: true)
            let request = try IPCRequest(type: .cp, payload: payload)
            _ = try await client.send(request)
        } else {
            fputs("Error: At least one of source or destination must be a container path (container:path)\n", stderr)
            throw ExitCode.failure
        }
    }
}

struct RenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a container"
    )

    @Argument(help: "Container ID or current name")
    var container: String

    @Argument(help: "New name")
    var newName: String

    mutating func run() async throws {
        let client = IPCClient()
        let payload = RenameRequest(id: container, newName: newName)
        let request = try IPCRequest(type: .rename, payload: payload)
        _ = try await client.send(request)
        print(newName)
    }
}

struct AttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach local STDIN/STDOUT/STDERR to a running container"
    )

    @Flag(name: .customLong("no-stdin"), help: "Do not attach STDIN")
    var noStdin = false

    @Argument(help: "Container ID or name")
    var container: String

    mutating func run() async throws {
        let client = IPCClient()
        let payload = ContainerIDRequest(id: container)
        let request = try IPCRequest(type: .attach, payload: payload)

        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status:
                if !event.data.isEmpty { print(event.data, terminator: "") }
            case .error: fputs("Error: \(event.data)\n", stderr)
            }
        }
    }
}

struct ContainerPruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container",
        abstract: "Manage containers",
        subcommands: [ContainerPruneSubcommand.self]
    )
}

struct ContainerPruneSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Remove all stopped containers"
    )

    @Flag(name: [.short, .customLong("force")], help: "Do not prompt for confirmation")
    var force = false

    mutating func run() async throws {
        if !force {
            print("WARNING! This will remove all stopped containers.")
            print("Are you sure you want to continue? [y/N] ", terminator: "")
            let answer = readLine()?.lowercased() ?? "n"
            guard answer == "y" || answer == "yes" else { return }
        }

        let client = IPCClient()
        let request = try IPCRequest(type: .containerPrune, payload: EmptyPayload())
        let response = try await client.send(request)
        let result = try response.decode(PruneResponse.self)

        if result.containersDeleted.isEmpty {
            print("Total reclaimed space: 0 B")
        } else {
            print("Deleted Containers:")
            result.containersDeleted.forEach { print($0) }
            print("Total reclaimed space: \(formatBytes(result.spaceReclaimed))")
        }
    }
}
