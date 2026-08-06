import ArgumentParser
import CockerCore
import Foundation

// All lifecycle commands route their successful result through
// UX.printResult so the user sees a colored action line in a TTY but
// scripts still get the bare ID on stdout. Errors go through
// UX.Failure.emit with a what/reason/hint shape ; we let the daemon's
// CockerError description carry the reason and add a hint where we can
// guess one. See docs/UX-CHARTER.md §4–6.

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start one or more stopped containers"
    )

    /// `docker start -a` streams the container's output until it exits.
    /// This flag existed here but was never read — it parsed fine and did
    /// nothing, which is worse than not offering it at all.
    @Flag(name: [.short, .customLong("attach")],
          help: "Attach STDOUT/STDERR and stream until the container exits")
    var attach = false

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        // Attaching to several containers at once would interleave two
        // unlabelled streams into one terminal ; docker rejects it too.
        if attach && containers.count > 1 {
            try UX.Failure.fail(
                headline: "--attach needs exactly one container",
                reason: "got \(containers.count)",
                hint: "use `cocker logs -f` to follow several containers at once")
        }

        let client = IPCClient()
        let failures = FailureCode()
        for id in containers {
            let start = Date()
            do {
                let request = try IPCRequest(type: .start, payload: ContainerIDRequest(id: id))
                _ = try await client.send(request)
                UX.printResult(.container, id, verb: .start, elapsed: Date().timeIntervalSince(start))

                // Stream the container's output, exactly like `docker start -a`.
                if attach {
                    // Pinned footer so the `d`/`q` hint stays visible under
                    // a stream that only ends when the container does.
                    let footer = InteractiveFooter()
                    footer.start(footer: { footerLines(detach: true) }, onDetach: { true },
                                 plainFallback: false)
                    let view = StreamingLogView(footer: footer)
                    let logsReq = try IPCRequest(
                        type: .logs,
                        payload: LogsRequest(id: id, follow: true, tail: 0))
                    try await client.sendStreaming(logsReq) { event in
                        view.emit(event)
                    }
                    view.finish()
                    footer.restore()
                }
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot start container \(id)",
                    reason: error.description,
                    hint: "check `cocker ps -a` to confirm it exists"
                )
            }
        }
        try failures.throwIfFailed()
    }
}

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Block until one or more containers stop, then print their exit codes"
    )

    @Argument(help: "Container ID(s) or name(s)")
    var containers: [String]

    mutating func run() async throws {
        let client = IPCClient()
        let failures = FailureCode()
        for id in containers {
            do {
                let request = try IPCRequest(type: .wait, payload: ContainerIDRequest(id: id))
                let response = try await client.send(request)
                // Docker prints one code per line and exits 0 itself — the
                // code is data here, not this command's own status.
                print(try response.decode(WaitResponse.self).exitCode)
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot wait on container \(id)",
                    reason: error.description,
                    hint: "check `cocker ps -a` to confirm it exists"
                )
            }
        }
        try failures.throwIfFailed()
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
        let failures = FailureCode()
        for id in containers {
            let start = Date()
            do {
                // `-t` was parsed and dropped; the grace period never left
                // the CLI.
                let request = try IPCRequest(type: .stop,
                                             payload: ContainerIDRequest(id: id,
                                                                         timeout: TimeInterval(timeout)))
                _ = try await client.send(request)
                UX.printResult(.container, id, verb: .stop, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot stop container \(id)",
                    reason: error.description,
                    hint: "use `cocker kill \(id)` to force-stop if needed"
                )
            }
        }
        try failures.throwIfFailed()
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
        let failures = FailureCode()
        for id in containers {
            let start = Date()
            do {
                let request = try IPCRequest(type: .kill, payload: ContainerIDRequest(id: id, signal: signal))
                _ = try await client.send(request)
                UX.printResult(.container, id, verb: .kill, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot kill container \(id)",
                    reason: error.description
                )
            }
        }
        try failures.throwIfFailed()
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
        let failures = FailureCode()
        for id in containers {
            let start = Date()
            do {
                let request = try IPCRequest(type: .restart,
                                             payload: ContainerIDRequest(id: id,
                                                                         timeout: TimeInterval(timeout)))
                _ = try await client.send(request)
                UX.printResult(.container, id, verb: .restart, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot restart container \(id)",
                    reason: error.description
                )
            }
        }
        try failures.throwIfFailed()
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
        let failures = FailureCode()
        for id in containers {
            let start = Date()
            do {
                let request = try IPCRequest(type: .pause, payload: ContainerIDRequest(id: id))
                _ = try await client.send(request)
                UX.printResult(.container, id, verb: .pause, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot pause container \(id)",
                    reason: error.description,
                    hint: "container must be running first — `cocker ps`"
                )
            }
        }
        try failures.throwIfFailed()
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
        let failures = FailureCode()
        for id in containers {
            let start = Date()
            do {
                let request = try IPCRequest(type: .unpause, payload: ContainerIDRequest(id: id))
                _ = try await client.send(request)
                UX.printResult(.container, id, verb: .unpause, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot unpause container \(id)",
                    reason: error.description
                )
            }
        }
        try failures.throwIfFailed()
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
        let failures = FailureCode()
        for id in containers {
            let start = Date()
            do {
                // `-v` was parsed and never sent, so anonymous volumes piled
                // up on disk with no way to reclaim them by name.
                let request = try IPCRequest(type: .rm,
                                             payload: ContainerIDRequest(id: id, force: force,
                                                                         removeVolumes: volumes))
                _ = try await client.send(request)
                UX.printResult(.container, id, verb: .remove, elapsed: Date().timeIntervalSince(start))
            } catch let error as CockerError {
                failures.record(error)
                UX.Failure.emit(
                    headline: "Cannot remove container \(id)",
                    reason: error.description,
                    hint: force ? nil : "use `--force` (-f) to remove a running container"
                )
            }
        }
        try failures.throwIfFailed()
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

    /// Parsed, sent, and never read: `ContainerEngine.logs` consults only
    /// `tail` and `follow`.
    @Option(name: .customLong("since"),
            help: "Not honoured: the whole retained buffer is returned")
    var since: String?

    @Argument(help: "Container ID or name")
    var container: String

    mutating func run() async throws {
        if since != nil {
            UX.IgnoredFlag.warn("--since",
                "logs are not filtered by time; the whole retained buffer is returned")
        }
        let client = IPCClient()
        let sinceDate = since.flatMap { ISO8601DateFormatter().date(from: $0) }
        let payload = LogsRequest(id: container, follow: follow, tail: tail, timestamps: timestamps, since: sinceDate)
        let request = try IPCRequest(type: .logs, payload: payload)

        let showTimestamps = timestamps
        // Uniform interactive hint : while following, `q` (or Ctrl-C) quits
        // the viewer and restores the terminal ; the container keeps running.
        // The footer stays pinned at the bottom while logs scroll above it.
        let footer = InteractiveFooter()
        let view = StreamingLogView(footer: footer)
        if follow {
            footer.start(footer: { footerLines(detach: true) }, onDetach: { true },
                                 plainFallback: false)
        }
        try await client.sendStreaming(request) { event in
            // stderr is painted dim red so the eye separates streams without
            // forcing the user to pipe to grep. Goes through UX.TTY.paint so
            // it stays plain text when redirected to a file.
            let kind: UX.StreamKind = (event.stream == .stderr) ? .stderr : .stdout
            let stamp = showTimestamps
                ? UX.TTY.paint(ISO8601DateFormatter().string(from: event.timestamp), .dim) + " "
                : ""
            view.emit(event) { stamp + UX.Stream.paint($0, stream: kind) }
        }
        view.finish()
        if follow { footer.restore() }
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
        // Same POSIX terminator rule as `run` : `cocker exec c -- sh -c ...`
        // must execute `sh`, not `--`.
        let command = CommandSeparator.strippingLeadingSeparator(self.command)
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
        // Live interactive session : raw mode locally, stdin streamed to the
        // daemon on a side channel, PTY allocated in the guest. This branch
        // used to print "typed input will not reach the container" and drop
        // the keystrokes on the floor.
        let session: InteractiveSession? =
            (interactive && InteractiveSession.stdinIsTerminal) ? InteractiveSession() : nil
        if let session {
            config.sessionID = session.sessionID
            if tty, let size = InteractiveSession.windowSize() {
                config.rows = size.rows
                config.cols = size.cols
            }
        }

        if interactive {
            if isatty(fileno(stdin)) == 1 {
                // Handled by the live session above — nothing to slurp.
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
                    UX.Warning.emit(
                        "stdin truncated at 64 MiB",
                        note: "use `cocker cp` for larger inputs"
                    )
                }
                if !collected.isEmpty {
                    config.stdin = collected
                }
            }
        }

        let client = IPCClient()
        let payload = ExecRequest(config: config)
        let request = try IPCRequest(type: .exec, payload: payload)

        // Docker parity : `cocker exec` exits with the command's code. The
        // `.status` event carrying `exit:<n>` used to be dropped here, so
        // `cocker exec c false` reported success.
        let status = ExitStatusBox()
        // Raw mode goes on before the first byte of output and comes off no
        // matter how we leave — a half-restored terminal is the worst
        // possible failure mode for an interactive command.
        // Read stdin from the start so nothing typed early is lost; the
        // pump holds it until the daemon reports its vsock is up.
        session?.enterRawMode()
        session?.startPump()
        defer {
            session?.stop()
            session?.restore()
        }
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: UX.writeStreamChunk(event.data)
            case .stderr: UX.writeStderr(event.data)
            case .status:
                if event.data == "exec-ready" { session?.markReady() }
                status.consume(statusPayload: event.data)
            case .error: UX.writeStderr(event.data)
            }
        }
        session?.stop()
        session?.restore()
        if status.code != 0 { throw ExitCode(status.code) }
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
        let start = Date()
        let containerLabel: String

        do {
            if let src = srcContainer {
                // Container -> host
                let payload = CpRequest(containerID: src, containerPath: srcPath, hostPath: dstPath, toContainer: false)
                let request = try IPCRequest(type: .cp, payload: payload)
                _ = try await client.send(request)
                containerLabel = src
            } else if let dst = dstContainer {
                // Host -> container
                let payload = CpRequest(containerID: dst, containerPath: dstPath, hostPath: srcPath, toContainer: true)
                let request = try IPCRequest(type: .cp, payload: payload)
                _ = try await client.send(request)
                containerLabel = dst
            } else {
                UX.Failure.emit(
                    headline: "cp needs a container path",
                    reason: "neither source nor destination starts with `<container>:`",
                    hint: "format : `cocker cp <container>:/src /host/dst` or `cocker cp /host/src <container>:/dst`"
                )
                // Usage error, not a daemon failure — plain 1.
                throw ExitCode.failure
            }
            UX.printResult(.container, containerLabel, verb: .copy, elapsed: Date().timeIntervalSince(start))
        } catch let error as CockerError {
            UX.Failure.emit(
                headline: "Cannot copy files",
                reason: error.description
            )
            throw ExitCode(error.exitCode)
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
        let start = Date()
        do {
            let request = try IPCRequest(type: .rename, payload: RenameRequest(id: container, newName: newName))
            _ = try await client.send(request)
            UX.printResult(.container, newName, verb: .rename, elapsed: Date().timeIntervalSince(start))
        } catch let error as CockerError {
            try UX.Failure.fail(
                headline: "Cannot rename container \(container)",
                reason: error.description,
                hint: "another container may already be named `\(newName)`"
            )
        }
    }
}

struct AttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach local STDIN/STDOUT/STDERR to a running container"
    )

    /// `attach` used to be read-only — cocker had no way to reach a running
    /// container's stdin, so this flag was documented as a no-op. It isn't
    /// one any more: a container started with `-t` has a console the host
    /// can write to, and `attach` now relays the local terminal into it.
    @Flag(name: .customLong("no-stdin"),
          help: "Do not forward STDIN (view the output only)")
    var noStdin = false

    @Argument(help: "Container ID or name")
    var container: String

    mutating func run() async throws {
        let client = IPCClient()

        // Only a container started with `-t` has a console the host can
        // write into. Attaching stdin to one that hasn't would silently
        // swallow every keystroke, so check first and stay read-only
        // otherwise.
        var containerHasTTY = false
        if !noStdin, InteractiveSession.stdinIsTerminal {
            let inspectReq = try IPCRequest(type: .inspect, payload: ContainerIDRequest(id: container))
            if let info = try? await client.send(inspectReq).decode(Container.self) {
                containerHasTTY = info.tty == true
            }
        }
        let interactive = containerHasTTY

        let payload = ContainerIDRequest(id: container)
        let request = try IPCRequest(type: .attach, payload: payload)

        // Attach holds the terminal until the container stops, so it gets
        // the same pinned footer as the other continuous viewers. Piped, the
        // footer is inert and this is a plain pass-through.
        //
        // Not in interactive mode though: the footer reads stdin for its
        // d/q keys, and two readers on one fd means it steals bytes out of
        // the middle of what the user typed. The container owns the terminal.
        let footer = InteractiveFooter()
        if !interactive {
            footer.start(footer: { footerLines(detach: true) }, onDetach: { true },
                         plainFallback: false)
        }
        let session: InteractiveSession? =
            interactive ? InteractiveSession(sessionID: container) : nil
        if let session {
            session.enterRawMode()
            session.startPump(containerStdin: true)
            // The console is already up — nothing to hand-shake with.
            session.markReady()
        }
        defer {
            session?.stop()
            session?.restore()
        }
        let view = StreamingLogView(footer: interactive ? nil : footer)

        let fail = UX.FailFlag()
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout, .stderr:
                view.emit(event)
            case .status:
                if !event.data.isEmpty { view.emitLine(event.data) }
            case .error:
                fail.trip()
                footer.clear()
                UX.Failure.emit(headline: event.data)
            }
        }
        view.finish()
        session?.stop()
        session?.restore()
        footer.restore()
        try fail.throwIfTripped()
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
        guard UX.Confirm.ask(
            summary: "This will remove all stopped containers.",
            force: force
        ) else { return }

        let client = IPCClient()
        let request = try IPCRequest(type: .containerPrune, payload: EmptyPayload())
        let response = try await client.send(request)
        let result = try response.decode(PruneResponse.self)

        if result.containersDeleted.isEmpty {
            print(" " + UX.TTY.paint("nothing to prune — 0 B reclaimed", .dim, [.italic]))
        } else {
            for id in result.containersDeleted {
                UX.printResult(.container, id, verb: .remove)
            }
            let summary = "reclaimed \(UX.formatBytes(Int64(result.spaceReclaimed)))"
            print(" " + UX.TTY.paint(summary, .dim))
        }
    }
}
