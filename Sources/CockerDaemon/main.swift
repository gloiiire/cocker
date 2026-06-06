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
            printUsage()
            return
        case "--version", "-v":
            print("cockerd \(CockerVersion.version)")
            return
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

    // Handle signals for graceful shutdown
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    sigintSrc.setEventHandler {
        log.info("signal", "SIGINT received, shutting down")
        server.stop()
        dockerAPI.stop()
        Task { await dns.stop() }
        exit(0)
    }
    sigtermSrc.setEventHandler {
        log.info("signal", "SIGTERM received, shutting down")
        server.stop()
        dockerAPI.stop()
        Task { await dns.stop() }
        exit(0)
    }

    sigintSrc.resume()
    sigtermSrc.resume()

    // DNS interne en background
    Task {
        do {
            try await dns.start()
        } catch {
            log.error("dns", "server error: \(error) — try COCKER_DNS_PORT=5300 cockerd")
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
    print("""
    cockerd — Cocker container engine daemon

    Usage:
      cockerd [options]
      cockerd setup

    Options:
      --root <path>     Data directory (default: ~/.cocker)
      --socket <path>   Unix socket path (default: ~/.cocker/cocker.sock)
      --version, -v     Show version
      --help, -h        Show this help

    Commands:
      setup             Download and configure the Linux kernel for VM containers

    How to run cockerd
    ──────────────────
    cockerd is a long-running daemon (like dockerd). It listens on three
    sockets and never exits on its own. Pick one of three ways to run it :

      1. Foreground (development / debugging)
         $ cockerd
         # ← stays in your terminal, Ctrl-C to stop.
         # Open another terminal for `cocker run`, `cocker ps`, etc.

      2. Background in the current shell
         $ cockerd > ~/cockerd.log 2>&1 &
         $ cocker ps                       # ← back to a prompt, daemon runs
         $ kill %1                         # ← stop the daemon

      3. As a managed service (recommended)
         $ brew services start cocker     # ← auto-restarts at login
         $ brew services stop cocker
         $ brew services list             # ← status
         # Logs : /opt/homebrew/var/log/cockerd.log
         # Auto-rotated at 10 MiB, last 5 kept.

    Environment:
      COCKER_ROOT       Override data directory
      COCKER_SOCKET     Override socket path
      COCKER_LOG_LEVEL  debug | info | warn | error (default: info)
      COCKER_LOG_FORMAT text | json
      COCKER_TRACE      stderr  — emit OTLP-compatible JSON spans
      COCKER_DNS_PORT   Override DNS server port (default: 5300)

    Entitlements required:
      com.apple.security.virtualization

    The daemon must be code-signed with the above entitlement to start VMs.
    See: codesign -s "Your Dev ID" --entitlements entitlements/cockerd.entitlements .build/release/cockerd
    """)
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
