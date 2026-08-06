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

    @Option(name: .customLong("shm-size"),
            help: "Size of /dev/shm in MB (default: kernel — usually 64). Common values: 1024 for postgres, 2048 for chromium.")
    var shmSize: UInt64?

    @Option(name: .customLong("stop-signal"),
            help: "Signal to use on `cocker stop` before SIGKILL (default SIGTERM)")
    var stopSignal: String?

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

    @Flag(name: .customLong("privileged"), help: "Give extended privileges to this container")
    var privileged = false

    @Option(name: .customLong("env-file"), help: "Read environment variables from a file")
    var envFile: [String] = []

    @Option(name: .customLong("add-host"), help: "Add an entry to /etc/hosts (name:ip)")
    var addHosts: [String] = []

    @Option(name: .customLong("dns"), help: "Extra DNS server, consulted after cocker's own resolver")
    var dns: [String] = []

    @Option(name: .customLong("dns-search"), help: "DNS search domain (`cocker` stays appended)")
    var dnsSearch: [String] = []

    @Option(name: .customLong("volumes-from"), help: "Mount volumes from another container")
    var volumesFrom: [String] = []

    @Option(name: .customLong("tmpfs"), help: "Mount a tmpfs (e.g. /run or /run:size=64m)")
    var tmpfs: [String] = []

    @Flag(name: .customLong("read-only"), help: "Mount the container root read-only")
    var readOnly = false

    @Option(name: .customLong("health-cmd"), help: "Command to run to check health (CLI override)")
    var healthCmd: String?

    @Option(name: .customLong("health-interval"), help: "Time between healthchecks (e.g. 5s, 1m). Default 30s.")
    var healthInterval: String?

    @Option(name: .customLong("health-timeout"), help: "Per-check timeout (e.g. 3s, 1m). Default 30s.")
    var healthTimeout: String?

    @Option(name: .customLong("health-start-period"), help: "Grace window before failures count (e.g. 5s, 1m).")
    var healthStartPeriod: String?

    @Option(name: .customLong("health-retries"), help: "Consecutive failures before unhealthy.")
    var healthRetries: Int?

    @Flag(name: .customLong("no-healthcheck"), help: "Disable any healthcheck (overrides image HEALTHCHECK)")
    var noHealthcheck = false

    @Argument(help: "Image to run")
    var image: String

    /// Docker-style command capture : everything after the image name is
    /// the command, dashes and all. `.captureForPassthrough` is the
    /// ArgumentParser idiom that stops trying to parse flags from this
    /// point onward — without it, `cocker run alpine sh -c "..."` rejects
    /// `-c` as an unknown option of the `run` command itself.
    @Argument(parsing: .captureForPassthrough, help: "Command to run inside the container")
    var command: [String] = []

    mutating func run() async throws {
        // `cocker run alpine -- sh -c '...'` : the POSIX terminator is a
        // separator, not argv[0]. Left in place it reached the guest and
        // cocker-init exited 127 with `execvp --`.
        let command = CommandSeparator.strippingLeadingSeparator(self.command)
        var config = RunConfig(image: image, command: command)
        config.name = name
        config.detach = detach
        config.interactive = interactive
        config.tty = tty
        // `run -it` : the container's main process gets the console as a
        // controlling terminal, sized to the caller's window. Only when we
        // actually have a terminal to relay — piping into `run -t` would
        // otherwise put the guest in a tty it can never receive input from.
        if tty, let size = InteractiveSession.windowSize() {
            config.rows = size.rows
            config.cols = size.cols
        }
        config.rm = rm
        config.ports = try portSpecs.map { try PortMapping.parse($0) }
        config.volumes = try volumeSpecs.map { try VolumeMount.parse($0) }
        config.env = try parseEnv(env)
        config.labels = try parseKV(labels)
        config.network = network
        config.cpuCount = cpus
        config.memoryMB = memory
        config.shmSizeMB = shmSize
        config.stopSignal = stopSignal
        config.hostname = hostname
        config.workdir = workdir
        config.user = user
        config.restartPolicy = RestartPolicy(rawValue: restart) ?? .no
        config.capAdd = capAdd
        config.capDrop = capDrop
        config.privileged = privileged

        // Parse env files
        for file in envFile {
            let path = file.hasPrefix("/") ? file : FileManager.default.currentDirectoryPath + "/" + file
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in content.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                    let parts = trimmed.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        config.env[String(parts[0])] = String(parts[1])
                    } else {
                        config.env[trimmed] = ProcessInfo.processInfo.environment[trimmed] ?? ""
                    }
                }
            } else {
                fputs("Warning: env-file not found: \(file)\n", stderr)
            }
        }

        config.addHosts = addHosts
        config.dnsServers = dns
        config.dnsSearch = dnsSearch
        config.volumesFrom = volumesFrom
        config.tmpfsMounts = tmpfs
        config.readOnly = readOnly
        config.healthCmd = healthCmd
        config.healthInterval = healthInterval.flatMap(Self.parseDuration)
        config.healthTimeout = healthTimeout.flatMap(Self.parseDuration)
        config.healthStartPeriod = healthStartPeriod.flatMap(Self.parseDuration)
        config.healthRetries = healthRetries
        config.healthDisable = noHealthcheck

        let client = IPCClient()
        let request = try IPCRequest(type: .run, payload: RunRequest(config: config))
        let response = try await client.send(request)
        let result = try response.decode(RunResponse.self)

        if detach {
            print(result.containerID)
        } else {
            // Foreground : show a one-shot header (published URLs + `q` to
            // quit), then stream the container's logs. `q` / Ctrl-C detach the
            // viewer and restore the terminal ; the container keeps running.
            // Shared model with compose up / watch via UX.InteractiveFooter.
            let name = config.name ?? String(result.containerID.prefix(12))
            var header = [" " + UX.TTY.paint("→ Running", .progress) + " " + UX.TTY.paint(name, .accent)]
            for p in config.ports {
                // `localhost` is only where it actually answers when the bind
                // is every-interface or loopback. Printing it for a mapping
                // pinned to one LAN address sends the user to a closed port.
                let host = (p.hostIP == "0.0.0.0" || p.hostIP == "127.0.0.1")
                    ? "localhost" : p.hostIP
                header.append("   " + UX.TTY.paint("http://\(host):\(p.hostPort)", .accent))
            }
            let cid = result.containerID
            // `-it` hands the terminal to the container, so the footer must
            // not also be reading stdin. Two readers on one fd means the
            // footer's key handler steals bytes out of the middle of what the
            // user typed — verified on hardware: `exit` reached the shell as
            // `xit`. In interactive mode we show the header once and keep our
            // hands off the keyboard.
            let interactiveTTY = interactive && tty && InteractiveSession.stdinIsTerminal
            let footer = InteractiveFooter()
            // Pinned footer: the container URLs and the d/q hints stay
            // visible at the bottom while output scrolls above them.
            if interactiveTTY {
                // One-shot header, no key capture.
                for line in header { print(line) }
            } else {
            footer.start(
                footer: { footerLines(header: header, detach: true, quit: true) },
                onDetach: {
                    // `d` = detach : leave the container running, return the shell.
                    print(UX.TTY.paint("Detached.", .dim) + " "
                        + UX.TTY.paint("Container keeps running — `cocker logs -f \(name)` to follow, `cocker stop \(name)` to stop.", .dim))
                    return true
                },
                onQuit: {
                    // `q` / Ctrl-C = quit for real : stop the container.
                    if let req = try? IPCRequest(type: .stop, payload: ContainerIDRequest(id: cid)) {
                        _ = try? await IPCClient().send(req)
                    }
                    print("\n" + UX.TTY.paint("Stopped \(name).", .dim))
                },
                // Piped: no keyboard, so no key hints in the output.
                plainFallback: false)
            }

            // `-it` : relay the local terminal into the container's console.
            // Without this the container had a tty it could never be typed
            // into — `cocker run -it alpine sh` showed a prompt and ignored
            // every keystroke.
            let session: InteractiveSession? =
                interactiveTTY ? InteractiveSession(sessionID: result.containerID) : nil
            if let session {
                session.enterRawMode()
                session.startPump(containerStdin: true)
                session.startResizeWatcher()
                // The console is up as soon as the container is running;
                // there is no connect handshake to wait for here.
                session.markReady()
            }
            defer {
                session?.stop()
                session?.restore()
            }

            let view = StreamingLogView(footer: interactiveTTY ? nil : footer)
            let logsReq = LogsRequest(id: result.containerID, follow: true, tail: 0)
            let streamReq = try IPCRequest(type: .logs, payload: logsReq)
            try await client.sendStreaming(streamReq) { event in
                view.emit(event)
            }
            view.finish()
            session?.stop()
            session?.restore()
            footer.restore()

            // Docker parity : a foreground `run` exits with the container's
            // code. Without this the CLI always returned 0, so
            // `cocker run img false && echo ok` printed ok and every CI step
            // shelling out to cocker passed no matter what the container did.
            //
            // `.wait` rather than an inspect because `--rm` removes the
            // container the instant it stops — the daemon publishes the code
            // before the removal, so this is race-free where an inspect
            // would 404. Reaching here means the stream ended on its own :
            // `q` and `d` exit from inside the footer, above.
            let waitReq = try IPCRequest(type: .wait, payload: ContainerIDRequest(id: result.containerID))
            let waitResp = try await client.send(waitReq)
            let code = try waitResp.decode(WaitResponse.self).exitCode
            if code != 0 { throw ExitCode(code) }
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

    /// Parse Docker-style duration strings : "5s", "1m", "500ms", "2h". Plain
    /// integers are taken as seconds (matches docker behaviour). Returns nil
    /// on parse failure ; the CLI silently falls back to image defaults rather
    /// than aborting the run for a typo'd flag.
    static func parseDuration(_ s: String) -> TimeInterval? {
        let str = s.trimmingCharacters(in: .whitespaces).lowercased()
        if str.isEmpty { return nil }
        // Pure number → seconds
        if let n = Double(str) { return n }
        // Suffix-based
        let suffixes: [(String, Double)] = [
            ("ms", 0.001), ("us", 0.000001), ("ns", 0.000000001),
            ("s", 1), ("m", 60), ("h", 3600)
        ]
        for (suf, mult) in suffixes {
            if str.hasSuffix(suf) {
                let numPart = String(str.dropLast(suf.count))
                if let n = Double(numPart) { return n * mult }
            }
        }
        return nil
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
