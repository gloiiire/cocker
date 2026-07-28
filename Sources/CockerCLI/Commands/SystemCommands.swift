import ArgumentParser
import CockerCore
import Foundation

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show the Cocker version information"
    )

    @Flag(name: [.short, .customLong("format")], help: "Format as JSON")
    var json = false

    mutating func run() async throws {
        // Best-effort daemon ping. Down/missing daemon is normal during
        // first install ; we just omit the server section.
        let daemonInfo: PingResponse? = await {
            let client = IPCClient()
            let req = try? IPCRequest(type: .ping, payload: EmptyPayload())
            guard let req else { return nil }
            return try? await client.send(req).decode(PingResponse.self)
        }()

        if json {
            struct VersionInfo: Codable {
                let client: ClientInfo
                let server: ServerInfo?
                struct ClientInfo: Codable {
                    let version, apiVersion, goVersion, gitCommit, buildTime, os, arch: String
                }
                struct ServerInfo: Codable {
                    let version, apiVersion, buildTime: String
                }
            }
            let info = VersionInfo(
                client: .init(
                    version: CockerVersion.version,
                    apiVersion: CockerVersion.apiVersion,
                    goVersion: "swift-6.2",
                    gitCommit: "HEAD",
                    buildTime: CockerVersion.buildTime,
                    os: "darwin",
                    arch: "arm64"
                ),
                server: daemonInfo.map {
                    .init(version: $0.version, apiVersion: $0.apiVersion, buildTime: $0.buildTime)
                }
            )
            let data = try JSONEncoder().encode(info)
            print(String(data: data, encoding: .utf8) ?? "")
            return
        }

        print("Client:")
        print("  Version:     \(CockerVersion.version)")
        print("  API version: \(CockerVersion.apiVersion)")
        print("  Built:       \(CockerVersion.buildTime)")
        print("  OS/Arch:     darwin/arm64")
        print("")
        if let s = daemonInfo {
            print("Server (cockerd):")
            print("  Version:     \(s.version)")
            print("  API version: \(s.apiVersion)")
            print("  Built:       \(s.buildTime)")
            print("  Engine:      Apple Virtualization.framework")
            if s.version != CockerVersion.version {
                UX.Warning.emit(
                    "client \(CockerVersion.version) ≠ daemon \(s.version)",
                    note: "some commands may behave unexpectedly until both halves are upgraded"
                )
            }
        } else {
            print("Server:        not reachable (cockerd not running ?)")
        }
    }
}

struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Display system-wide information"
    )

    mutating func run() async throws {
        let client = IPCClient()
        let request = try IPCRequest(type: .info, payload: EmptyPayload())
        let response = try await client.send(request)
        let info = try response.decode(InfoResponse.self)

        print("Containers: \(info.containers)")
        print(" Running:   \(info.containersRunning)")
        print(" Stopped:   \(info.containers - info.containersRunning)")
        print("Images:     \(info.images)")
        print("Volumes:    \(info.volumes)")
        print("Networks:   \(info.networks)")
        print("")
        print("Kernel:     \(info.kernelVersion)")
        print("Arch:       \(info.architecture)")
        print("CPUs:       \(info.cpus)")
        print("Memory:     \(formatBytes(info.totalMemory))")
        print("")
        print("Cocker Root: \(info.cockerRootDir)")
        print("Socket:      \(info.socketPath)")
    }
}

struct PruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system",
        abstract: "Manage Cocker",
        subcommands: [SystemPruneCommand.self, SystemInfoCommand.self, SystemEventsCommand.self, SystemDfCommand.self],
        aliases: ["s"]
    )
}

/// Shared prune logic. Two CLI surfaces invoke this :
///   1. `cocker system prune` (Docker-compatible path)
///   2. `cocker prune` (top-level shortcut, PRO-58 — same flags)
/// `--staging` (PRO-58) also wipes the iCloud staging cache used by
/// `cocker compose up`. The cache only exists for iCloud-resident
/// projects, so on a non-iCloud workflow the staging branch is a
/// no-op (clearCache returns 0 B reclaimed).
enum PruneRunner {
    static func run(force: Bool, volumes: Bool, staging: Bool) async throws {
        var extras: [String] = []
        if volumes { extras.append("unreferenced volumes") }
        if staging { extras.append("the iCloud staging cache") }
        // "containers and dangling images" + " AND volumes" → flat list ;
        // for two extras, " AND volumes AND the staging cache" reads
        // worse than " ; volumes ; and the staging cache" but only one
        // extra at a time is realistic for now so keep it simple.
        let suffix = extras.isEmpty ? "" : " and \(extras.joined(separator: ", and "))"
        let summary = "This will remove all stopped containers and dangling images\(suffix)."
        guard UX.Confirm.ask(summary: summary, force: force) else { return }

        let client = IPCClient()
        let request = try IPCRequest(type: .prune, payload: PruneRequest(volumes: volumes))
        let response = try await client.send(request)
        let result = try response.decode(PruneResponse.self)

        for c in result.containersDeleted { UX.printResult(.container, c, verb: .remove) }
        for i in result.imagesDeleted     { UX.printResult(.image, i, verb: .remove) }
        for v in result.volumesDeleted    { UX.printResult(.volume, v, verb: .remove) }

        // PRO-58 : staging happens host-side (the CLI has direct access
        // to ~/Library/Caches/cocker/staging), not via the daemon. Run it
        // after the daemon-side prune so the printed totals are
        // additive. The cache has no per-project listing surface, so we
        // print a single line rather than going through `printResult`
        // (which expects one named entity).
        var stagingFreed: UInt64 = 0
        if staging {
            stagingFreed = ICloudStaging.clearCache()
            if stagingFreed > 0 {
                print(" " + UX.TTY.paint("✓", .success)
                    + " iCloud staging cache cleared ("
                    + UX.formatBytes(Int64(stagingFreed)) + ")")
            }
        }

        let totalReclaimed = Int64(result.spaceReclaimed) + Int64(stagingFreed)
        let nothing = result.containersDeleted.isEmpty
            && result.imagesDeleted.isEmpty
            && result.volumesDeleted.isEmpty
            && stagingFreed == 0
        if nothing {
            print(" " + UX.TTY.paint("nothing to prune — 0 B reclaimed", .dim, [.italic]))
        } else {
            print(" " + UX.TTY.paint("reclaimed \(UX.formatBytes(totalReclaimed))", .dim))
        }
    }
}

struct SystemPruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Remove unused data")

    @Flag(name: [.short, .customLong("force")], help: "Do not prompt for confirmation")
    var force = false

    @Flag(name: [.short, .customLong("volumes")], help: "Also prune volumes")
    var volumes = false

    @Flag(name: .customLong("staging"), help: "Also wipe the iCloud staging cache used by `cocker compose up`")
    var staging = false

    mutating func run() async throws {
        try await PruneRunner.run(force: force, volumes: volumes, staging: staging)
    }
}

/// `cocker prune` — top-level shortcut to the same flow. Same flags,
/// same semantics. Exists because `cocker system prune` is buried
/// under `system` and most users expect a plain `prune` (PRO-58).
struct TopLevelPruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Remove unused data (alias for `cocker system prune`)"
    )

    @Flag(name: [.short, .customLong("force")], help: "Do not prompt for confirmation")
    var force = false

    @Flag(name: [.short, .customLong("volumes")], help: "Also prune volumes")
    var volumes = false

    @Flag(name: .customLong("staging"), help: "Also wipe the iCloud staging cache used by `cocker compose up`")
    var staging = false

    mutating func run() async throws {
        try await PruneRunner.run(force: force, volumes: volumes, staging: staging)
    }
}

struct SystemInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Display system-wide information")
    mutating func run() async throws {
        var cmd = InfoCommand()
        try await cmd.run()
    }
}

struct SystemDfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "df", abstract: "Show docker disk usage")

    mutating func run() async throws {
        let client = IPCClient()
        let request = try IPCRequest(type: .systemDf, payload: EmptyPayload())
        let response = try await client.send(request)
        let result = try response.decode(SystemDfResponse.self)

        let columns: [TableFormatter.Column] = [
            .init("TYPE", min: 12),
            .init("TOTAL", min: 8),
            .init("ACTIVE", min: 8),
            .init("SIZE", min: 12),
            .init("RECLAIMABLE", min: 16),
        ]

        let rows = result.entries.map { e -> [String] in
            let reclaim = e.reclaimable > 0 ? "\(formatBytes(e.reclaimable)) (\(e.total > 0 ? Int(Double(e.reclaimable) / Double(e.size) * 100) : 0)%)" : "0 B"
            return [e.type, "\(e.total)", "\(e.active)", formatBytes(e.size), reclaim]
        }

        if !rows.isEmpty { print(TableFormatter.format(columns: columns, rows: rows)) }
    }
}

struct SystemEventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "events", abstract: "Get real-time events from the server")

    @Option(name: .customLong("since"), help: "Show events since timestamp")
    var since: String?

    @Option(name: .customLong("filter"), help: "Filter events")
    var filter: [String] = []

    mutating func run() async throws {
        let client = IPCClient()
        let request = try IPCRequest(type: .events, payload: EmptyPayload())

        // Parse `--filter event=<action>` / `--filter type=<type>` /
        // `--filter container=<id-or-prefix>` ; only matching events
        // reach stdout. Mirrors `docker events --filter`.
        var actions: Set<String> = []
        var types: Set<String> = []
        var ids: Set<String> = []
        for f in filter {
            let parts = f.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "event": actions.insert(parts[1])
            case "type":  types.insert(parts[1])
            case "container": ids.insert(parts[1])
            default: break
            }
        }
        // Capture as constants so the Swift 6 sendable-closure check accepts
        // them — the closure is sendable but the loop above mutates the vars.
        let allowedActions = actions
        let allowedTypes = types
        let allowedIDs = ids

        let footer = InteractiveFooter()
        footer.armStreaming(footerLines(detachable: false))
        try await client.sendStreaming(request) { event in
            // Wire format engine→client : "<type>\t<action>\t<id>".
            let parts = event.data.split(separator: "\t", maxSplits: 2,
                                         omittingEmptySubsequences: false)
            let type = parts.count > 0 ? String(parts[0]) : ""
            let action = parts.count > 1 ? String(parts[1]) : event.data
            let id = parts.count > 2 ? String(parts[2]) : ""

            // `--filter event=health_status` matches against the colon-prefix
            // of action (`health_status: healthy` → `health_status`).
            let actionKey = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
            if !allowedActions.isEmpty && !allowedActions.contains(actionKey) { return }
            if !allowedTypes.isEmpty && !allowedTypes.contains(type) { return }
            if !allowedIDs.isEmpty && !allowedIDs.contains(where: { id.hasPrefix($0) }) { return }

            let ts = ISO8601DateFormatter().string(from: event.timestamp)
            print("\(ts) \(type) \(action)\(id.isEmpty ? "" : " " + id)")
        }
        footer.restore()
    }
}
