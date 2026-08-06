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

        let rows: [UX.Table.Row] = result.containers.map { c in
            let cmd = c.command.isEmpty ? "" : c.command.joined(separator: " ")
            let ports = c.ports.map { $0.description }.joined(separator: ", ")
            return .init([
                .init(String(c.id.prefix(12)), color: .accent),
                .init(c.image),
                .init(cmd.isEmpty ? "" : "\"\(cmd)\""),
                .init(relativeTime(from: c.createdAt), color: .dim),
                .init(Self.statusText(c), color: Self.statusColor(c)),
                .init(ports, color: .dim),
                .init(c.name),
            ])
        }
        let table = UX.Table(
            columns: [
                .init("CONTAINER ID", maxWidth: 12),
                .init("IMAGE", maxWidth: 40),
                .init("COMMAND", maxWidth: 30),
                .init("CREATED"),
                .init("STATUS"),
                .init("PORTS"),
                .init("NAMES"),
            ],
            rows: rows,
            emptyMessage: "no containers — run `cocker run <image>` to create one"
        )
        print(table.render())
    }

    /// Charter §5 status text (no ANSI). Color is applied by the
    /// containing UX.Table cell via `statusColor(_:)`.
    static func statusText(_ c: Container) -> String {
        let base: String
        switch c.status {
        case .running:
            let uptime = c.startedAt.map { relativeTime(from: $0).replacingOccurrences(of: " ago", with: "") } ?? "unknown"
            base = "Up \(uptime)"
        case .stopped:
            let code = c.exitCode.map { " (\($0))" } ?? ""
            return "Exited\(code)"
        case .created:    return "Created"
        case .paused:     return "Paused"
        case .restarting: return "Restarting"
        case .dead:       return "Dead"
        }
        // Docker-style health suffix on running containers. .none = no probe
        // configured, render the bare uptime.
        guard let hc = c.healthcheck, !hc.isDisabled else { return base }
        switch c.healthStatus {
        case .none:      return base
        case .starting:  return base + " (health: starting)"
        case .healthy:   return base + " (healthy)"
        case .unhealthy: return base + " (unhealthy)"
        }
    }

    /// Charter §5 STATUS column color mapping :
    ///   success → running (and healthy)
    ///   failure → exited with non-zero / dead
    ///   warn    → restarting / paused / unhealthy / health-starting
    ///   dim     → created / cleanly-stopped (exit 0)
    static func statusColor(_ c: Container) -> UX.Color {
        switch c.status {
        case .running:
            // Health override wins over the base "running == success".
            if let hc = c.healthcheck, !hc.isDisabled {
                switch c.healthStatus {
                case .unhealthy: return .warn
                case .starting:  return .warn
                case .healthy, .none: break
                }
            }
            return .success
        case .stopped:
            return (c.exitCode ?? -1) == 0 ? .dim : .failure
        case .created:    return .dim
        case .paused:     return .warn
        case .restarting: return .warn
        case .dead:       return .failure
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

    /// Docker-compatible `--format`. Supports field paths
    /// (`{{.State.Status}}`) and `{{json .X}}`. Without it, every script
    /// and helper written against `docker inspect --format` fails on
    /// cocker with "Unknown option".
    @Option(name: .customLong("format"),
            help: "Format output with a Go template, e.g. '{{.State.Status}}'")
    var format: String?

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

        // `--format` renders against the very JSON we would have printed,
        // so the two outputs can never disagree.
        if let format {
            let decoded = try JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
            // Docker renders one line per inspected object.
            let items = (decoded as? [Any]) ?? [decoded]
            for item in items {
                print(try GoTemplate.render(format, value: item))
            }
            return
        }
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

    enum CodingKeys: String, CodingKey { case State, NetworkSettings }

    struct StateView: Encodable {
        // Docker's canonical State block. `cocker inspect` used to expose
        // only Health here, so `{{.State.Status}}` — the single most common
        // template in scripts and health checks — resolved to nothing.
        let Status: String
        let Running: Bool
        let ExitCode: Int
        let StartedAt: String?
        let Health: HealthView?
    }
    /// Docker's network block. Scripts read `.NetworkSettings.IPAddress`
    /// to reach a container ; cocker only had the flat `cockerIP`.
    struct NetworkSettingsView: Encodable {
        let IPAddress: String
        let MacAddress: String
        let Gateway: String
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
        try c.encode(StateView(
            Status: container.status.rawValue,
            Running: container.status == .running,
            ExitCode: Int(container.exitCode ?? 0),
            StartedAt: container.startedAt.map(rfc3339Nano),
            Health: health
        ), forKey: .State)
        // `cockerIP` is the address reachable from other containers ; `ip`
        // is the NAT-side lease. Prefer the former, which is what a script
        // asking for `.NetworkSettings.IPAddress` wants to talk to.
        try c.encode(NetworkSettingsView(
            IPAddress: container.cockerIP ?? container.ip ?? "",
            MacAddress: container.cockerMAC ?? container.natMAC ?? "",
            Gateway: container.cockerIP != nil ? "10.42.0.1" : ""
        ), forKey: .NetworkSettings)
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
            case .stderr: UX.writeStderr(event.data)
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

    /// Parse the two /proc/stat snapshots out of one probe's output and
    /// turn them into a percentage. Returns "--" when the sample can't
    /// support an answer rather than inventing one.
    static func cpuPercent(from output: String) -> String {
        guard let marker = output.range(of: "__STAT2__") else { return "--" }
        let first = String(output[output.startIndex..<marker.lowerBound])
        let second = String(output[marker.upperBound...])

        // `cpu  <user> <nice> <system> <idle> <iowait> …` — the aggregate
        // line, distinguished from the per-core `cpu0`/`cpu1` lines by the
        // double space the kernel writes after it.
        func aggregate(_ text: String) -> (total: UInt64, idle: UInt64)? {
            for line in text.split(separator: "\n") where line.hasPrefix("cpu ") {
                let fields = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
                guard fields.count >= 5 else { return nil }
                let total = fields.reduce(0, &+)
                let idle = fields[3] &+ fields[4]   // idle + iowait
                return (total, idle)
            }
            return nil
        }
        func coreCount(_ text: String) -> Int {
            let n = text.split(separator: "\n").filter {
                $0.hasPrefix("cpu") && !$0.hasPrefix("cpu ")
            }.count
            return max(n, 1)
        }

        guard let a = aggregate(first), let b = aggregate(second),
              b.total > a.total else { return "--" }

        let totalDelta = b.total - a.total
        let idleDelta = b.idle >= a.idle ? b.idle - a.idle : 0
        let busy = totalDelta >= idleDelta ? totalDelta - idleDelta : 0
        let pct = Double(busy) / Double(totalDelta) * 100 * Double(coreCount(second))
        return String(format: "%.2f%%", pct)
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
        // Two /proc/stat reads a fifth of a second apart, in one round-trip.
        // CPU time in /proc/stat is cumulative since boot, so a single read
        // says nothing about *now* — which is why the column used to be a
        // permanent "--". Sampling both ends inside the guest keeps this to
        // one exec and makes the first frame as correct as the hundredth.
        let argv = ["sh", "-c",
                    "cat /proc/meminfo; echo __STAT__; cat /proc/stat; "
                    + "sleep 0.2; echo __STAT2__; cat /proc/stat"]
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
        // CPU%: the share of the interval the container's vCPUs spent doing
        // something. /proc/stat's `cpu` line is cumulative jiffies since
        // boot, so the figure comes from the delta between the two samples:
        //
        //     busy = (total₂ − total₁) − (idle₂ − idle₁)
        //     %    = busy / (total₂ − total₁) × 100 × ncpu
        //
        // idle covers `idle` + `iowait` — a core waiting on IO is not
        // running anything. Scaling by ncpu matches docker, where a
        // container saturating 4 cores reads 400%.
        //
        // "--" is kept for the cases where it is honest: no second sample
        // (the image has no `sleep`), or an interval so short the two reads
        // land on the same jiffy.
        let cpuPct = Self.cpuPercent(from: output)
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
