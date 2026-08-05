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

    // Create data directories, owner-only (0700). These hold volume disk
    // images (a container's raw database files + any secrets it writes),
    // pulled layer blobs, and the kernel — none of it should be readable by
    // other local accounts. `createDirectory`'s `attributes` are applied
    // directly and are NOT masked by umask, unlike bare `open()`/`mkdir`,
    // so this reliably yields 0700 even with a permissive umask.
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
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        // Migration for installs created before the 0700/0600 hardening :
        // `attributes` above only affects freshly-created dirs, so tighten
        // the existing tree and any world-readable volume images in place.
        // Best-effort — a chmod failure must not stop the daemon booting.
        for dir in dirs {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        let volumesRoot = rootURL.appendingPathComponent("volumes")
        if let volDirs = try? FileManager.default.contentsOfDirectory(
            at: volumesRoot, includingPropertiesForKeys: nil) {
            for volDir in volDirs {
                let img = volDir.appendingPathComponent("data.img")
                if FileManager.default.fileExists(atPath: img.path) {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: img.path)
                }
            }
        }
    } catch {
        DaemonMessage.failure("Cannot create the data directories",
                              reason: "\(error)",
                              hint: "check permissions on the --root path")
        exit(1)
    }

    if setupMode {
        await runSetup(rootURL: rootURL)
        // Without exit() the surrounding RunLoop.main.run() keeps the
        // process alive — old behaviour was to hang on Ctrl-C after setup
        // finished, which read like a crash.
        exit(0)
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

    // Fail fast if the binary is missing the virtualization entitlement.
    // Without it, every VZVirtualMachine init throws a cryptic
    // "Invalid virtual machine configuration" error on first container
    // start — way after launch, when the user can't tell what's wrong.
    if !hasVirtualizationEntitlement() {
        let exe = CommandLine.arguments.first ?? "cockerd"
        fputs("""
        Error: cockerd is missing the com.apple.security.virtualization entitlement.
        Without it Virtualization.framework refuses to boot any VM.

        Fix (dev build, ad-hoc signature):
          codesign --force --sign - \\
            --entitlements entitlements/cockerd.entitlements \\
            \(exe)

        Or rerun the full installer (recommended) :
          ./install.sh

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
    // status`, and the run lock that keeps one daemon per root.
    //
    // This used to read the pid out of the file and check whether that
    // process was alive. That samples a value which is briefly wrong during
    // any restart, and two daemons ended up sharing one root because of it:
    // Homebrew's LaunchAgent has KeepAlive, so killing the daemon makes
    // launchd respawn it within a second, and `cocker daemon restart` then
    // started a second one — the file still named the process it had just
    // killed, so the check passed. Both printed "Ready", both wrote the same
    // state.json.
    //
    // `flock` has no such window: it is held by a live descriptor and
    // released by the kernel on exit, SIGKILL included. `lockFD` is
    // intentionally kept for the process lifetime — closing it would drop
    // the lock.
    let pidFile = rootURL.appendingPathComponent("cockerd.pid")
    guard let lockFD = PIDFile.acquire(pidFile) else {
        let who = PIDFile.read(pidFile).map { " (pid=\($0))" } ?? ""
        log.error("startup",
            "another cockerd already holds \(pidFile.path)\(who) — " +
            "stop it first with `cocker daemon stop`, or `brew services stop cocker` " +
            "if it is service-managed")
        exit(1)
    }
    _ = lockFD  // held for the lifetime of the process; see above

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
    //
    // Match our own binary's suffix : if we're running as `cockerd-dev`
    // (SUFFIX=-dev install), look for `cocker-portfwd-dev` next to us
    // instead of falling back to a prod `cocker-portfwd` that may not
    // exist in `~/.local/bin/` at all.
    let cockerdName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    let portFwdSuffix: String = {
        if cockerdName.hasPrefix("cockerd") {
            return String(cockerdName.dropFirst("cockerd".count))
        }
        return ""
    }()
    let portFwdBinary = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("cocker-portfwd\(portFwdSuffix)")

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
        // Nothing to watch when containers assign their own eth0 address:
        // they never ask for a lease, so the pool's depth says nothing about
        // whether the next `cocker run` will work. Warning about it anyway
        // would be telling the user to fix something that is not their
        // problem, which is how warnings get ignored.
        if ContainerEngine.staticNATEnabled {
            log.info("vmnet",
                "eth0 addresses are assigned by cocker — the macOS DHCP lease "
                + "pool is not used and not monitored (COCKER_STATIC_ETH0=0 "
                + "restores the DHCP path)")
            return
        }
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
            // Whether the helper ACCEPTED the request, not whether its
            // plist happens to exist. The old shape asked "is it
            // installed?", tried the write, discarded the failure, and
            // routed the actionable warning into the `else` branch — so an
            // installed-but-inert helper produced total silence while the
            // pool ran to 317/256 and containers failed DHCP. Both
            // failure modes are real: the plist can be present with
            // `launchctl` never having loaded it, and `/var/run` is
            // root-owned while cockerd runs as the user.
            let helperInstalled = FileManager.default.fileExists(atPath: helperPath)
            var helperAccepted = false
            if helperInstalled {
                let trigger = URL(fileURLWithPath: triggerPath)
                helperAccepted = (try? Data().write(to: trigger)) != nil
                if helperAccepted {
                    log.info("vmnet", "lease pool at \(count)/256 — asked helper to clear")
                }
            }
            if !helperAccepted, count > 240 {
                // Rate limit : warn on first crossing of 240, then at
                // most every 5 min, OR immediately if the count jumped
                // ≥10 leases since the last warning (= rapid saturation).
                let now = Date()
                let crossedFresh = lastWarnedAbove240 == nil
                let dueByTime = lastWarnedAbove240.map { now.timeIntervalSince($0) >= 300 } ?? false
                let jumpedFast = count - lastCount >= 10
                if crossedFresh || dueByTime || jumpedFast {
                    let fix = helperInstalled
                        ? "The helper is installed but did not accept the request — it is " +
                          "probably not loaded (`sudo launchctl load \(helperPath)`). " +
                          "Reinstall with `cocker daemon helper-install`, or clear once " +
                          "with `cocker daemon clear-leases`."
                        : "Install the helper with `cocker daemon helper-install` " +
                          "OR run `cocker daemon clear-leases`."
                    log.warn("vmnet", "lease pool at \(count)/256 — new containers will " +
                        "soon fail DHCP. " + fix)
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
    } catch let error as CockerError {
        log.error("startup", "failed to initialize engine: \(error.description)")
        // Schema-too-new keeps its historical EX_USAGE (64) exit code so
        // operators / scripts keying on it still work. The check used to
        // live (as an exit()) inside StateStore ; it now throws and the
        // process-death decision is made here, at the top level.
        if case .stateSchemaTooNew = error { exit(64) }
        exit(1)
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
    // The listener needs to ask VMRuntime who owns a given vsock device, so
    // DNS can be scoped to the querier's network. Weak so the closure does
    // not keep the runtime alive.
    let runtime = engine.vmRuntime
    let dnsVsockListener = DNSVsockListener(dnsServer: dns) { [weak runtime] device in
        runtime?.containerOwning(vsockDevice: device)
    }
    engine.vmRuntime.dnsVsockListener = dnsVsockListener.makeListener()
    // VZVirtioSocketListener holds its delegate weakly, so the delegate has
    // to be retained here or DNS silently stops working once it deallocs.
    engine.vmRuntime.dnsVsockDelegate = dnsVsockListener

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

    /// Graceful shutdown : tear every async-aware service down before exit so
    /// the next daemon doesn't inherit orphan port-forwarders and so DNS /
    /// IPC clients see a clean disconnect. Awaiting is mandatory — the
    /// pre-fix code dispatched `Task { await ... }` then called `exit(0)`
    /// in the same closure, killing the process before the Tasks had a
    /// chance to run.
    @MainActor func gracefulShutdown() async {
        server.stop()
        dockerAPI.stop()
        await dns.stop()
        await engine.portForwarder.stopAll()
        tlsTcpListener?.stop()
        // Push any debounced (.coalesced) state mutations to disk before
        // the process dies — otherwise the last ~500 ms of healthcheck
        // bookkeeping would be lost on every clean shutdown.
        await engine.state.flushPending()
        PIDFile.clear(pidFile)
    }

    sigintSrc.setEventHandler {
        log.info("signal", "SIGINT received, shutting down")
        Task { @MainActor in
            await gracefulShutdown()
            exit(0)
        }
    }
    sigtermSrc.setEventHandler {
        log.info("signal", "SIGTERM received, shutting down")
        Task { @MainActor in
            await gracefulShutdown()
            exit(0)
        }
    }

    sighupSrc.setEventHandler {
        // Runtime log-level swap isn't supported because CockerLog.shared
        // is a value-type singleton ; pretending otherwise (as the prior
        // code did with a fake "log level → X" line) misled operators who
        // expected COCKER_LOG_LEVEL changes to take effect. We do two
        // useful things instead, both of which match Unix daemon conventions
        // for SIGHUP : (1) force a log rotation, (2) probe + report current
        // lease pool state so the operator gets a fresh observability ping.
        let currentLevel = LogLevel.parse(ProcessInfo.processInfo.environment["COCKER_LOG_LEVEL"])
        log.info("signal",
            "SIGHUP — rotating cockerd.log (live log-level swap not supported ; " +
            "current level=\(currentLevel.label), restart cockerd to change it)")
        try? LogRotator.rotate(file: logFile, keep: 5)
        let pool = ContainerEngine.leasePoolCount()
        let helper = ContainerEngine.leasePoolHelperInstalled() ? "yes" : "no"
        log.info("vmnet", "lease pool=\(pool)/256, helper=\(helper)")
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

// MARK: - Entitlement self-check

/// Shells out to `codesign -d --entitlements -` against our own binary and
/// looks for the virtualization entitlement key. Tolerant of every failure
/// path : if codesign isn't there or the binary path can't be resolved, we
/// assume the entitlement is present and let VZ surface the real error
/// later — better than blocking a working install over a probe glitch.
func hasVirtualizationEntitlement() -> Bool {
    let exe = CommandLine.arguments.first ?? ""
    guard !exe.isEmpty, FileManager.default.fileExists(atPath: exe) else { return true }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    proc.arguments = ["-d", "--entitlements", ":-", exe]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do { try proc.run() } catch { return true }
    proc.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let str = String(data: data, encoding: .utf8) ?? ""
    return str.contains("com.apple.security.virtualization")
}

// MARK: - Setup

/// Where Apple-provided `container` runtimes can sit. Order matters — we
/// take the first match. The list covers : Homebrew (cellar-shared dirs),
/// the official `.pkg` installer's libexec/share paths, and the per-user
/// directory the `container` CLI writes to on first run.
private let kernelSearchRoots: [String] = {
    let home = NSHomeDirectory()
    return [
        "/opt/homebrew/share/container",
        "/usr/local/share/container",
        "/usr/local/libexec/container",
        "/opt/homebrew/libexec/container",
        "\(home)/.container",
        "\(home)/Library/Application Support/com.apple.container",
        "\(home)/Library/Application Support/com.apple.container.runtime",
    ]
}()

/// Adds paths relative to `container` in PATH (e.g. .pkg installs to
/// /usr/local/bin/container and the kernel sits in ../share or ../libexec).
private func kernelRootsFromContainerBinary() -> [String] {
    guard let bin = which("container") else { return [] }
    let dir = (bin as NSString).deletingLastPathComponent
    let prefix = (dir as NSString).deletingLastPathComponent
    return [
        "\(prefix)/share/container",
        "\(prefix)/libexec/container",
    ]
}

/// Look for cocker's own bundled initrd.img in the Homebrew share tree.
/// `brew install gloiiire/cocker/cocker` drops the initrd at
/// `<prefix>/share/cocker/initrd.img` (intermediate staging before the
/// postinstall step symlinks it into `~/.cocker/kernel/`). If the
/// postinstall stranded the file there (HOME-sandbox bug pre-0.5.5),
/// `cockerd setup` calls this to recover. Returns nil if no Homebrew
/// install is present (= the user is on a source/install.sh build).
///
/// Path resolution is layered, most-portable-first :
///   1. `$HOMEBREW_PREFIX/share/cocker/initrd.img` — set by brew shellenv,
///      respects custom prefixes (Linuxbrew, dev installs to ~/brew, etc).
///   2. Sibling to the running binary : `argv[0]/../../share/cocker/...`.
///      Works regardless of brew prefix because the path is derived from
///      cockerd's own location. Robust to symlinks because resolvingSymlinks
///      collapses /opt/homebrew/bin/cockerd → Cellar/.../bin/cockerd before
///      we go up two levels.
///   3. The two historically hardcoded brew prefixes, kept as a last
///      resort so a stripped HOMEBREW_PREFIX + broken argv[0] still
///      finds the file on a default install.
///
/// Apple's container hit a related bug (1.0.0_1) and fixed it with an
/// `env_script` wrapper that exports an install-root env var; we don't
/// need that because cocker resolves sibling binaries via the executable's
/// own parent, not via a lexical grandparent of argv[0].
private func discoverShippedCockerInitrd() -> String? {
    let fm = FileManager.default
    var candidates: [String] = []

    if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
        candidates.append("\(prefix)/share/cocker/initrd.img")
    }

    // argv[0] → resolve symlinks → bin/cockerd → ../share/cocker/initrd.img
    let argv0 = CommandLine.arguments[0]
    let exe = URL(fileURLWithPath: argv0).resolvingSymlinksInPath()
    let prefixFromExe = exe.deletingLastPathComponent().deletingLastPathComponent().path
    candidates.append("\(prefixFromExe)/share/cocker/initrd.img")

    candidates.append("/opt/homebrew/share/cocker/initrd.img")   // Apple Silicon (default brew prefix)
    candidates.append("/usr/local/share/cocker/initrd.img")      // Intel Mac (legacy brew prefix)

    return candidates.first { fm.fileExists(atPath: $0) }
}

private func which(_ tool: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
        let d = String(dir)
        // **S4 fix** : refuse empty entries ("::") AND any relative PATH
        // component ("." or unrooted directories). A misconfigured PATH
        // that contains `.` would otherwise let `which("container")`
        // resolve to a same-named binary in whatever cwd cockerd happens
        // to be launched from — useful for attackers planting bait
        // binaries in build context directories.
        guard d.hasPrefix("/") else { continue }
        let candidate = "\(d)/\(tool)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Sanity-check that a kernel path the daemon is about to symlink into
/// `~/.cocker/kernel/vmlinuz` lives in a directory we'd expect (Homebrew
/// prefix, Apple's container .pkg layout, the user's ~/.container, …). A
/// kernel found anywhere else is suspicious enough to surface : an
/// attacker who could plant a vmlinuz in a world-writable temp dir would
/// otherwise see cockerd happily boot every container off it.
private func kernelPathLooksTrusted(_ path: String) -> Bool {
    let trustedRoots = [
        "/opt/homebrew/",
        "/usr/local/",
        "/Library/",
        "\(NSHomeDirectory())/.container/",
        "\(NSHomeDirectory())/.cocker/",
        "\(NSHomeDirectory())/Library/Application Support/com.apple.container",
        "\(NSHomeDirectory())/Library/Application Support/com.apple.container.runtime",
    ]
    return trustedRoots.contains { path.hasPrefix($0) }
}

private struct DiscoveredKernel {
    let root: String
    let vmlinuz: String
    let initrd: String?
}

/// Two layouts we recognize :
///   1. Homebrew / older releases : <root>/kernel/vmlinuz (+ initrd.img)
///   2. Apple `container` .pkg     : <root>/kernels/vmlinux-<ver>-<build>
///      (initrd lives per-container, so nothing to symlink — cocker uses
///      its own initrd.img from cocker-init either way.)
private func discoverAppleKernel() -> DiscoveredKernel? {
    var roots = kernelSearchRoots
    roots.append(contentsOf: kernelRootsFromContainerBinary())
    let fm = FileManager.default

    for root in roots {
        // Layout 1 — classic Homebrew path.
        let classic = root + "/kernel/vmlinuz"
        if fm.fileExists(atPath: classic) {
            let initrd = root + "/kernel/initrd.img"
            return DiscoveredKernel(
                root: root,
                vmlinuz: classic,
                initrd: fm.fileExists(atPath: initrd) ? initrd : nil
            )
        }

        // Layout 2 — Apple `container` .pkg. Pick the lexicographically
        // newest vmlinux-* (release strings sort naturally enough for our
        // single-Mac use case).
        let kernelsDir = root + "/kernels"
        if let entries = try? fm.contentsOfDirectory(atPath: kernelsDir) {
            let candidates = entries.filter { $0.hasPrefix("vmlinux") }.sorted()
            if let pick = candidates.last {
                return DiscoveredKernel(
                    root: root,
                    vmlinuz: kernelsDir + "/" + pick,
                    initrd: nil
                )
            }
        }
    }
    return nil
}

/// Symlinks (or copies, if symlink fails) the discovered kernel into
/// `kernelDir`. Returns true on success. Errors are printed in-place so
/// the caller can keep its happy-path branching simple.
private func linkKernel(_ k: DiscoveredKernel, into kernelDir: URL) -> Bool {
    // S7 — warn (don't refuse) if the discovered kernel sits in a
    // directory we don't recognise. We don't refuse outright because
    // power users intentionally bind-mount custom kernels into
    // ~/.container ; printing the path makes the trust decision
    // visible at install time so the user can spot anything odd.
    if !kernelPathLooksTrusted(k.vmlinuz) {
        DaemonMessage.warning("kernel path \(k.vmlinuz) is outside the usual " +
              "Homebrew / Apple container / ~/.container prefixes. " +
              "Verify it's the kernel you intended to install before " +
              "starting cockerd.")
    }
    let dstKernel = kernelDir.appendingPathComponent("vmlinuz")
    let dstInitrd = kernelDir.appendingPathComponent("initrd.img")
    try? FileManager.default.removeItem(at: dstKernel)
    try? FileManager.default.removeItem(at: dstInitrd)
    do {
        try FileManager.default.createSymbolicLink(
            at: dstKernel,
            withDestinationURL: URL(fileURLWithPath: k.vmlinuz)
        )
        if let initrd = k.initrd {
            try FileManager.default.createSymbolicLink(
                at: dstInitrd,
                withDestinationURL: URL(fileURLWithPath: initrd)
            )
        }
        // **B14 fix** : verify the symlink target is reachable post-creation.
        // A pre-existing broken symlink (kernel file later deleted by user)
        // would otherwise let cockerd start and explode on first run with
        // an opaque VZ "config validate" error. fileExists follows symlinks,
        // so a true return == the underlying file is reachable.
        guard FileManager.default.fileExists(atPath: dstKernel.path) else {
            DaemonMessage.failure("Kernel symlink is broken",
                              reason: "\(dstKernel.path) doesn't resolve to a file",
                              hint: "re-run `cockerd setup` to re-create it")
            return false
        }
        return true
    } catch {
        DaemonMessage.warning("could not symlink kernel files", note: "\(error)")
        return false
    }
}

func runSetup(rootURL: URL) async {
    print("Cocker Setup")
    print("============")
    print("Root directory: \(rootURL.path)")
    print("")

    let kernelDir = rootURL.appendingPathComponent("kernel")
    try? FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)

    if let discovered = discoverAppleKernel() {
        print("Found Apple container kernel at: \(discovered.vmlinuz)")
        print("Linking kernel files...")
        if linkKernel(discovered, into: kernelDir) {
            print("✓ Kernel linked successfully")
            let cockerInitrd = kernelDir.appendingPathComponent("initrd.img").path
            // If Apple's kernel didn't ship an initrd alongside (which is the
            // normal case — Apple's `container` builds per-container init fs
            // and doesn't need a global one), fall back to discovering cocker's
            // OWN shipped initrd in the Homebrew share tree. The Homebrew
            // postinstall is supposed to drop it directly in ~/.cocker/kernel/,
            // but historical bugs have left it stranded at /opt/homebrew/share/
            // cocker/initrd.img — this code path rescues that situation so
            // users running `cockerd setup` on a half-broken install get
            // a fully working setup without manual symlinks.
            if !FileManager.default.fileExists(atPath: cockerInitrd) {
                if let shippedInitrd = discoverShippedCockerInitrd() {
                    do {
                        try FileManager.default.createSymbolicLink(
                            at: URL(fileURLWithPath: cockerInitrd),
                            withDestinationURL: URL(fileURLWithPath: shippedInitrd)
                        )
                        print("✓ Linked cocker's shipped initrd: \(shippedInitrd)")
                    } catch {
                        DaemonMessage.warning("found a shipped initrd but could not symlink it",
                                              note: "\(shippedInitrd): \(error)")
                    }
                } else {
                    print("")
                    DaemonMessage.warning("initrd.img is still missing at \(cockerInitrd)")
                    print("  Apple's `container` doesn't ship a Linux initrd next to its kernel")
                    print("  (it builds per-container init filesystems instead). Cocker needs")
                    print("  its own initrd. Either run `./install.sh` from the cocker checkout")
                    print("  (it copies cocker-init/initrd.img into place), or copy it manually:")
                    print("    cp cocker-init/initrd.img \(cockerInitrd)")
                }
            }
            print("")
            print("Setup complete! Run `cocker daemon start` (or restart it if already running).")
        }
        return
    }

    print("No Apple container kernel found. Tried these locations:")
    for root in kernelSearchRoots {
        print("  - \(root)/kernel/vmlinuz           (Homebrew layout)")
        print("  - \(root)/kernels/vmlinux-*        (.pkg layout)")
    }
    print("")
    if which("container") != nil {
        print("`container` is in your PATH but its kernel wasn't where we expected.")
        print("Run `container system status` to see where it stores its data, then")
        print("either symlink that vmlinuz into \(kernelDir.path)/vmlinuz manually,")
        print("or paste the absolute path to vmlinuz below.")
    } else {
        // Bottle builds since v0.7.9 declare `depends_on "container"`, so a
        // Homebrew install path can only land here when cocker was built from
        // source. Spell out both recovery options.
        print("Install Apple's container runtime first:")
        print("  → brew: `brew install container` (auto-pulls the kernel)")
        print("  → or download the .pkg from https://github.com/apple/container/releases")
        print("")
        print("Then re-run: cockerd setup")
    }
    print("")
    print("Or provide a kernel manually right now —")
    print("paste the absolute path to a Linux aarch64 vmlinuz (or leave empty to skip): ", terminator: "")
    fflush(stdout)
    let entered = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !entered.isEmpty else {
        print("")
        print("Skipped. cockerd cannot boot VMs until a kernel is in place at")
        print("  \(kernelDir.path)/vmlinuz")
        return
    }
    guard FileManager.default.fileExists(atPath: entered) else {
        DaemonMessage.failure("\(entered) does not exist")
        return
    }
    let initrdSibling = (entered as NSString).deletingLastPathComponent + "/initrd.img"
    let initrd = FileManager.default.fileExists(atPath: initrdSibling) ? initrdSibling : nil
    let manual = DiscoveredKernel(root: (entered as NSString).deletingLastPathComponent, vmlinuz: entered, initrd: initrd)
    if linkKernel(manual, into: kernelDir) {
        print("✓ Kernel linked from \(entered)")
        if initrd == nil {
            print("Note: no initrd.img next to it — cocker will ship its own.")
        }
        print("")
        print("Setup complete! Run `cocker daemon start` (or restart it if already running).")
    }
}

// Entry point
Task { @MainActor in
    await main()
}

// Keep runloop alive
RunLoop.main.run()
