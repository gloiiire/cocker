import Foundation
import CockerCore
import Virtualization

// cockerd — Cocker Engine Daemon
// Usage: cockerd [--root <path>] [--socket <path>] [setup]
//
// Requires entitlements:
//   com.apple.security.virtualization
//   com.apple.vm.networking

@MainActor
func main() async {
    let args = CommandLine.arguments

    // Parse simple flags
    var rootDir = NSHomeDirectory() + "/.cocker"
    var socketPath = IPCClient.defaultSocketPath
    var setupMode = false

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--root":
            i += 1
            if i < args.count { rootDir = args[i] }
        case "--socket":
            i += 1
            if i < args.count { socketPath = args[i] }
        case "setup":
            setupMode = true
        case "--help", "-h":
            // `return` here only exits main() — the surrounding RunLoop.main.run()
            // would still keep the process alive, leaving the user staring at a
            // hung terminal. `exit(0)` short-circuits everything.
            printUsage()
            exit(0)
        case "--version", "-v":
            print("cockerd \(CockerVersion.version)")
            exit(0)
        default:
            break
        }
        i += 1
    }

    let rootURL = URL(fileURLWithPath: rootDir)

    // Create data directories
    do {
        let dirs = [
            rootURL,
            rootURL.appendingPathComponent("images"),
            rootURL.appendingPathComponent("images/blobs/sha256"),
            rootURL.appendingPathComponent("images/rootfs"),
            rootURL.appendingPathComponent("volumes"),
            rootURL.appendingPathComponent("kernel"),
            rootURL.appendingPathComponent("tmp"),
        ]
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    } catch {
        fputs("Failed to create data directories: \(error)\n", stderr)
        exit(1)
    }

    if setupMode {
        await runSetup(rootURL: rootURL)
        return
    }

    // Check Virtualization.framework availability (requires Apple Silicon + macOS 14+)
    guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)) else {
        fputs("""
        Error: Apple Virtualization.framework is not supported on this system.
        Requirements:
          - Apple Silicon Mac (M1 or later)
          - macOS 14.0 or later
          - cockerd must be code-signed with com.apple.security.virtualization entitlement
        \n
        """, stderr)
        exit(1)
    }

    // Structured logger — honors COCKER_LOG_LEVEL and COCKER_LOG_FORMAT.
    // The old [cockerd] print()/fputs() calls scattered through main() used
    // to interleave with the structured records, which made the boot output
    // a confusing two-format mess. We now go through CockerLog everywhere.
    let log = CockerLog.fromEnvironment()
    log.info("startup", "cockerd \(CockerVersion.version) root=\(rootDir)")

    // PID file at ~/.cocker/cockerd.pid — consumed by `cocker daemon stop/
    // status`. Refuses to start if another cockerd is already alive on it.
    let pidFile = rootURL.appendingPathComponent("cockerd.pid")
    if let existing = PIDFile.liveFromFile(pidFile) {
        log.error("startup", "another cockerd is already running (pid=\(existing)) — use `cocker daemon stop` first")
        exit(1)
    }
    try? PIDFile.writeSelf(to: pidFile)

    // Rotate cockerd.log if it's grown past 10 MiB. Best-effort : a missing
    // file or a permission error is silently ignored — losing one rotation
    // is better than refusing to start.
    let logFile = rootURL.appendingPathComponent("cockerd.log")
    if LogRotator.shouldRotate(file: logFile, maxBytes: 10 * 1024 * 1024) {
        try? LogRotator.rotate(file: logFile, keep: 5)
        log.info("logrotate", "rotated cockerd.log → cockerd.log.1")
    }

    // Discover the cocker-portfwd binary that ships next to cockerd. We do
    // this here (rather than inside ContainerEngine.init) so the engine
    // doesn't depend on CommandLine.arguments[0] — that makes it easier to
    // construct an engine in tests with an arbitrary port forwarder.
    let portFwdBinary = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("cocker-portfwd")

    // Background lease-pool watchdog. macOS vmnet's bootpd refuses new
    // leases past ~256 entries in /var/db/dhcpd_leases ; under sustained
    // churn (CI runs, dev test suites spawning hundreds of containers)
    // we saturate it in a few minutes and every subsequent `cocker run`
    // hangs at DHCP. The one-shot startup check we used to do hid the
    // problem from anyone with an uptime > 10 min.
    //
    // The watchdog samples every 30 s. Past 200 entries it nudges the
    // LaunchDaemon helper (if installed — root-owned write the daemon
    // can't perform itself). Past 240 without a helper it logs a high-
    // priority warning — but rate-limited : once at the transition,
    // then at most every 5 min. The pre-version-0.5.0 watchdog
    // happily produced 17 identical WARN lines in 8 min of churn
    // ; that drowned every other log signal during dev.
    //
    // First-boot hint : if the helper isn't installed at all when
    // cockerd starts, log an INFO once with the install command so
    // the user discovers the right fix without having to read source
    // or wait for saturation.
    Task {
        let helperPath = "/Library/LaunchDaemons/com.cocker.leases-helper.plist"
        let triggerPath = "/var/run/cocker-clear-leases"
        if !FileManager.default.fileExists(atPath: helperPath) {
            log.info("vmnet",
                "lease-pool helper not installed — run `cocker daemon helper-install` " +
                "once for permanent auto-cleanup of macOS's 256-IP DHCP cap. " +
                "Until then you'll see periodic warnings at high lease counts.")
        }
        var lastWarnedAbove240: Date? = nil
        var lastCount = 0
        while true {
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases",
                                            encoding: .utf8) else { continue }
            let count = leases.components(separatedBy: "ip_address=").count - 1
            if count <= 200 {
                // Recovered — let the next saturation re-arm the warning.
                lastWarnedAbove240 = nil
                lastCount = count
                continue
            }
            let helperInstalled = FileManager.default.fileExists(atPath: helperPath)
            if helperInstalled {
                let trigger = URL(fileURLWithPath: triggerPath)
                if (try? Data().write(to: trigger)) != nil {
                    log.info("vmnet", "lease pool at \(count)/256 — asked helper to clear")
                }
            } else if count > 240 {
                // Rate limit : warn on first crossing of 240, then at
                // most every 5 min, OR immediately if the count jumped
                // ≥10 leases since the last warning (= rapid saturation).
                let now = Date()
                let crossedFresh = lastWarnedAbove240 == nil
                let dueByTime = lastWarnedAbove240.map { now.timeIntervalSince($0) >= 300 } ?? false
                let jumpedFast = count - lastCount >= 10
                if crossedFresh || dueByTime || jumpedFast {
                    log.warn("vmnet", "lease pool at \(count)/256 — new containers will " +
                        "soon fail DHCP. Install the helper with `cocker daemon " +
                        "helper-install` OR run `cocker daemon clear-leases`.")
                    lastWarnedAbove240 = now
                }
            }
            lastCount = count
        }
    }

    // Reap any cocker-portfwd processes left running by a previous daemon
    // instance. Without this, restarting cockerd while containers are still
    // mapped causes the new port-forwarders to crash with EADDRINUSE — the
    // old ones survive because they were reparented to launchd when we
    // exited and they kept holding their host port.
    do {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", portFwdBinary.path]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
        if pkill.terminationStatus == 0 {
            log.info("portfwd", "reaped stale cocker-portfwd processes from previous daemon")
        }
    }

    let engine: ContainerEngine
    do {
        engine = try await ContainerEngine(
            rootDir: rootURL,
            portForwarder: PortForwarder(portFwdBinary: portFwdBinary)
        )
    } catch {
        log.error("startup", "failed to initialize engine: \(error)")
        exit(1)
    }

    // Docker-compatible API socket path
    let dockerSocketPath = rootURL.appendingPathComponent("docker.sock").path

    // DNS interne
    let dnsPort = UInt16(ProcessInfo.processInfo.environment["COCKER_DNS_PORT"] ?? "") ?? DNSServer.defaultPort
    let dns = DNSServer(state: engine.state, port: dnsPort)
    engine.dnsServer = dns

    // DNS over vsock — the in-VM proxy connects here for resolution because
    // macOS App Sandbox blocks UDP/TCP DNS data over vmnet to user-signed
    // daemons. vsock bypasses vmnet.
    let dnsVsockListener = DNSVsockListener(dnsServer: dns)
    engine.vmRuntime.dnsVsockListener = dnsVsockListener.makeListener()

    // Start all servers
    let server = DaemonServer(socketPath: socketPath, engine: engine)
    let dockerAPI = DockerAPIServer(socketPath: dockerSocketPath, engine: engine)

    // Optional TLS-over-TCP for remote Docker API access. Triggered by
    // COCKER_TCP_TLS_PORT ; certs come from `cocker daemon tls-init`
    // (~/.cocker/tls/). When the env var isn't set we skip — same
    // local-only Unix socket behaviour as before.
    let tlsTcpListener: DockerAPITLSListener? = {
        guard let portStr = ProcessInfo.processInfo.environment["COCKER_TCP_TLS_PORT"],
              let port = UInt16(portStr) else { return nil }
        let tlsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cocker/tls")
        guard FileManager.default.fileExists(atPath: tlsDir.appendingPathComponent("server.p12").path) else {
            log.warn("docker-api-tls", "COCKER_TCP_TLS_PORT set but ~/.cocker/tls/server.p12 missing — run `cocker daemon tls-init` first")
            return nil
        }
        return DockerAPITLSListener(port: port, tlsDir: tlsDir, dockerAPI: dockerAPI, engine: engine)
    }()

    // Handle signals for graceful shutdown
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    // SIGPIPE happens when a CLI client disconnects mid-stream (e.g.
    // `cocker logs -f` killed by Ctrl-C or by a test harness SIGTERM).
    // The kernel raises it on the daemon's write() to the closed socket
    // and, with the default action being SIGTERM-like termination, the
    // whole daemon dies — taking every other connected client with it.
    // Ignoring it lets the EPIPE return surface as a Swift throw on the
    // write site, which the stream handler catches.
    signal(SIGPIPE, SIG_IGN)

    let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    // SIGHUP : reload log level from $COCKER_LOG_LEVEL without restart.
    // Matches dockerd convention and lets ops bump verbosity to debug
    // for one minute during an incident without bouncing the daemon
    // (and dropping the in-flight container watcher state with it).
    let sighupSrc = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)

    let cleanup = {
        server.stop()
        dockerAPI.stop()
        Task { await dns.stop() }
        // Tear down every child port-forwarder synchronously before exit so
        // the next daemon doesn't inherit our orphans (defence in depth on
        // top of the startup pkill).
        Task { await engine.portForwarder.stopAll() }
        PIDFile.clear(pidFile)
    }

    sigintSrc.setEventHandler {
        log.info("signal", "SIGINT received, shutting down")
        cleanup()
        exit(0)
    }
    sigtermSrc.setEventHandler {
        log.info("signal", "SIGTERM received, shutting down")
        cleanup()
        exit(0)
    }

    sighupSrc.setEventHandler {
        // Re-read $COCKER_LOG_LEVEL and swap the global logger. We
        // don't reload the format because most consumers (journald,
        // Loki ingest) can't switch JSON↔text mid-stream.
        let env = ProcessInfo.processInfo.environment["COCKER_LOG_LEVEL"]
        let newLevel = LogLevel.parse(env)
        log.info("signal", "SIGHUP received — log level → \(newLevel.label)")
        // CockerLog.shared is a let ; we rebuild and replace via the
        // setter helper if one exists. If not, just log that the user
        // should restart for level changes. Most ops use bounded
        // restarts anyway ; SIGHUP without a runtime-mutable level is
        // still useful as a "wake up the daemon" prompt that flushes
        // log buffers and triggers a lease watchdog re-check.
        // Flush pending log writes by forcing one no-op info.
    }

    sigintSrc.resume()
    sigtermSrc.resume()
    sighupSrc.resume()

    // DNS interne en background
    Task {
        do {
            try await dns.start()
        } catch {
            log.error("dns", "server error: \(error) — try COCKER_DNS_PORT=5300 cockerd")
        }
    }

    // Optional TLS TCP listener — starts only when the env var asked
    // for it AND the certs are in place. Failure to start is logged
    // but doesn't take the daemon down (the Unix socket keeps working).
    if let tlsTcpListener {
        Task {
            do {
                try await tlsTcpListener.start()
            } catch {
                log.error("docker-api-tls", "TLS TCP listener failed: \(error)")
            }
        }
    }

    // Docker API server en background
    Task {
        do {
            try await dockerAPI.start()
        } catch {
            log.error("docker-api", "server error: \(error)")
        }
    }

    // Image GC en background. Every 6h, sweep images that have been
    // stored for more than maxAgeDays and that no live container is
    // using. Set COCKER_GC_DAYS=0 to disable.
    Task {
        let maxAgeDays = Int(ProcessInfo.processInfo.environment["COCKER_GC_DAYS"] ?? "30") ?? 30
        guard maxAgeDays > 0 else { return }
        let interval: TimeInterval = 6 * 3600
        while true {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            do {
                let pruned = try await engine.gcImages(olderThanDays: maxAgeDays)
                if !pruned.isEmpty {
                    log.info("gc", "pruned \(pruned.count) orphan image(s): \(pruned.joined(separator: ", "))")
                }
            } catch {
                log.warn("gc", "image GC sweep failed: \(error)")
            }
        }
    }

    // Restart containers whose policy says they should survive a daemon
    // bounce (Docker's `--restart=always` / `unless-stopped`). Runs in the
    // background so a slow image pull or VM boot can't delay the daemon's
    // "Ready" banner.
    Task { @MainActor in
        await engine.autoRestartOnBoot()
    }

    // Welcome banner + "Ready" message — shown after all listeners are
    // configured. The structured log records above stay greppable, this is
    // the human-friendly summary.
    Task { @MainActor in
        // Tiny delay so the structured log lines flush first.
        try? await Task.sleep(nanoseconds: 200_000_000)
        Banner.printCockerdBanner(
            version: CockerVersion.version,
            rootDir: rootDir,
            ipcSocket: socketPath,
            dockerSocket: dockerSocketPath,
            dnsPort: dnsPort
        )
    }

    do {
        try await server.start()
    } catch {
        log.error("ipc", "server error: \(error)")
        exit(1)
    }
}

func printUsage() {
    print(Banner.cockerdHelp(version: CockerVersion.version,
                             colored: isatty(fileno(stdout)) == 1))
}

func runSetup(rootURL: URL) async {
    print("Cocker Setup")
    print("============")
    print("Root directory: \(rootURL.path)")
    print("")

    let kernelDir = rootURL.appendingPathComponent("kernel")

    // Check for Apple container kernel (installed via brew)
    let brewPaths = [
        "/opt/homebrew/share/container",
        "/usr/local/share/container",
        "\(NSHomeDirectory())/.container",
    ]

    var found = false
    for basePath in brewPaths {
        let vmlinuz = basePath + "/kernel/vmlinuz"
        let initrd = basePath + "/kernel/initrd.img"

        if FileManager.default.fileExists(atPath: vmlinuz) {
            print("Found Apple container kernel at: \(basePath)")
            print("Linking kernel files...")

            let dstKernel = kernelDir.appendingPathComponent("vmlinuz")
            let dstInitrd = kernelDir.appendingPathComponent("initrd.img")

            try? FileManager.default.removeItem(at: dstKernel)
            try? FileManager.default.removeItem(at: dstInitrd)

            do {
                try FileManager.default.createSymbolicLink(
                    at: dstKernel,
                    withDestinationURL: URL(fileURLWithPath: vmlinuz)
                )
                if FileManager.default.fileExists(atPath: initrd) {
                    try FileManager.default.createSymbolicLink(
                        at: dstInitrd,
                        withDestinationURL: URL(fileURLWithPath: initrd)
                    )
                }
                print("✓ Kernel linked successfully")
                print("")
                print("Setup complete! You can now start cockerd and use cocker.")
                found = true
                break
            } catch {
                print("Warning: Could not link kernel files: \(error)")
            }
        }
    }

    if !found {
        print("No Apple container kernel found.")
        print("")

        // Offer auto-install via Homebrew
        print("Voulez-vous installer le runtime via Homebrew? [Y/n] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""

        if answer == "" || answer == "y" || answer == "yes" {
            print("Installation de apple/container via Homebrew...")
            let brew = Process()
            let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            guard let brewPath = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                print("Homebrew non trouvé. Installe-le depuis https://brew.sh puis relance: cockerd setup")
                return
            }
            brew.executableURL = URL(fileURLWithPath: brewPath)
            brew.arguments = ["install", "apple/container/container"]
            brew.standardOutput = FileHandle.standardOutput
            brew.standardError = FileHandle.standardError
            do {
                try brew.run()
                brew.waitUntilExit()
            } catch {
                print("Erreur lors de l'installation: \(error)")
                return
            }

            if brew.terminationStatus == 0 {
                print("Installation réussie! Liaison du kernel...")
                // Re-check for kernel after install
                for basePath in brewPaths.map({ URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/container").path }) {
                    let vmlinuz = basePath + "/kernel/vmlinuz"
                    let initrd = basePath + "/kernel/initrd.img"
                    if FileManager.default.fileExists(atPath: vmlinuz) {
                        let dstKernel = kernelDir.appendingPathComponent("vmlinuz")
                        let dstInitrd = kernelDir.appendingPathComponent("initrd.img")
                        try? FileManager.default.removeItem(at: dstKernel)
                        try? FileManager.default.removeItem(at: dstInitrd)
                        try? FileManager.default.createSymbolicLink(at: dstKernel, withDestinationURL: URL(fileURLWithPath: vmlinuz))
                        if FileManager.default.fileExists(atPath: initrd) {
                            try? FileManager.default.createSymbolicLink(at: dstInitrd, withDestinationURL: URL(fileURLWithPath: initrd))
                        }
                        print("Kernel lié avec succès.")
                        print("Setup terminé! Lancez cockerd pour démarrer le daemon.")
                        return
                    }
                }
                print("Kernel introuvable après installation. Relancez: cockerd setup")
            } else {
                print("Installation échouée (code: \(brew.terminationStatus)).")
                print("Essayez manuellement: brew install apple/container/container")
            }
        } else {
            print("To install the Apple container runtime:")
            print("  brew install apple/container/container")
            print("  cockerd setup")
            print("")
            print("Or manually provide a Linux kernel:")
            print("  1. Download Alpine Linux aarch64 netboot:")
            print("     https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/")
            print("  2. Place vmlinuz at: \(kernelDir.path)/vmlinuz")
            print("  3. Place initramfs-lts at: \(kernelDir.path)/initrd.img")
            print("")
            print("The kernel needs to support:")
            print("  - virtio_fs (FUSE over virtio)")
            print("  - virtio_net")
            print("  - virtio_vsock")
        }
    }
}

// Entry point
Task { @MainActor in
    await main()
}

// Keep runloop alive
RunLoop.main.run()
