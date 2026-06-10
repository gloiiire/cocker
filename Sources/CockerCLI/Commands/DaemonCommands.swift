import ArgumentParser
import CockerCore
import Darwin
import Foundation

// `cocker daemon …` — manage the background cockerd process without needing
// to know shell idioms like `cockerd > log 2>&1 &` and `kill %1`.
//
// State is tracked via a single PID file at $COCKER_ROOT/cockerd.pid which
// cockerd writes on startup and removes on graceful shutdown. `start`
// refuses to spawn if it sees a live PID ; `stop` reads the PID and sends
// SIGTERM ; `status` checks both PID liveness and IPC socket reachability.

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the cockerd background process",
        discussion: """
        Three ways to run cockerd :

          cocker daemon start          ← background, returns to shell, recommended
          brew services start cocker   ← managed, auto-restarts at login
          cockerd                      ← foreground, Ctrl-C to stop, for debugging
        """,
        subcommands: [
            DaemonStartCommand.self,
            DaemonStopCommand.self,
            DaemonRestartCommand.self,
            DaemonStatusCommand.self,
            DaemonLogsCommand.self,
            DaemonClearLeasesCommand.self,
            DaemonHelperInstallCommand.self,
            DaemonTLSInitCommand.self,
        ]
    )
}

/// `cocker daemon tls-init` — generate a self-signed CA + server +
/// client certs in `~/.cocker/tls/` so the daemon can expose the
/// Docker API over TLS on TCP for remote access. After init, set
/// `COCKER_TCP_TLS_PORT=2376` before starting cockerd (or pass
/// `--tcp-tls-port 2376` to `cockerd` directly) ; clients then talk
/// to it with the same client.{pem,key} + ca.pem the init produced.
///
/// Requires `openssl` on PATH ; cocker doesn't bundle its own crypto
/// to keep the binary lean and to give security-conscious users an
/// audit trail (every cert is a regular file they can inspect, sign,
/// revoke).
struct DaemonTLSInitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tls-init",
        abstract: "Generate self-signed mTLS certs for remote docker.sock access",
        discussion: """
        Generates a complete TLS material set in ~/.cocker/tls/ so cockerd
        can expose its Docker API over TCP with mutual authentication
        (mTLS). After running this, start the daemon with
            COCKER_TCP_TLS_PORT=2376 cocker daemon start
        and clients connect with
            DOCKER_HOST=tcp://host:2376 \\
            DOCKER_TLS_VERIFY=1 \\
            DOCKER_CERT_PATH=~/.cocker/tls

        FILES GENERATED in ~/.cocker/tls/
          ca-key.pem        Private key of the local Certificate Authority
                            (used to sign server + client certs). 0600.
          ca.pem            Public CA cert. Share with anyone who needs
                            to verify a cocker daemon. 0644.
          server-key.pem    Daemon's private key. 0600.
          server-cert.pem   Daemon's cert (signed by the CA above).
                            Subject CN=<--host>, SAN=DNS:<host>,
                            IP:127.0.0.1, IP:0.0.0.0.
          server.p12        Server identity bundle (cert+key together)
                            in PKCS#12 format with -legacy framing. The
                            daemon imports this at startup via
                            SecPKCS12Import to feed Network.framework.
          server.p12.pass   Passphrase for server.p12 (0600). SecPKCS12-
                            Import returns errSecAuthFailed on empty-
                            password bundles even with -legacy framing,
                            so a non-empty value is mandatory.
          cert.pem          Client cert. Set DOCKER_CERT_PATH to this
                            directory and Docker CLI / curl pick it up.
          key.pem           Client private key. 0600.

        WHY ECDSA P-256 EVERYWHERE, NOT RSA

        macOS's Security framework wraps an internal TLS stack
        (boringssl) that demands RSA-PSS signatures for RSA keys on
        TLS 1.3. The legacy CSSM-backed private keys that
        SecPKCS12Import produces on macOS can't do RSA-PSS — every
        attempt returns CSSMERR_CSP_INVALID_KEYATTR_MASK and the TLS
        handshake stalls forever. Forcing TLS 1.2-only (where RSA-
        PKCS1v15 still works) is a workaround but limits the
        ciphersuites we'd like to advertise. ECDSA sidesteps the entire
        family of bugs : its signature format is identical in TLS 1.2
        and 1.3, the CSSM key handles it fine, and the cert/key files
        are an order of magnitude smaller (~600 B vs 3.3 KB for RSA-
        4096). Cocker therefore uses prime256v1 for the CA + server +
        client triple, not classic RSA.

        SERVER-KEY PRE-WARM (you'll see it in the daemon log)

        The very first SecKeyCreateSignature call on a freshly-imported
        PKCS#12 identity routinely takes 9–12 seconds on macOS — and
        on a cold keychain it can stretch to several minutes. The
        latency is from keychain ACL bootstrap (legacy CSSM machinery)
        and is unavoidable. Subsequent signatures complete in single-
        digit milliseconds.

        At daemon startup, DockerAPITLSListener.start does ONE dummy
        signature synchronously before opening the listening port —
        the operator waits ~10 s once at boot ; in exchange every
        client connection that follows sees a millisecond-fast
        handshake. Without this pre-warm the first incoming TLS
        connection times out at ~8 s before boringssl finishes the
        sign, and the user sees "SSL connection timeout" forever.

        Look for these lines in cocker daemon logs after start :
            [docker-api-tls] pre-warming server key (one-time, ~10s; up to 4 min on cold keychain)…
            [docker-api-tls] server key pre-warmed in 9s
            [docker-api-tls] TLS listening on tcp://0.0.0.0:2376

        OPENSSL FLAVOR

        We try Homebrew's openssl@3 first (`/opt/homebrew/opt/openssl@3/bin/openssl`)
        because the bundled `/usr/bin/openssl` on macOS is LibreSSL and
        doesn't understand the `-legacy` flag we need for the PKCS#12
        wrapper that SecPKCS12Import accepts. If you don't have brew
        openssl, install with `brew install openssl@3` before running
        this command.
        """
    )

    @Option(name: .customLong("cn"), help: "Common Name for the CA cert (default: 'cocker-ca')")
    var commonName: String = "cocker-ca"

    @Option(name: .customLong("host"), help: "Hostname / IP the TLS cert will validate against")
    var host: String = "localhost"

    @Option(name: .customLong("days"), help: "Validity in days (default 365)")
    var days: Int = 365

    @Flag(name: .customLong("force"), help: "Overwrite existing certs in ~/.cocker/tls/")
    var force = false

    mutating func run() async throws {
        let tlsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cocker/tls")
        if FileManager.default.fileExists(atPath: tlsDir.path), !force {
            fputs("Existing TLS dir at \(tlsDir.path). Pass --force to overwrite.\n", stderr)
            throw ExitCode(1)
        }
        try FileManager.default.createDirectory(at: tlsDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        // We delegate the actual cert math to openssl. The recipe mirrors
        // Docker's documented mTLS quickstart almost line-for-line so
        // clients that already work against `dockerd --tlsverify` work
        // here unmodified.
        // openssl on PATH (use system one not Homebrew's potentially) :
        // /usr/bin/openssl is the macOS-shipped LibreSSL which doesn't
        // support -legacy. We prefer Homebrew's openssl@3 if present
        // since its `-legacy` (real OpenSSL) is needed for the
        // SecPKCS12Import wire format.
        let opensslPath: String = {
            for p in ["/opt/homebrew/opt/openssl@3/bin/openssl",
                      "/opt/homebrew/bin/openssl",
                      "/usr/local/opt/openssl@3/bin/openssl",
                      "/usr/local/bin/openssl",
                      "/usr/bin/openssl"] {
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
            return "/usr/bin/openssl"
        }()
        func run(_ args: [String], stdin: String? = nil) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: opensslPath)
            p.arguments = args
            p.currentDirectoryURL = tlsDir
            let errPipe = Pipe()
            p.standardError = errPipe
            if let stdin {
                let pipe = Pipe()
                p.standardInput = pipe
                try p.run()
                pipe.fileHandleForWriting.write(Data(stdin.utf8))
                try pipe.fileHandleForWriting.close()
                p.waitUntilExit()
            } else {
                try p.run()
                p.waitUntilExit()
            }
            guard p.terminationStatus == 0 else {
                let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                throw CockerError.requestFailed(
                    "openssl \(args.joined(separator: " ")) (using \(opensslPath)) " +
                    "exited \(p.terminationStatus) : \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
        }

        print("Generating CA, server, and client certs in \(tlsDir.path)...")

        // We use ECDSA (P-256) for every cert, not RSA. On macOS the
        // RSA private key produced by SecPKCS12Import is backed by the
        // legacy CSSM keychain, and boringssl can't drive it through
        // the TLS 1.3 RSA-PSS signature path — it fails with
        // CSSMERR_CSP_INVALID_KEYATTR_MASK. ECDSA bypasses that whole
        // family of bugs. The CA stays RSA-4096 ; only the leaf keys
        // need to be ECDSA because only those are passed to boringssl.
        // Actually we use EC for the CA too — keeps the bundle small
        // and there's no reason for a self-signed dev CA to be RSA.

        // CA — EC P-256
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca-key.pem"])
        try run(["req", "-new", "-x509", "-days", String(days),
                 "-key", "ca-key.pem", "-sha256", "-out", "ca.pem",
                 "-subj", "/CN=\(commonName)"])

        // Server — EC P-256
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "server-key.pem"])
        try run(["req", "-subj", "/CN=\(host)", "-sha256", "-new",
                 "-key", "server-key.pem", "-out", "server.csr"])
        let extfile = """
        subjectAltName = DNS:\(host),IP:127.0.0.1,IP:0.0.0.0
        extendedKeyUsage = serverAuth
        """
        try Data(extfile.utf8).write(to: tlsDir.appendingPathComponent("extfile.cnf"))
        try run(["x509", "-req", "-days", String(days), "-sha256",
                 "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca-key.pem",
                 "-CAcreateserial", "-out", "server-cert.pem",
                 "-extfile", "extfile.cnf"])

        // Client — EC P-256
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "key.pem"])
        try run(["req", "-subj", "/CN=client", "-new",
                 "-key", "key.pem", "-out", "client.csr"])
        let clientExt = """
        extendedKeyUsage = clientAuth
        """
        try Data(clientExt.utf8).write(to: tlsDir.appendingPathComponent("extfile-client.cnf"))
        try run(["x509", "-req", "-days", String(days), "-sha256",
                 "-in", "client.csr", "-CA", "ca.pem", "-CAkey", "ca-key.pem",
                 "-CAcreateserial", "-out", "cert.pem",
                 "-extfile", "extfile-client.cnf"])

        // Lock down secrets (private keys + CA private key).
        for name in ["ca-key.pem", "server-key.pem", "key.pem"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tlsDir.appendingPathComponent(name).path
            )
        }
        // Bundle server identity into a PKCS#12 the daemon can load via
        // SecPKCS12Import → SecIdentity. Two non-obvious quirks :
        //  - `-legacy` : OpenSSL 3.x defaults to PBKDF2-HMAC-SHA256 +
        //    AES-256-CBC which macOS's Security framework still can't
        //    parse (returns errSecAuthFailed -25293). RC2/SHA1 works.
        //  - Non-empty passphrase : SecPKCS12Import on an empty-password
        //    bundle returns -25293 too. Stash a fixed value in
        //    `server.p12.pass` (0600) so the daemon can read it back.
        let p12Pass = "cocker"
        try run(["pkcs12", "-export",
                 "-in", "server-cert.pem", "-inkey", "server-key.pem",
                 "-out", "server.p12", "-passout", "pass:\(p12Pass)",
                 "-legacy"])
        try Data(p12Pass.utf8).write(to: tlsDir.appendingPathComponent("server.p12.pass"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tlsDir.appendingPathComponent("server.p12.pass").path
        )
        // Build the CA trust bundle clients use (DOCKER_CERT_PATH).
        // ca.pem already covers it ; just stamp 0o644 so it's readable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: tlsDir.appendingPathComponent("ca.pem").path
        )

        // Clean up CSRs and the extfiles ; keep the .srl files for renewals.
        for tmp in ["server.csr", "client.csr", "extfile.cnf", "extfile-client.cnf"] {
            try? FileManager.default.removeItem(at: tlsDir.appendingPathComponent(tmp))
        }

        print("""
        ✓ TLS certs written to \(tlsDir.path)

        Server side — start cockerd with TLS exposed on port 2376 :
            COCKER_TCP_TLS_PORT=2376 cocker daemon restart

        Client side — point any Docker tool at the TCP socket :
            export DOCKER_HOST=tcp://\(host):2376
            export DOCKER_TLS_VERIFY=1
            export DOCKER_CERT_PATH=\(tlsDir.path)
            docker ps

        Files :
          ca.pem          — CA cert (share with clients to trust the daemon)
          cert.pem        — client cert (DOCKER_CERT_PATH/cert.pem)
          key.pem         — client private key (0600)
          server.p12      — daemon's PKCS#12 identity bundle (loaded by cockerd)
        """)
    }
}

/// `cocker daemon clear-leases` — truncates macOS's vmnet bootpd lease
/// file (`/var/db/dhcpd_leases`). Required when the pool saturates around
/// 256 entries and new containers fail DHCP. The file is root-owned, so
/// we shell out to `sudo` ; the user gets a password prompt unless they
/// installed the LaunchDaemon helper (`cocker daemon helper-install`).
struct DaemonClearLeasesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-leases",
        abstract: "Truncate /var/db/dhcpd_leases (frees macOS vmnet's DHCP pool)"
    )

    mutating func run() async throws {
        let path = "/var/db/dhcpd_leases"
        // Fast path : the LaunchDaemon helper, if installed, watches a
        // trigger file ; touching it asks the root-owned helper to do
        // the clear without prompting for a sudo password.
        let trigger = "/var/run/cocker-clear-leases"
        let triggerURL = URL(fileURLWithPath: trigger)
        if FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.cocker.leases-helper.plist") {
            try? Data().write(to: triggerURL)
            // Wait briefly for the helper to consume the trigger and clear.
            for _ in 0..<20 {
                if !FileManager.default.fileExists(atPath: trigger) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let s = try? String(contentsOfFile: path, encoding: .utf8) {
                let n = s.components(separatedBy: "ip_address=").count - 1
                print("Leases now: \(n) entries.")
                return
            }
        }
        // Slow path : sudo prompt.
        print("Clearing \(path) (sudo will prompt for your password)…")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["sh", "-c", "echo > \(path)"]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            fputs("Error: sudo failed (exit \(proc.terminationStatus))\n", stderr)
            throw ExitCode.failure
        }
        print("Leases cleared. New containers will get fresh IPs.")
    }
}

/// `cocker daemon helper-install` — installs a LaunchDaemon that watches
/// `/var/run/cocker-clear-leases` and truncates the lease file whenever
/// the trigger appears. Avoids the sudo prompt every time the pool fills.
struct DaemonHelperInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper-install",
        abstract: "Install the lease-clearing LaunchDaemon (one sudo prompt)",
        discussion: """
        macOS's vmnet bootpd caps `/var/db/dhcpd_leases` at ~256 entries.
        Past that, new containers can't get an IP and `cocker run` produces
        a half-broken container (port-forwarding stuck on 127.0.0.1).

        This command installs a tiny LaunchDaemon at
        /Library/LaunchDaemons/com.cocker.leases-helper.plist that runs
        as root and watches /var/run/cocker-clear-leases. Whenever cockerd
        sees the lease count climb above 200, it touches the trigger file
        and the helper truncates the lease pool — no sudo prompt, no
        manual intervention. The helper persists across reboots and
        cockerd restarts.

        You only need to run this command ONCE per machine. After that,
        the issue is solved permanently.

        The one-shot alternative if you don't want to install the helper :
        `cocker daemon clear-leases` (prompts for sudo each call).

        The helper's plist + behaviour are inspectable via
        `launchctl list | grep cocker` and
        `cat /Library/LaunchDaemons/com.cocker.leases-helper.plist`.
        """
    )

    mutating func run() async throws {
        let plistPath = "/Library/LaunchDaemons/com.cocker.leases-helper.plist"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.cocker.leases-helper</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/sh</string>
            <string>-c</string>
            <string>while true; do if [ -f /var/run/cocker-clear-leases ]; then echo > /var/db/dhcpd_leases; rm -f /var/run/cocker-clear-leases; fi; sleep 1; done</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardErrorPath</key>
          <string>/var/log/cocker-leases-helper.log</string>
        </dict>
        </plist>
        """

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-leases-helper.plist")
        try plist.write(to: tmp, atomically: true, encoding: .utf8)
        print("Installing LaunchDaemon at \(plistPath) (sudo will prompt for your password)…")
        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        install.arguments = ["sh", "-c",
            "install -m 644 -o root -g wheel \(tmp.path) \(plistPath) && " +
            "launchctl bootstrap system \(plistPath) 2>/dev/null || launchctl load \(plistPath)"]
        try install.run()
        install.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
        guard install.terminationStatus == 0 else {
            fputs("Error: install failed (exit \(install.terminationStatus))\n", stderr)
            throw ExitCode.failure
        }
        print("✓ Helper installed and running.")
        print("  Subsequent `cocker daemon clear-leases` calls will skip the sudo prompt.")
    }
}

// MARK: - Helpers

private struct DaemonPaths {
    let root: URL
    var pidFile: URL { root.appendingPathComponent("cockerd.pid") }
    var logFile: URL { root.appendingPathComponent("cockerd.log") }
    var ipcSock: URL { root.appendingPathComponent("cocker.sock") }
}

private func defaultPaths() -> DaemonPaths {
    // Derive root from env so SUFFIX=-dev installs (wrapper sets
    // COCKER_HOST=unix://~/.cocker-dev/cocker.sock) don't accidentally
    // operate on the prod data dir. Order of precedence : explicit
    // COCKER_ROOT > COCKER_HOST socket dirname > ~/.cocker fallback.
    // `daemon start` propagates the resolved root to cockerd as
    // --root/--socket args ; without this the subcommand spawned a
    // prod-rooted daemon even when the wrapper set COCKER_HOST.
    let root: URL
    if let envRoot = ProcessInfo.processInfo.environment["COCKER_ROOT"], !envRoot.isEmpty {
        root = URL(fileURLWithPath: envRoot)
    } else if let host = ProcessInfo.processInfo.environment["COCKER_HOST"],
              host.hasPrefix("unix://") {
        let sock = String(host.dropFirst("unix://".count))
        root = URL(fileURLWithPath: sock).deletingLastPathComponent()
    } else {
        root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cocker")
    }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return DaemonPaths(root: root)
}

/// True when `paths.root` isn't the conventional ~/.cocker default.
/// Used by `daemon start` to decide whether to pass --root/--socket to
/// the cockerd it spawns (no-args = ~/.cocker for backwards compat).
private func isNonDefaultRoot(_ root: URL) -> Bool {
    let defaultRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cocker")
    return root.standardizedFileURL.path != defaultRoot.standardizedFileURL.path
}

/// Derive the launchd plist path for a given data dir. Mirrors what
/// install.sh writes : `~/.cocker` → `com.cocker.cockerd.plist`,
/// `~/.cocker-dev` → `com.cocker.cockerd-dev.plist`. The suffix is the
/// part of the data dir's basename after `.cocker` (empty for prod).
private func launchdPlistPath(for root: URL) -> URL {
    let base = root.lastPathComponent          // .cocker, .cocker-dev, …
    let suffix: String
    if base == ".cocker" {
        suffix = ""
    } else if base.hasPrefix(".cocker") {
        suffix = String(base.dropFirst(".cocker".count))
    } else {
        suffix = ""
    }
    return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/LaunchAgents/com.cocker.cockerd\(suffix).plist")
}

/// Run /bin/launchctl with the given args. Surfaces stderr on failure
/// so the user gets the actual reason (already loaded, no such job, …)
/// rather than a generic "command exited non-zero".
@discardableResult
private func runLaunchctl(_ args: [String]) throws -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = args
    let errPipe = Pipe()
    proc.standardError = errPipe
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw ValidationError(
            "launchctl \(args.joined(separator: " ")) exited " +
            "\(proc.terminationStatus): \(stderr.isEmpty ? "(no stderr)" : stderr)"
        )
    }
    return proc.terminationStatus
}

/// Read the PID from the PID file ; nil if the file doesn't exist or is
/// malformed. Does NOT verify the process is alive — call `isAlive(_:)` after.
private func readPID(_ url: URL) -> pid_t? {
    PIDFile.read(url)
}

/// kill(pid, 0) returns 0 if the process exists and we can signal it.
private func isAlive(_ pid: pid_t) -> Bool {
    PIDFile.isAlive(pid)
}

/// Find a cockerd binary. Delegates to BinaryResolver in CockerCore.
private func resolveCockerdBinary(explicit: String?) -> String? {
    BinaryResolver.find(name: "cockerd",
                        explicit: explicit,
                        siblingTo: CommandLine.arguments[0])
}

// MARK: - start

struct DaemonStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start cockerd in the background",
        discussion: """
        Spawns cockerd as a detached background process. The daemon
        listens on three sockets simultaneously :
          - ~/.cocker/cocker.sock    native CLI IPC
          - ~/.cocker/docker.sock    Docker Engine API v1.41 (Unix)
          - tcp://0.0.0.0:<port>     same Docker API over TLS (optional)

        TLS over TCP is opt-in. Set COCKER_TCP_TLS_PORT before
        starting :
            COCKER_TCP_TLS_PORT=2376 cocker daemon start
        and the daemon brings up a 4th listener at port 2376 with
        mutual-TLS. See `cocker daemon tls-init --help` for the cert
        layout and the design notes.

        FIRST-BOOT WITH TLS — WHY IT TAKES ~10 s

        macOS's keychain machinery has a one-time ACL bootstrap that
        runs the first time a freshly-imported private key is used.
        That bootstrap can take 9-12 seconds. cockerd performs this
        sign synchronously at boot (one dummy signature), BEFORE
        opening the port — otherwise the first incoming client would
        time out waiting for its TLS handshake to complete. So the
        first `cocker daemon start` after a `tls-init` (and every
        start that follows a daemon restart) eats ~10 s before the
        socket accepts. The cost vanishes after that — all subsequent
        TLS handshakes complete in milliseconds for the life of the
        process.

        LEASE-POOL HELPER HINT

        On a fresh machine the daemon logs an INFO once at startup
        reminding you to run `cocker daemon helper-install` for
        automatic recovery from macOS's 256-IP DHCP cap (see
        `cocker daemon helper-install --help`). One sudo prompt, then
        the daemon never asks again.

        Use `cocker daemon stop` to terminate, `cocker daemon status`
        to inspect state, `cocker daemon logs -f` to tail the log.
        """
    )

    @Option(name: .customLong("binary"),
            help: "Path to the cockerd binary (defaults to autodetect)")
    var binary: String?

    @Flag(name: .customLong("foreground"),
          help: "Run cockerd in the foreground (Ctrl-C to stop) — same as just `cockerd`")
    var foreground = false

    @Flag(name: [.short, .customLong("service")],
          help: "Bootstrap the launchd job instead of spawning a one-off process (use after install.sh).")
    var service = false

    mutating func run() async throws {
        let paths = defaultPaths()

        // --service / -s : delegate to launchd. install.sh shipped a plist
        // at ~/Library/LaunchAgents/com.cocker.cockerd${suffix}.plist that
        // has RunAtLoad=true and KeepAlive=true ; `launchctl bootstrap`
        // loads it AND starts the daemon. Different code path entirely
        // from the PID-file-based spawn below.
        if service {
            let plist = launchdPlistPath(for: paths.root)
            guard FileManager.default.fileExists(atPath: plist.path) else {
                throw ValidationError(
                    "No launchd plist at \(plist.path). " +
                    "Did you install via ./install.sh ? Without it there's no service to manage."
                )
            }
            try runLaunchctl(["bootstrap", "gui/\(getuid())", plist.path])
            print("✓ launchd job \(plist.lastPathComponent) bootstrapped")
            print("  KeepAlive=true → daemon auto-restarts on crash")
            print("  → cocker daemon status     to inspect")
            print("  → cocker daemon stop -s    to stop (no respawn)")
            return
        }

        if let pid = readPID(paths.pidFile), isAlive(pid) {
            print("cockerd is already running (pid \(pid))")
            print("→ cocker daemon status   to see details")
            print("→ cocker daemon stop     to stop it")
            return
        }

        guard let cockerd = resolveCockerdBinary(explicit: binary) else {
            throw ValidationError("Could not find a cockerd binary. " +
                "Use --binary <path>, or install via `brew install cocker`.")
        }

        if foreground {
            // Just exec cockerd in-place.
            execv(cockerd, [cockerd, nil].compactMap { $0 }.map { strdup($0) })
            throw ValidationError("execv failed")
        }

        // Background spawn. We redirect stdout+stderr into the log file and
        // detach from the controlling terminal so the process survives the
        // shell that launched it.
        let log = FileHandle(forWritingAtPath: paths.logFile.path)
            ?? {
                FileManager.default.createFile(atPath: paths.logFile.path,
                                               contents: nil)
                return FileHandle(forWritingAtPath: paths.logFile.path)!
            }()
        try? log.seekToEnd()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cockerd)
        // For SUFFIX=-dev installs the wrapper sets COCKER_HOST and our
        // defaultPaths() derives a non-default root from it. Pass that
        // through as explicit --root/--socket flags so the spawned daemon
        // uses the alternate data dir instead of falling back to the
        // ~/.cocker hard-coded default.
        if isNonDefaultRoot(paths.root) {
            proc.arguments = [
                "--root",   paths.root.path,
                "--socket", paths.ipcSock.path,
            ]
        }
        proc.standardOutput = log
        proc.standardError = log
        proc.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        try proc.run()

        // Wait briefly for cockerd to write its PID file (it does so on
        // startup, before binding sockets). If it never appears, surface
        // whatever cockerd printed to the log.
        let started = Date()
        while Date().timeIntervalSince(started) < 5 {
            if let pid = readPID(paths.pidFile), isAlive(pid) {
                print("✓ cockerd started (pid \(pid))")
                print("  log : \(paths.logFile.path)")
                print()
                print("  → cocker daemon status")
                print("  → cocker daemon logs -f")
                print("  → cocker daemon stop")
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Didn't see a PID file — dump the tail of the log so the user gets
        // a clue.
        print("✗ cockerd failed to start within 5 s. Last lines of log :")
        if let data = try? String(contentsOf: paths.logFile) {
            for line in data.split(separator: "\n").suffix(15) {
                print("  \(line)")
            }
        }
        throw ExitCode.failure
    }
}

// MARK: - stop

struct DaemonStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the background cockerd process"
    )

    @Option(name: .customLong("timeout"),
            help: "Seconds to wait for graceful shutdown before SIGKILL")
    var timeout: Int = 10

    @Flag(name: [.short, .customLong("service")],
          help: "Bootout the launchd job so KeepAlive doesn't respawn it (counterpart to `daemon start -s`).")
    var service = false

    mutating func run() async throws {
        let paths = defaultPaths()

        // --service / -s : bootout the launchd job. SIGTERM would normally
        // get instantly undone by KeepAlive=true ; bootout removes the
        // job from launchd's bookkeeping so no respawn happens until the
        // user bootstraps it again (`daemon start -s` or relog).
        if service {
            let plist = launchdPlistPath(for: paths.root)
            guard FileManager.default.fileExists(atPath: plist.path) else {
                throw ValidationError(
                    "No launchd plist at \(plist.path). " +
                    "There's no service to stop ; you probably want `cocker daemon stop` (no -s)."
                )
            }
            try runLaunchctl(["bootout", "gui/\(getuid())", plist.path])
            try? FileManager.default.removeItem(at: paths.pidFile)
            print("✓ launchd job \(plist.lastPathComponent) booted out (no respawn)")
            print("  → cocker daemon start -s   to bring it back up")
            return
        }

        guard let pid = readPID(paths.pidFile), isAlive(pid) else {
            print("cockerd is not running")
            try? FileManager.default.removeItem(at: paths.pidFile)
            return
        }

        print("Stopping cockerd (pid \(pid))…")
        _ = kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while isAlive(pid) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        if isAlive(pid) {
            print("✗ still alive after \(timeout) s, sending SIGKILL")
            _ = kill(pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        try? FileManager.default.removeItem(at: paths.pidFile)
        print("✓ cockerd stopped")
    }
}

// MARK: - restart

struct DaemonRestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Stop then start the cockerd background process"
    )

    @Option(name: .customLong("binary"),
            help: "Path to the cockerd binary (defaults to autodetect)")
    var binary: String?

    @Flag(name: [.short, .customLong("service")],
          help: "Bootout + bootstrap the launchd job instead of SIGTERM-then-spawn (use after install.sh).")
    var service = false

    mutating func run() async throws {
        // ArgumentParser only initializes @Option/@Flag values during parse().
        // Direct `Type()` instantiation leaves them unset and crashes the run.
        var stop = try DaemonStopCommand.parse([])
        stop.service = service
        try await stop.run()
        var start = try DaemonStartCommand.parse([])
        start.binary = binary
        start.service = service
        try await start.run()
    }
}

// MARK: - status

struct DaemonStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether cockerd is running"
    )

    mutating func run() async throws {
        let paths = defaultPaths()
        guard let pid = readPID(paths.pidFile) else {
            print("● cockerd is not running")
            print("  → cocker daemon start")
            return
        }
        if !isAlive(pid) {
            print("✗ cockerd is not running (stale pid file)")
            try? FileManager.default.removeItem(at: paths.pidFile)
            print("  → cocker daemon start")
            return
        }

        // Process started-at via getpriority/proc_pidinfo would need extra
        // syscalls ; the mtime of the PID file is good enough as an uptime
        // proxy.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: paths.pidFile.path)[.modificationDate]) as? Date
        let uptime = mtime.map { Date().timeIntervalSince($0) }

        print("✓ cockerd is running")
        print("  pid     \(pid)")
        if let u = uptime {
            let h = Int(u) / 3600, m = (Int(u) % 3600) / 60, s = Int(u) % 60
            print("  uptime  \(String(format: "%02d:%02d:%02d", h, m, s))")
        }
        print("  log     \(paths.logFile.path)")
        print("  ipc     \(paths.ipcSock.path)")

        // Try a ping over the IPC socket to confirm it's accepting requests.
        if FileManager.default.fileExists(atPath: paths.ipcSock.path) {
            print("  socket  reachable")
        } else {
            print("  socket  MISSING — daemon may still be booting")
        }

        // Lease pool + helper status. macOS's bootpd caps at ~256 ;
        // we show the live count so the operator can spot saturation
        // without having to `tail -f` the daemon log for the 30 s
        // watchdog warnings. The helper line tells them which
        // remediation command applies (one-shot vs. install-and-forget).
        let leaseFile = "/var/db/dhcpd_leases"
        if let leases = try? String(contentsOfFile: leaseFile, encoding: .utf8) {
            let count = leases.components(separatedBy: "ip_address=").count - 1
            let marker: String
            switch count {
            case 0..<200:  marker = "OK"
            case 200..<240: marker = "elevated"
            case 240..<252: marker = "WARNING"
            default:       marker = "SATURATED"
            }
            print("  leases  \(count)/256 (\(marker))")
        }
        let helperPath = "/Library/LaunchDaemons/com.cocker.leases-helper.plist"
        if FileManager.default.fileExists(atPath: helperPath) {
            print("  helper  installed (auto-clears at >200 leases)")
        } else {
            print("  helper  not installed — `cocker daemon helper-install` to fix forever")
        }
    }
}

// MARK: - logs

struct DaemonLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show cockerd log output"
    )

    @Flag(name: [.short, .customLong("follow")],
          help: "Follow the log as it grows (like `tail -f`)")
    var follow = false

    @Option(name: .customLong("tail"),
            help: "Print the last N lines (default 50)")
    var tail: Int = 50

    @Flag(name: .customLong("no-color"),
          help: "Disable level/module colorization (forced off when stdout isn't a TTY)")
    var noColor = false

    mutating func run() async throws {
        let paths = defaultPaths()
        guard FileManager.default.fileExists(atPath: paths.logFile.path) else {
            print("No log file at \(paths.logFile.path).")
            print("Try `cocker daemon start` first.")
            return
        }

        // We still use `tail` for the platform-correct -n / -f / log
        // rotation handling, but pipe its output through our colorizer
        // so each line gets ANSI escapes applied by log level. cockerd
        // writes plain text to its log file (the file is consumed by
        // grep / log aggregators that don't want escape sequences), so
        // re-colorizing has to happen at read time.
        var args: [String] = []
        args.append(contentsOf: ["-n", "\(tail)"])
        if follow { args.append("-f") }
        args.append(paths.logFile.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        proc.arguments = args

        // Force-off colors if redirected (typical: `cocker daemon logs >
        // session.log`). Mirrors how `ls` / `git` decide on color.
        let useColor = !noColor && isatty(fileno(stdout)) != 0

        if !useColor {
            // Hot path : no colorizer at all, pass `tail` straight
            // through to inherit stdout. Cheaper than piping when the
            // user just wants to grep.
            try proc.run()
            proc.waitUntilExit()
            return
        }

        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()

        let colorizer = LogColorizer()
        let handle = pipe.fileHandleForReading
        var carry = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if !proc.isRunning { break }
                continue
            }
            carry.append(chunk)
            while let nlRange = carry.range(of: Data([0x0A])) {
                let lineData = carry.subdata(in: 0..<nlRange.lowerBound)
                carry.removeSubrange(0..<nlRange.upperBound)
                if let line = String(data: lineData, encoding: .utf8) {
                    print(colorizer.render(line))
                }
            }
        }
        if !carry.isEmpty, let line = String(data: carry, encoding: .utf8) {
            print(colorizer.render(line))
        }
        proc.waitUntilExit()
    }
}

/// Re-colorize cockerd log lines on the fly. The on-disk format is
/// plain text — `<iso-timestamp>  <LEVEL>   [<module>] <message>` —
/// because consumers like `grep`, log shippers, and `journalctl`-style
/// tooling all assume escape-free input. So we don't make cockerd emit
/// ANSI to its file ; we apply colors here, in the user-facing reader.
///
/// Color choices match what cockerd's banner-time stdout uses when run
/// in the foreground :
///   - timestamp: dim grey (de-emphasize, the eye lands on level)
///   - INFO  : green
///   - WARN  : yellow
///   - ERROR : red
///   - DEBUG : dim
///   - [module] : cyan
///   - message body : default fg
struct LogColorizer {
    // Single regex with named-ish capture groups would be cleaner but
    // pulls in NSRegularExpression machinery for very little gain in
    // a hot loop. The format is rigid enough that a hand-rolled
    // splitter is both faster and easier to maintain.
    func render(_ line: String) -> String {
        // Lines that don't match our format (banner art, multi-line
        // stack traces, etc.) pass through untouched — better than
        // accidentally mangling something we can't classify.
        guard let leveled = splitLevel(line) else { return line }

        let timestamp = ANSI.colored(leveled.timestamp, ANSI.dim)
        let levelColor: String
        switch leveled.level {
        case "INFO":  levelColor = ANSI.green
        case "WARN", "WARNING": levelColor = ANSI.yellow
        case "ERROR", "FATAL":  levelColor = ANSI.red
        case "DEBUG", "TRACE":  levelColor = ANSI.dim
        default: levelColor = ANSI.reset
        }
        let level = ANSI.colored(leveled.level.padding(toLength: 5, withPad: " ", startingAt: 0), levelColor)
        let rest = colorizeModule(in: leveled.rest)
        return "\(timestamp)  \(level)  \(rest)"
    }

    private struct LeveledLine {
        let timestamp: String
        let level: String
        let rest: String
    }

    /// Parse `<timestamp>  <LEVEL>   <rest>` (two+ spaces between).
    /// Tolerant of any whitespace count so we don't drift if cockerd
    /// ever changes its formatter alignment.
    private func splitLevel(_ line: String) -> LeveledLine? {
        // Timestamp is fixed-width ISO-8601 with `Z` suffix : it's
        // exactly 24 chars long in cockerd's formatter. Bail if the
        // line is shorter or doesn't end with `Z` at index 23.
        guard line.count >= 30 else { return nil }
        let tsEnd = line.index(line.startIndex, offsetBy: 24)
        let timestamp = String(line[..<tsEnd])
        guard timestamp.hasSuffix("Z") else { return nil }
        let after = line[tsEnd...].drop(while: { $0 == " " })
        // Level is one ASCII word followed by whitespace.
        guard let wordEnd = after.firstIndex(where: { $0 == " " }) else { return nil }
        let level = String(after[..<wordEnd])
        let knownLevels: Set<String> = ["INFO", "WARN", "WARNING", "ERROR", "FATAL", "DEBUG", "TRACE"]
        guard knownLevels.contains(level.uppercased()) else { return nil }
        let rest = String(after[wordEnd...].drop(while: { $0 == " " }))
        return LeveledLine(timestamp: timestamp, level: level.uppercased(), rest: rest)
    }

    /// Cyan-ify any `[module]` prefix the log emitter wrote.
    private func colorizeModule(in body: String) -> String {
        guard body.hasPrefix("["), let close = body.firstIndex(of: "]") else {
            return body
        }
        let module = String(body[body.startIndex...close])
        let tail = String(body[body.index(after: close)...])
        return ANSI.colored(module, ANSI.cyan) + tail
    }
}
