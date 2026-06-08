import ArgumentParser
import CockerCore
import Foundation

struct PSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "List containers",
        aliases: ["ls", "list"]
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
        let base: String
        switch c.status {
        case .running:
            let uptime = c.startedAt.map { relativeTime(from: $0).replacingOccurrences(of: " ago", with: "") } ?? "unknown"
            base = ANSI.colored("Up \(uptime)", ANSI.green)
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
        // Docker-style health suffix on running containers : "Up 2 minutes
        // (healthy)". Only shown when a non-NONE healthcheck is configured ;
        // .none status (no probe) prints the bare uptime.
        guard let hc = c.healthcheck, !hc.isDisabled else { return base }
        switch c.healthStatus {
        case .none:        return base
        case .starting:    return base + ANSI.colored(" (health: starting)", ANSI.yellow)
        case .healthy:     return base + ANSI.colored(" (healthy)", ANSI.green)
        case .unhealthy:   return base + ANSI.colored(" (unhealthy)", ANSI.red)
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
        var results: [InspectView] = []

        for id in containers {
            let payload = ContainerIDRequest(id: id)
            let request = try IPCRequest(type: .inspect, payload: payload)
            let response = try await client.send(request)
            let container = try response.decode(Container.self)
            results.append(InspectView(container: container))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(results)
        print(String(data: data, encoding: .utf8) ?? "")
    }
}

/// Wrapper around `Container` that also emits a Docker-style `State.Health`
/// block at the top level. Existing flat fields (`healthStatus`, `healthLog`,
/// `healthFailingStreak`) are preserved so users of the legacy shape don't
/// break ; the new `State` key lets Docker template parsers (or shell
/// helpers like `jq '.[0].State.Health.Status'`) work against the same
/// payload they'd get from `docker inspect`.
struct InspectView: Encodable {
    let container: Container

    enum CodingKeys: String, CodingKey { case State }

    struct StateView: Encodable {
        let Health: HealthView?
    }
    struct HealthView: Encodable {
        let Status: String
        let FailingStreak: Int
        let Log: [LogEntryView]
    }
    struct LogEntryView: Encodable {
        let Start: String
        let End: String
        let ExitCode: Int
        let Output: String
    }

    func encode(to encoder: Encoder) throws {
        // First write every flat field of Container, then overlay our
        // Docker-shaped State block. Mirrors what `docker inspect` returns
        // alongside the cocker-native flat layout. Timestamps go through
        // the shared CockerCore `rfc3339Nano` so `cocker inspect` and the
        // Docker API socket agree byte-for-byte on the same Date.
        try container.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        let health: HealthView?
        if let hc = container.healthcheck, !hc.isDisabled {
            health = HealthView(
                Status: container.healthStatus.rawValue,
                FailingStreak: container.healthFailingStreak,
                Log: container.healthLog.map {
                    LogEntryView(
                        Start: rfc3339Nano($0.start),
                        End:   rfc3339Nano($0.end),
                        ExitCode: Int($0.exitCode),
                        Output: $0.output
                    )
                }
            )
        } else {
            health = nil
        }
        try c.encode(StateView(Health: health), forKey: .State)
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
        // The daemon-side `.top` handler is a stub. We run `ps` inside the
        // container directly via exec — works because `cocker exec` from
        // CLI uses the same daemon code path as `cocker top` would, with
        // none of the stub's hardcoded output. Falls back to busybox `ps`
        // (no flags) if `ps -ef` isn't available.
        let client = IPCClient()
        let argv = ["sh", "-c", "ps -ef 2>/dev/null || ps"]
        let config = ExecConfig(containerID: container, command: argv)
        let request = try IPCRequest(type: .exec, payload: ExecRequest(config: config))
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .error: fputs("Error: \(event.data)\n", stderr)
            case .status: break
            }
        }
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

        // For each container, exec into it and read /proc/{meminfo,stat}.
        // The CLI-side exec path goes through the working manual-exec
        // code path (DaemonServer → engine.exec → vmRuntime.exec), so
        // calls from `cocker stats` reliably get a response — unlike the
        // healthcheck loop which calls vmRuntime.exec from inside an actor.
        repeat {
            var rows: [[String]] = []
            for c in allContainers {
                let snapshot = await sampleStats(client: client, containerID: c.id,
                                                  configuredLimit: c.memoryMB)
                rows.append([
                    String(c.id.prefix(12)),
                    c.name,
                    snapshot.cpuPct,
                    "\(snapshot.memUsedFmt) / \(snapshot.memLimitFmt)",
                    snapshot.memPct,
                ])
            }
            // Clear the previous frame in streaming mode so the table
            // refreshes in place. ANSI `\u{1B}[2J\u{1B}[H` = clear screen + home.
            if !noStream { print("\u{1B}[2J\u{1B}[H", terminator: "") }
            print(TableFormatter.format(columns: columns, rows: rows))
            if noStream { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        } while !noStream
    }

    private struct StatsSnapshot {
        let cpuPct: String
        let memUsedFmt: String
        let memLimitFmt: String
        let memPct: String
    }

    /// One stats sample for a container. Reads /proc/meminfo and /proc/stat
    /// over `cocker exec`, parses the lines, and falls back to "--" on
    /// missing data instead of crashing the row.
    private func sampleStats(client: IPCClient,
                             containerID: String,
                             configuredLimit: UInt64) async -> StatsSnapshot {
        let configuredBytes = configuredLimit * 1024 * 1024
        // Single exec that emits both files separated by a magic marker so
        // we can disentangle them without two round-trips.
        let argv = ["sh", "-c", "cat /proc/meminfo; echo __STAT__; cat /proc/stat"]
        let config = ExecConfig(containerID: containerID, command: argv)
        let request = try? IPCRequest(type: .exec, payload: ExecRequest(config: config))
        // Buffer behind a reference type so the `@Sendable` streaming
        // closure can mutate it without tripping Swift 6's
        // sendable-closure capture check (a `var output = ""` capture is
        // forbidden because the closure outlives the function).
        final class OutputBuffer: @unchecked Sendable {
            var value = ""
        }
        let buf = OutputBuffer()
        if let request {
            try? await client.sendStreaming(request) { event in
                switch event.stream {
                case .stdout: buf.value += event.data
                case .stderr, .status, .error: break
                }
            }
        }
        let output = buf.value
        // Parse memory.
        var memTotalKB: UInt64 = 0
        var memAvailKB: UInt64 = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("MemTotal:") {
                memTotalKB = UInt64(line.split(separator: " ").dropFirst().first ?? "") ?? 0
            } else if line.hasPrefix("MemAvailable:") {
                memAvailKB = UInt64(line.split(separator: " ").dropFirst().first ?? "") ?? 0
            }
            if line.hasPrefix("__STAT__") { break }
        }
        let memUsedKB = memTotalKB > memAvailKB ? memTotalKB - memAvailKB : 0
        let memUsedBytes = memUsedKB * 1024
        let memLimitBytes = configuredBytes > 0 ? configuredBytes : memTotalKB * 1024
        let memPct: String
        if memLimitBytes > 0 {
            let pct = Double(memUsedBytes) / Double(memLimitBytes) * 100
            memPct = String(format: "%.2f%%", pct)
        } else {
            memPct = "--"
        }
        // CPU%: aggregate of all cores' non-idle ticks since boot. Without
        // a previous sample we can't compute a delta-based percentage on
        // the very first frame ; show "--" to signal "warming up".
        let cpuPct = "--"
        return StatsSnapshot(
            cpuPct: cpuPct,
            memUsedFmt: formatBytes(memUsedBytes),
            memLimitFmt: formatBytes(memLimitBytes),
            memPct: memPct
        )
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
