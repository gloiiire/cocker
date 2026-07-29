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
            ComposeWatchCommand.self,
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
        let originalPath = resolvePath(file)
        guard FileManager.default.fileExists(atPath: originalPath) else {
            throw CockerError.invalidComposeFile("File not found: \(originalPath)")
        }

        // iCloud Drive paths trigger EDEADLK ("Resource deadlock avoided")
        // inside cockerd for every COPY past the first one — iCloud's
        // `bird` daemon serializes file access in a way that deadlocks with
        // cockerd's Swift concurrency runtime. The CLI runs as a regular
        // user process and DOES have working iCloud access, so we stage
        // the whole compose project dir to /tmp here, then point cockerd
        // at the staged copy.
        // Staging is cached at ~/Library/Caches/cocker/staging/<hash> so
        // re-runs are incremental (rsync diffs the iCloud source). Bind
        // mounts in compose services keep referencing the staged source
        // for the lifetime of the container — that's why the staging
        // dir is persistent, not /tmp ephemeral.
        let stage = try await ICloudStaging.stageIfNeeded(originalPath: originalPath) { msg in
            // Charter §12 — name the macOS daemon (bird) explicitly so the
            // operator understands what's delaying their first compose up.
            print(" " + UX.TTY.paint("→ bird (iCloud) " + msg, .progress))
        }

        // If we staged to /tmp, ComposeEngine would infer the project name
        // from the staging dir's parent (something like
        // `cocker-compose-stage-<UUID>`). Pin the project name to the
        // ORIGINAL compose-file dir basename so containers/networks land
        // under the user-recognizable name.
        let effectiveProjectName = ProjectName.normalize(projectName
            ?? URL(fileURLWithPath: originalPath).deletingLastPathComponent().lastPathComponent)

        let client = IPCClient()
        let payload = ComposeRequest(
            composePath: stage.path,
            projectName: effectiveProjectName,
            services: services,
            detach: detach,
            forceBuild: build
        )
        let request = try IPCRequest(type: .composeUp, payload: payload)

        // Charter §13.1 — sticky multi-line table in TTY mode (one row per
        // network/volume/container with live status + per-resource timer),
        // chronological passthrough otherwise (CI, pipes, logs).
        let view: UX.ComposeUpView? = UX.TTY.current.animationEnabled ? UX.ComposeUpView() : nil
        // Start the repaint loop before the first event : the daemon can
        // spend minutes inside one RUN without emitting anything, and a
        // view that only repaints on events freezes mid-frame.
        view?.startAnimating()
        // A `.error` stream event reports a build/start failure the stream
        // doesn't itself throw for — latch it and fail after draining so
        // `compose up` doesn't exit 0 on a broken build. See PRO-76.
        let fail = UX.FailFlag()

        // `-d` short-circuits the interactive footer : the user explicitly
        // asked for background mode, so we just stream the build / start
        // progress and exit when the daemon says it's done.
        if detach {
            do {
                try await client.sendStreaming(request) { event in
                    if case .error = event.stream { fail.trip() }
                    if let view {
                        view.ingest(stream: event.stream, line: event.data)
                    } else {
                        renderComposeEvent(event)
                    }
                }
            } catch {
                // Flush the sticky view's buffered build output (the real
                // RUN failure) BEFORE the error propagates — otherwise a
                // failed build shows only the one-line headline and the
                // actual cause is lost. See PRO-76.
                view?.finalize()
                throw error
            }
            view?.finalize()
            try fail.throwIfTripped()
            return
        }

        // Foreground mode : stream the up sequence, then hold the terminal
        // with a sticky footer (service URLs + `q` to quit) — the same model
        // as compose watch / run, via UX.InteractiveFooter. Quitting leaves
        // the containers running (cocker never tears them down on CLI exit).
        // Off-TTY the footer prints once and we return immediately.
        let urls = ServiceURLs()
        do {
            try await client.sendStreaming(request) { event in
                if case .error = event.stream { fail.trip() }
                if case .stdout = event.stream { urls.capture(fromStdout: event.data) }
                if let view {
                    view.ingest(stream: event.stream, line: event.data)
                } else {
                    renderComposeEvent(event)
                }
            }
        } catch {
            view?.finalize()  // flush buffered build output before the error surfaces (PRO-76)
            throw error
        }
        view?.finalize()
        try fail.throwIfTripped()

        let proj = effectiveProjectName
        let downPath = stage.path
        let downProj = effectiveProjectName
        let footer = InteractiveFooter()
        footer.start(
            footer: {
                footerLines(
                    header: [" " + UX.TTY.paint("→ Running", .progress) + " " + UX.TTY.paint(proj, .accent)],
                    services: urls.snapshot(),
                    detach: true, quit: true)
            },
            onDetach: {
                // `d` = detach : leave the containers running, return the shell.
                print(UX.TTY.paint("Detached.", .dim) + " "
                    + UX.TTY.paint("Containers keep running — `cocker compose logs -f` to follow, `cocker compose down` to stop.", .dim))
                return true
            },
            onQuit: {
                // `q` / Ctrl-C = quit for real : tear the project down.
                if let req = try? IPCRequest(type: .composeDown,
                                             payload: ComposeRequest(composePath: downPath, projectName: downProj)) {
                    _ = try? await IPCClient().send(req)
                }
                print("\n" + UX.TTY.paint("Stopped and removed the project.", .dim))
            })
        // Hold the terminal so the footer stays attached ; the key task exits
        // the process on `q` / Ctrl-C. Off-TTY we don't hold.
        if footer.animated {
            while true { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
    }

}

/// Shared event renderer for compose streaming output. Free function so
/// it can be captured by `@Sendable` closures without dragging the
/// enclosing `mutating` command struct in.
private func renderComposeEvent(_ event: StreamEvent) {
    switch event.stream {
    case .stdout: print(event.data, terminator: "")
    case .stderr: fputs(event.data, stderr)
    case .status: print(UX.TTY.paint(event.data, .progress))
    case .error:  UX.Failure.emit(headline: event.data)
    }
}

// ICloudStaging lives in Sources/CockerCLI/ICloudStaging.swift now ; the
// implementation grew enough optimizations (stable cache dir, brctl
// pre-fetch, xattr-based detection, .cockerignore support) that it
// deserved its own file and reuse from BuildCommand.

struct ComposeDownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Stop and remove containers, networks")

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Flag(name: [.customShort("v"), .customLong("volumes")], help: "Remove named volumes")
    var removeVolumes = false

    @Flag(name: .customLong("remove-orphans"), help: "Remove orphaned containers")
    var removeOrphans = false

    mutating func run() async throws {
        let composePath = resolvePath(file)
        let client = IPCClient()
        let payload = ComposeRequest(
            composePath: composePath,
            projectName: projectName,
            removeVolumes: removeVolumes
        )
        let request = try IPCRequest(type: .composeDown, payload: payload)
        _ = try await client.send(request)
        print("Compose project stopped and removed.")
        if removeVolumes {
            print("Named volumes removed.")
        }
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

        let rows: [UX.Table.Row] = result.projects.map { p in
            .init([
                .init(p.name),
                .init(p.status, color: p.status.lowercased().contains("run") ? .success : .dim),
                .init(p.configFiles, color: .dim),
                .init("\(p.servicesCount)", color: .accent),
            ])
        }
        let table = UX.Table(
            columns: [
                .init("NAME"),
                .init("STATUS"),
                .init("CONFIG FILES"),
                .init("SERVICES", align: .right),
            ],
            rows: rows,
            emptyMessage: "no compose projects — run `cocker compose up` to start one"
        )
        print(table.render())
    }
}

struct ComposeLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "View output from containers")

    @Flag(name: [.short, .customLong("follow")], help: "Follow log output")
    var follow = false

    // `--file` has no short alias on `logs` — `-f` is reserved for
    // `--follow` here (matches docker compose). Other subcommands keep
    // `-f / --file` because they don't take a `--follow` flag.
    @Option(name: .customLong("file"), help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Option(name: .customLong("tail"),
            help: "Number of lines to show from the end of the logs (default 50)")
    var tail: Int = 50

    @Argument(help: "Services to show logs for (default: all)")
    var services: [String] = []

    mutating func run() async throws {
        let composePath = resolvePath(file)
        // Default project name to the cwd basename when --project-name is
        // omitted, so `cocker compose logs` from the project dir Just
        // Works without arguments — matches docker compose's behavior.
        let effectiveProjectName = ProjectName.normalize(projectName
            ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent)

        let client = IPCClient()
        let payload = ComposeRequest(
            composePath: composePath,
            projectName: effectiveProjectName,
            services: services,
            follow: follow,
            tail: tail
        )
        let request = try IPCRequest(type: .composeLogs, payload: payload)

        let footer = InteractiveFooter()
        if follow { footer.armStreaming(footerLines(detach: true), onDetach: { true }) }
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            default: break
            }
        }
        if follow { footer.restore() }
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
        let project = ProjectName.normalize(projectName ?? URL(fileURLWithPath: resolvePath(file))
            .deletingLastPathComponent().lastPathComponent)

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
        let rows = containers.map { c -> [String] in
            // Match `docker compose ps` : status suffixed with health
            // when a non-NONE healthcheck is configured.
            var statusStr = c.status.rawValue
            if let hc = c.healthcheck, !hc.isDisabled {
                switch c.healthStatus {
                case .healthy:   statusStr += " (healthy)"
                case .unhealthy: statusStr += " (unhealthy)"
                case .starting:  statusStr += " (health: starting)"
                case .none:      break
                }
            }
            return [
                c.name, c.image, statusStr,
                c.ports.map { $0.description }.joined(separator: ", "),
            ]
        }
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

    @Argument(parsing: .captureForPassthrough, help: "Command to execute")
    var command: [String]

    mutating func run() async throws {
        // Same POSIX terminator rule as `cocker exec` : a leading `--`
        // separates flags from the command, it is not the command.
        let command = CommandSeparator.strippingLeadingSeparator(self.command)
        let composePath = resolvePath(file)
        let pName = ProjectName.normalize(projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent)
        let containerName = "\(pName)_\(service)_1"

        let client = IPCClient()
        // Find the container by name
        let psPayload = PSRequest(all: false, filter: ["name": containerName])
        let psRequest = try IPCRequest(type: .ps, payload: psPayload)
        let psResponse = try await client.send(psRequest)
        let containers = try psResponse.decode(PSResponse.self).containers

        guard let container = containers.first else {
            UX.Failure.emit(
                headline: "Cannot exec into service \(service)",
                reason: "no container found for project '\(pName)'",
                hint: "run `cocker compose ps` to see live services"
            )
            throw ExitCode.failure
        }

        var config = ExecConfig(containerID: container.id, command: command)
        config.tty = !noTTY
        config.env = container.env
        config.workdir = container.env["WORKDIR"]
        config.user = container.env["USER"]
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

        let fail = UX.FailFlag()
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status: print(UX.TTY.paint(event.data, .progress))
            case .error:  fail.trip(); UX.Failure.emit(headline: event.data)
            }
        }
        try fail.throwIfTripped()
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
        let payload = ComposeRequest(composePath: composePath, projectName: projectName,
                                     services: services, noCache: noCache)
        let request = try IPCRequest(type: .composeBuild, payload: payload)

        let fail = UX.FailFlag()
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status: print(UX.TTY.paint(event.data, .progress))
            case .error:  fail.trip(); UX.Failure.emit(headline: event.data)
            }
        }
        try fail.throwIfTripped()
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

        let fail = UX.FailFlag()
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status: print(UX.TTY.paint(event.data, .progress))
            case .error:  fail.trip(); UX.Failure.emit(headline: event.data)
            }
        }
        try fail.throwIfTripped()
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
        let pName = ProjectName.normalize(projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent)
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
        let pName = ProjectName.normalize(projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent)
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
            UX.Failure.emit(
                headline: "Compose file not found",
                reason: "no file at \(composePath)",
                hint: "pass `-f <path>` or run from a directory containing cocker-compose.yml"
            )
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
        let pName = ProjectName.normalize(projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent)
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
        let pName = ProjectName.normalize(projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent)
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
        let pName = ProjectName.normalize(projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent)
        let client = IPCClient()

        let psPayload = PSRequest(all: false, filter: ["label": "com.cocker.project=\(pName)"])
        let psReq = try IPCRequest(type: .ps, payload: psPayload)
        let psResp = try await client.send(psReq)
        let allContainers = try psResp.decode(PSResponse.self).containers

        guard let container = allContainers.first(where: { $0.labels["com.cocker.service"] == service }) else {
            UX.Failure.emit(
                headline: "Cannot resolve port for service \(service)",
                reason: "no running container in project '\(pName)'",
                hint: "run `cocker compose ps` to see live services"
            )
            throw ExitCode.failure
        }

        guard let port = UInt16(privatePort) else {
            UX.Failure.emit(
                headline: "Invalid port: \(privatePort)",
                reason: "must be a TCP/UDP port number between 1 and 65535"
            )
            throw ExitCode.failure
        }

        if let mapping = container.ports.first(where: { $0.containerPort == port && $0.proto.rawValue == proto }) {
            print("0.0.0.0:\(mapping.hostPort)")
        } else {
            UX.Failure.emit(
                headline: "Port \(privatePort)/\(proto) not published for service \(service)",
                reason: "this container has no host-side mapping for that port",
                hint: "check the service's `ports:` block in your compose file"
            )
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
        let pName = ProjectName.normalize(projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent)
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
        let pName = ProjectName.normalize(projectName ?? URL(fileURLWithPath: composePath).deletingLastPathComponent().lastPathComponent)
        let client = IPCClient()
        let request = try IPCRequest(type: .events, payload: EmptyPayload())
        let outputJSON = json

        let footer = InteractiveFooter()
        if !outputJSON { footer.armStreaming(footerLines(detach: true), onDetach: { true }) }
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
        if !outputJSON { footer.restore() }
    }
}

private func resolvePath(_ path: String) -> String {
    let abs = path.hasPrefix("/") ? path
        : FileManager.default.currentDirectoryPath + "/" + path
    // If the user is using the default `cocker-compose.yml` but the file
    // doesn't exist, fall back to the Docker-native filenames so that
    // existing projects work out of the box. Order matches Docker Compose's
    // own precedence (compose.yaml first since v2).
    if !FileManager.default.fileExists(atPath: abs)
        && path == "cocker-compose.yml" {
        let cwd = FileManager.default.currentDirectoryPath
        for candidate in ["compose.yaml", "compose.yml",
                          "docker-compose.yaml", "docker-compose.yml"] {
            let p = cwd + "/" + candidate
            if FileManager.default.fileExists(atPath: p) { return p }
        }
    }
    return abs
}
