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
            DaemonResignCommand.self,
            DaemonSetupCommand.self,
            DaemonInitCommand.self,
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
/// `cocker daemon resign` — re-sign cockerd with the user's Apple
/// Development certificate so it can launch VMs without ad-hoc
/// fallback. Necessary after `brew install` because Homebrew's
/// post_install runs inside a sandbox that denies access to
/// `~/Library/Keychains/`, so `security find-identity` returns
/// empty and the formula has to fall back to ad-hoc signing.
/// Run from the user's shell (outside the sandbox), this command
/// reads the real keychain and re-signs in place.
struct DaemonResignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resign",
        abstract: "Re-sign cockerd with your Apple Development cert (post-brew-install)",
        discussion: """
        Why this exists : `brew install cocker`'s post-install hook can't
        read your login keychain — Homebrew sandboxes it away — so cockerd
        ends up ad-hoc signed. That's fine for local boot, but the
        TeamIdentifier is missing and the binary can't be moved between
        machines. This command runs `security find-identity` outside the
        sandbox, picks the first Apple Development (or Developer ID
        Application) cert, and resigns the brew-installed cockerd with it.

        Run it once after `brew install cocker` or `brew upgrade cocker`.

        Override the cert by passing --identity "<full cert name>".
        """
    )

    @Option(name: [.short, .customLong("identity")],
            help: "Signing identity to use (defaults to the first Apple Development cert found).")
    var identity: String?

    @Option(name: .customLong("cockerd"),
            help: "Path to the cockerd binary to resign (defaults to /opt/homebrew/opt/cocker/bin/cockerd).")
    var cockerdPath: String = "/opt/homebrew/opt/cocker/bin/cockerd"

    @Option(name: .customLong("entitlements"),
            help: "Path to the entitlements plist (defaults to /opt/homebrew/share/cocker/cockerd.entitlements).")
    var entitlementsPath: String = "/opt/homebrew/share/cocker/cockerd.entitlements"

    mutating func run() async throws {
        guard FileManager.default.isExecutableFile(atPath: cockerdPath) else {
            UX.Failure.emit(headline: "cockerd not found",
                            reason: cockerdPath,
                            hint: "reinstall with `brew reinstall cocker`")
            fputs("Pass --cockerd <path> if you installed it elsewhere.\n", stderr)
            throw ExitCode.failure
        }
        guard FileManager.default.fileExists(atPath: entitlementsPath) else {
            UX.Failure.emit(headline: "Entitlements file not found",
                            reason: entitlementsPath,
                            hint: "run this from a source checkout, or reinstall cocker")
            throw ExitCode.failure
        }

        // Resolve the signing identity.
        let cert: String
        if let explicit = identity {
            cert = explicit
        } else if let detected = try Self.detectIdentity() {
            cert = detected
        } else {
            UX.Failure.emit(headline: "No signing certificate in your keychain",
                            reason: "need an \"Apple Development\" or \"Developer ID Application\" identity",
                            hint: "create one in Xcode → Settings → Accounts → Manage Certificates")
            fputs("Generate one in Xcode → Settings → Accounts → Manage Certificates → +.\n", stderr)
            throw ExitCode.failure
        }
        print("Signing \(cockerdPath) with: \(cert)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = [
            "--force",
            "--sign", cert,
            "--entitlements", entitlementsPath,
            cockerdPath,
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        if !errData.isEmpty {
            fputs(String(data: errData, encoding: .utf8) ?? "", stderr)
        }
        guard proc.terminationStatus == 0 else {
            fputs("codesign failed (exit \(proc.terminationStatus)).\n", stderr)
            throw ExitCode.failure
        }
        print("Signed. Restart the daemon to pick up the new signature:")
        print("  brew services restart cocker")
    }

    /// Shells out to `/usr/bin/security find-identity -v -p codesigning`
    /// and returns the first matching Apple Development / Developer ID
    /// Application certificate, or nil if none found.
    private static func detectIdentity() throws -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let outStr = String(data: outData, encoding: .utf8) ?? ""

        for kind in ["Apple Development", "Developer ID Application"] {
            for line in outStr.split(separator: "\n") {
                if line.contains(kind),
                   let openIdx = line.firstIndex(of: "\""),
                   let closeIdx = line.lastIndex(of: "\""),
                   openIdx < closeIdx {
                    return String(line[line.index(after: openIdx)..<closeIdx])
                }
            }
        }
        return nil
    }
}

/// `cocker daemon setup` — refresh `~/.cocker/kernel/` from the user's
/// shell (outside Homebrew's sandbox). Run after `brew install` or
/// `brew upgrade cocker` if you saw the "post-install step did not
/// complete successfully" warning, OR after installing apple/container
/// to pick up the Linux kernel symlink.
struct DaemonSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Refresh ~/.cocker/kernel/ (symlink Apple kernel + copy initrd)",
        discussion: """
        Why this exists : `brew install cocker`'s post-install hook tries
        to write to ~/.cocker/kernel/ but Homebrew's sandbox denies writes
        outside its own dirs, so the warning "post-install step did not
        complete successfully" surfaces even when cocker boots fine via
        the existing symlinks. This command runs the same steps in your
        shell context where the writes actually go through.

        What it does :
          1. Refresh ~/.cocker/kernel/vmlinuz → symlink to Apple's Linux
             kernel at ~/Library/Application Support/com.apple.container/
             kernels/default.kernel-arm64.
          2. Refresh ~/.cocker/kernel/initrd.img → copy of the cocker-init
             initrd shipped with the binary (<prefix>/share/cocker/initrd.img).
        """
    )

    @Option(name: .customLong("share-prefix"),
            help: "Prefix containing share/cocker (defaults to /opt/homebrew or /usr/local).")
    var sharePrefix: String?

    mutating func run() async throws {
        let home = NSHomeDirectory()
        let cockerRoot = home + "/.cocker"
        let kernelDir = cockerRoot + "/kernel"
        let fm = FileManager.default
        try fm.createDirectory(atPath: kernelDir, withIntermediateDirectories: true)

        // 1. Apple kernel symlink
        let appleKernel = "\(home)/Library/Application Support/com.apple.container/kernels/default.kernel-arm64"
        if fm.fileExists(atPath: appleKernel) {
            let resolved = URL(fileURLWithPath: appleKernel).resolvingSymlinksInPath().path
            let vmlinuz = kernelDir + "/vmlinuz"
            try? fm.removeItem(atPath: vmlinuz)
            try fm.createSymbolicLink(atPath: vmlinuz, withDestinationPath: resolved)
            print("✓ Linked kernel: \(vmlinuz) → \((resolved as NSString).lastPathComponent)")
        } else {
            print("⚠ Apple kernel not found at \(appleKernel)")
            print("  Install Apple's container CLI: brew install container")
        }

        // 2. Initrd copy from share/cocker/
        let prefix = sharePrefix ?? Self.detectSharePrefix()
        let srcInitrd = prefix + "/share/cocker/initrd.img"
        guard fm.fileExists(atPath: srcInitrd) else {
            UX.Failure.emit(headline: "initrd not found",
                            reason: "\(srcInitrd)",
                            hint: "reinstall cocker, or build it with scripts/build-initrd.sh")
            fputs("Pass --share-prefix <prefix> if cocker was installed elsewhere.\n", stderr)
            throw ExitCode.failure
        }
        let target = kernelDir + "/initrd.img"
        try? fm.removeItem(atPath: target)
        try fm.copyItem(atPath: srcInitrd, toPath: target)
        print("✓ Installed initrd: \(target)")
    }

    /// Pick the brew share prefix by file existence — Apple Silicon
    /// default vs Intel/legacy. Falls back to /opt/homebrew when
    /// neither exists ; that's the most common installs.
    private static func detectSharePrefix() -> String {
        for p in ["/opt/homebrew", "/usr/local"] {
            if FileManager.default.fileExists(atPath: p + "/share/cocker/initrd.img") {
                return p
            }
        }
        return "/opt/homebrew"
    }
}

/// `cocker daemon init` — single command that walks through every
/// post-`brew install` step with a TUX-style checklist and fixes
/// whatever needs fixing. Idempotent ; safe to re-run any time.
struct DaemonInitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "One-command post-install: resign + setup + start (TUX-style)",
        discussion: """
        Walks through every prerequisite cockerd needs and resolves them
        in your shell context (outside Homebrew's seatbelt sandbox). Each
        step is :
          1. Apple Container Linux kernel installed ?
          2. cockerd binary in place + properly signed ?
          3. ~/.cocker/kernel/ has vmlinuz + initrd ?
          4. Daemon running ?

        Fixes anything that's not yet done, prints "(ok)" for steps that
        are already good. Run after `brew install cocker` or any time
        you want a sanity check.
        """
    )

    @Flag(name: .customLong("dry-run"),
          help: "Print what would be done without making changes.")
    var dryRun: Bool = false

    @Flag(name: .customLong("no-color"),
          help: "Disable ANSI color codes in the output.")
    var noColor: Bool = false

    private struct Style {
        let useColor: Bool
        var ok:   String { useColor ? "\u{1B}[32m✓\u{1B}[0m" : "✓" }
        var arrow:String { useColor ? "\u{1B}[36m→\u{1B}[0m" : "→" }
        var warn: String { useColor ? "\u{1B}[33m⚠\u{1B}[0m" : "⚠" }
        var dim:  String { useColor ? "\u{1B}[2m"  : "" }
        var off:  String { useColor ? "\u{1B}[0m"  : "" }
        var bold: String { useColor ? "\u{1B}[1m"  : "" }
    }

    mutating func run() async throws {
        let s = Style(useColor: !noColor && isatty(STDOUT_FILENO) != 0)
        print("\(s.bold)cocker daemon init\(s.off)")
        print("")

        // 1. Apple Container kernel
        let home = NSHomeDirectory()
        let appleKernel = "\(home)/Library/Application Support/com.apple.container/kernels/default.kernel-arm64"
        if FileManager.default.fileExists(atPath: appleKernel) {
            print("\(s.ok) Apple Container Linux kernel found")
        } else {
            print("\(s.warn) Apple Container Linux kernel missing")
            print("  \(s.dim)Install Apple's container CLI for the Linux kernel cocker boots VMs with:\(s.off)")
            print("    brew install container")
            print("  \(s.dim)Then re-run: cocker daemon init\(s.off)")
            throw ExitCode.failure
        }

        // 2. cockerd binary + signature
        let cockerd = Self.detectCockerd()
        guard let cockerdPath = cockerd else {
            print("\(s.warn) cockerd binary not found in standard locations")
            print("  \(s.dim)Run `brew install cocker` or `./install.sh` first.\(s.off)")
            throw ExitCode.failure
        }
        print("\(s.ok) binaries installed at \((cockerdPath as NSString).deletingLastPathComponent)")
        let sigInfo = Self.codesignTeamID(of: cockerdPath)
        if sigInfo.adhoc {
            print("\(s.arrow) cockerd is ad-hoc signed — resigning with your Apple Development cert…")
            if dryRun {
                print("  \(s.dim)(dry-run: skipped)\(s.off)")
            } else {
                do {
                    let cert = try Self.detectIdentity()
                    let entitlements = (cockerdPath as NSString)
                        .deletingLastPathComponent
                        .replacingOccurrences(of: "/bin", with: "/share/cocker/cockerd.entitlements")
                    try Self.codesign(path: cockerdPath, identity: cert, entitlements: entitlements)
                    print("\(s.ok) signed: \(cert)")
                } catch {
                    print("\(s.warn) could not resign (\(error)) — ad-hoc signature kept.")
                    print("  \(s.dim)cockerd still boots VMs on this machine, but the binary can't be copied across machines.\(s.off)")
                }
            }
        } else if let teamID = sigInfo.teamID {
            print("\(s.ok) cockerd signed with TeamIdentifier=\(teamID)")
        } else {
            print("\(s.ok) cockerd is signed")
        }

        // 3. ~/.cocker/kernel/ — symlink + initrd
        let cockerRoot = home + "/.cocker"
        let kernelDir  = cockerRoot + "/kernel"
        let vmlinuz    = kernelDir + "/vmlinuz"
        let initrd     = kernelDir + "/initrd.img"
        var needRefresh = false
        if !FileManager.default.fileExists(atPath: vmlinuz) { needRefresh = true }
        if !FileManager.default.fileExists(atPath: initrd)  { needRefresh = true }

        if needRefresh {
            print("\(s.arrow) refreshing \(kernelDir) from \(DaemonSetupCommand.detectSharePrefixStatic())/share/cocker…")
            if !dryRun {
                var setup = DaemonSetupCommand()
                try await setup.run()
            } else {
                print("  \(s.dim)(dry-run: skipped)\(s.off)")
            }
        } else {
            print("\(s.ok) ~/.cocker/kernel/ already populated")
        }

        // 4. Start the daemon if not running
        let socketPath = cockerRoot + "/cocker.sock"
        if Self.isDaemonAlive(socketPath: socketPath) {
            print("\(s.ok) cockerd already running")
        } else {
            print("\(s.arrow) starting daemon via launchd (brew services)…")
            if !dryRun {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["brew", "services", "start", "cocker"]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    print("\(s.ok) cockerd starting")
                } else {
                    print("\(s.warn) brew services start exited \(p.terminationStatus)")
                    print("  \(s.dim)Try : cocker daemon start\(s.off)")
                }
            } else {
                print("  \(s.dim)(dry-run: skipped)\(s.off)")
            }
        }

        print("")
        print("\(s.bold)cocker is ready.\(s.off) Try : \(s.dim)cocker run -it alpine sh\(s.off)")
    }

    // MARK: - helpers

    private static func detectCockerd() -> String? {
        for p in [
            "/opt/homebrew/opt/cocker/bin/cockerd",
            "/opt/homebrew/bin/cockerd",
            "/usr/local/opt/cocker/bin/cockerd",
            "/usr/local/bin/cockerd",
        ] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private static func codesignTeamID(of path: String) -> (adhoc: Bool, teamID: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", path]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? ""
        let adhoc = str.contains("Signature=adhoc") || str.contains("flags=0x2(adhoc)")
        var teamID: String? = nil
        for line in str.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let v = String(line.dropFirst("TeamIdentifier=".count))
            if v != "not set" { teamID = v }
        }
        return (adhoc, teamID)
    }

    private static func detectIdentity() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? ""
        for kind in ["Apple Development", "Developer ID Application"] {
            for line in str.split(separator: "\n") where line.contains(kind) {
                if let openIdx = line.firstIndex(of: "\""),
                   let closeIdx = line.lastIndex(of: "\""),
                   openIdx < closeIdx {
                    return String(line[line.index(after: openIdx)..<closeIdx])
                }
            }
        }
        throw CockerError.requestFailed("no Apple Development cert in keychain")
    }

    private static func codesign(path: String, identity: String, entitlements: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = [
            "--force",
            "--sign", identity,
            "--entitlements", entitlements,
            path,
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw CockerError.requestFailed("codesign exit \(proc.terminationStatus)")
        }
    }

    private static func isDaemonAlive(socketPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        guard fd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                _ = socketPath.withCString { strncpy(dst, $0, 103) }
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }
}

extension DaemonSetupCommand {
    static func detectSharePrefixStatic() -> String {
        for p in ["/opt/homebrew", "/usr/local"] {
            if FileManager.default.fileExists(atPath: p + "/share/cocker/initrd.img") {
                return p
            }
        }
        return "/opt/homebrew"
    }
}

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
        func leaseCount() -> Int {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
            return s.components(separatedBy: "ip_address=").count - 1
        }
        let before = leaseCount()
        if before == 0 {
            print("Leases now: 0 entries.")
            return
        }
        // Fast path, but only if the helper actually does the work.
        //
        // This used to write the trigger with `try?`, discard the failure,
        // wait for a file that was never created (so the loop exited on
        // its first iteration), then print the *unchanged* count and
        // return 0. Measured on a real machine: 317 leases before, "Leases
        // now: 317 entries.", exit 0, 317 after. The one command the
        // daemon's own error message tells you to run was a no-op that
        // reported success, and it never reached the sudo path below
        // because the early `return` sat inside the helper branch.
        //
        // `/var/run` is root-owned and `cocker` runs as you, so that write
        // fails whenever the helper's LaunchDaemon isn't loaded to create
        // a path you can reach. Success is now measured by the pool
        // actually shrinking, not by the plist existing.
        let helperPlist = "/Library/LaunchDaemons/com.cocker.leases-helper.plist"
        if FileManager.default.fileExists(atPath: helperPlist) {
            if (try? Data().write(to: triggerURL)) != nil {
                // Wait briefly for the helper to consume the trigger and clear.
                for _ in 0..<20 {
                    if !FileManager.default.fileExists(atPath: trigger) { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let after = leaseCount()
                if after < before {
                    print("Leases now: \(after) entries.")
                    return
                }
                print("The lease helper did not clear the pool (\(after) entries) — "
                      + "falling back to sudo.")
            } else {
                print("The lease helper is installed but could not be reached: "
                      + "\(trigger) is not writable, so it is probably not loaded. "
                      + "Reinstall it with `cocker daemon helper-install`. "
                      + "Falling back to sudo for this run.")
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
            UX.Failure.emit(headline: "sudo failed",
                            reason: "exit \(proc.terminationStatus)",
                            hint: "this step needs administrator rights")
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
        // Prove the helper is alive instead of assuming it. Writing the
        // plist and calling `launchctl` is not the same as having a
        // running job, and the old version could not tell the difference:
        // it printed "✓ Helper installed and running." whenever the shell
        // exited 0, and `launchctl load` exits 0 even when it loads
        // nothing. Observed consequence — a plist installed in June, never
        // present in `launchctl list`, a 0-byte helper log, and a user who
        // had been told it was running. Everything downstream then treated
        // the file's existence as proof the helper worked, so a saturated
        // lease pool produced no diagnostics at all.
        //
        // The check is end-to-end: ask for a clear and see whether the
        // trigger gets consumed. Only a live helper removes that file, so
        // this cannot pass on a dead one — and as a side effect the pool
        // is actually cleared, which is why you ran this command.
        //
        // Exit codes from the script: 0 = helper answered, 2 = installed
        // but silent, anything else = the install itself failed.
        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        install.arguments = ["sh", "-c", """
            install -m 644 -o root -g wheel \(tmp.path) \(plistPath) || exit 1
            launchctl bootstrap system \(plistPath) 2>/dev/null \
              || launchctl load \(plistPath) 2>/dev/null
            touch /var/run/cocker-clear-leases || exit 1
            i=0
            while [ $i -lt 10 ]; do
              [ -f /var/run/cocker-clear-leases ] || exit 0
              sleep 1
              i=$((i+1))
            done
            exit 2
            """]
        try install.run()
        install.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)

        switch install.terminationStatus {
        case 0:
            let remaining = (try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8))
                .map { $0.components(separatedBy: "ip_address=").count - 1 }
            print("✓ Helper installed, running, and verified — it answered a clear request.")
            if let remaining { print("  Lease pool now at \(remaining) entries.") }
            print("  Subsequent `cocker daemon clear-leases` calls will skip the sudo prompt.")
        case 2:
            UX.Failure.emit(
                headline: "Helper installed but not responding",
                reason: "the plist is in place, but nothing consumed the trigger file "
                      + "within 10 s — the job is not actually running",
                hint: "inspect it with `sudo launchctl print system/com.cocker.leases-helper`; "
                    + "meanwhile `cocker daemon clear-leases` still works via sudo")
            throw ExitCode.failure
        default:
            UX.Failure.emit(headline: "Install failed",
                            reason: "exit \(install.terminationStatus)")
            throw ExitCode.failure
        }
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

/// Path of the plist `brew services` writes when the user installed via
/// Homebrew. Only present on the prod root (homebrew has no `cockerd-dev`
/// notion). Discovered via launchctl list as `homebrew.mxcl.cocker`.
private func homebrewPlistPath() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/LaunchAgents/homebrew.mxcl.cocker.plist")
}

/// Drives `brew services <action> cocker`. Splits out as a helper so the
/// three -s subcommands (start/stop/restart) share one shell-out point.
/// Returns true on success ; false (with a printed reason) when brew is
/// missing or returns non-zero. Stderr is surfaced so the user sees brew's
/// own diagnostics when something goes wrong.
@discardableResult
private func runBrewServices(_ action: String) -> Bool {
    let brewPath: String? = {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()
    guard let brew = brewPath else {
        UX.Failure.emit(
            headline: "brew binary not found",
            reason: "this daemon is managed by Homebrew but `brew` isn't on PATH",
            hint: "install Homebrew (https://brew.sh) or use `launchctl` directly"
        )
        return false
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: brew)
    proc.arguments = ["services", action, "cocker"]
    let errPipe = Pipe()
    proc.standardError = errPipe
    proc.standardOutput = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        UX.Failure.emit(
            headline: "Could not invoke `brew services \(action) cocker`",
            reason: "\(error)"
        )
        return false
    }
    guard proc.terminationStatus == 0 else {
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        UX.Failure.emit(
            headline: "brew services \(action) cocker failed",
            reason: stderrText.isEmpty ? "exit code \(proc.terminationStatus)" : stderrText
        )
        return false
    }
    return true
}

/// Decide which launchd backend manages this daemon. Single helper used
/// by start/stop/restart -s so the three sites agree on what's there.
///   .native(url)  → install.sh-style plist (com.cocker.cockerd[suffix].plist)
///   .homebrew     → brew services-managed (homebrew.mxcl.cocker.plist)
///   .none(url)    → neither plist present ; url is the native one we'd
///                    bootstrap if asked
private enum ServiceBackend {
    case native(URL)
    case homebrew
    case none(URL)
}

private func detectServiceBackend(root: URL) -> ServiceBackend {
    let native = launchdPlistPath(for: root)
    if FileManager.default.fileExists(atPath: native.path) {
        return .native(native)
    }
    // Brew managed only the prod root (`~/.cocker`) — for SUFFIX=-dev
    // installs we still expect the native plist, no brew fallback.
    if root.lastPathComponent == ".cocker",
       FileManager.default.fileExists(atPath: homebrewPlistPath().path) {
        return .homebrew
    }
    return .none(native)
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

        // --service / -s : delegate to launchd. Two backends supported :
        //   1. install.sh-style plist at ~/Library/LaunchAgents/com.cocker.cockerd
        //      [suffix].plist — managed directly via `launchctl bootstrap`.
        //   2. brew services-managed plist (homebrew.mxcl.cocker.plist) — we
        //      route to `brew services start cocker` so brew's bookkeeping
        //      stays consistent (otherwise `brew services list` would lie).
        if service {
            switch detectServiceBackend(root: paths.root) {
            case .native(let plist):
                try runLaunchctl(["bootstrap", "gui/\(getuid())", plist.path])
                print(UX.ActionLine(
                    icon: .success, name: plist.lastPathComponent,
                    status: "Bootstrapped", trailing: "KeepAlive auto-restarts on crash"
                ).render())
                print("   " + UX.TTY.paint("status :", .dim) + " cocker daemon status")
                print("   " + UX.TTY.paint("stop   :", .dim) + " cocker daemon stop -s")
                return
            case .homebrew:
                if runBrewServices("start") {
                    print(UX.ActionLine(
                        icon: .success, name: "cocker",
                        status: "Started (via brew services)", trailing: "managed by Homebrew"
                    ).render())
                    print("   " + UX.TTY.paint("status :", .dim) + " brew services list | grep cocker")
                    print("   " + UX.TTY.paint("stop   :", .dim) + " cocker daemon stop -s   (delegates to brew)")
                }
                return
            case .none(let plist):
                UX.Failure.emit(
                    headline: "No launchd service to start",
                    reason: "no plist at \(plist.path) and brew services is not managing cocker either",
                    hint: "either run install.sh, or `brew install cocker && brew services start cocker`"
                )
                throw ExitCode.failure
            }
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
        _ = try? log.seekToEnd()

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

        // --service / -s : tear down whichever launchd backend manages the
        // daemon (install.sh-native via launchctl bootout, or brew services
        // via `brew services stop`). Without -s, SIGTERM would just be
        // undone by KeepAlive=true and the daemon would respawn.
        if service {
            switch detectServiceBackend(root: paths.root) {
            case .native(let plist):
                try runLaunchctl(["bootout", "gui/\(getuid())", plist.path])
                try? FileManager.default.removeItem(at: paths.pidFile)
                print(UX.ActionLine(
                    icon: .success, name: plist.lastPathComponent,
                    status: "Booted out", trailing: "no respawn"
                ).render())
                print("   " + UX.TTY.paint("restart :", .dim) + " cocker daemon start -s")
                return
            case .homebrew:
                if runBrewServices("stop") {
                    try? FileManager.default.removeItem(at: paths.pidFile)
                    print(UX.ActionLine(
                        icon: .success, name: "cocker",
                        status: "Stopped (via brew services)", trailing: "no respawn"
                    ).render())
                    print("   " + UX.TTY.paint("restart :", .dim) + " cocker daemon start -s   (delegates to brew)")
                }
                return
            case .none(let plist):
                UX.Failure.emit(
                    headline: "No launchd service to stop",
                    reason: "no plist at \(plist.path) and brew services is not managing cocker either",
                    hint: "use `cocker daemon stop` (no -s) to kill the foreground / pid-file process"
                )
                throw ExitCode.failure
            }
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

        // Charter §13.4 — single action line for the daemon's state, then
        // a tree of dim sub-lines (launchd plist, log path, socket, leases,
        // helper). The user sees the headline in 3 chars (icon + verb) and
        // can dig into details below.

        guard let pid = readPID(paths.pidFile) else {
            print(UX.ActionLine(
                icon: .item, type: .daemon, name: "cockerd",
                status: "Not running"
            ).render())
            print("   " + UX.TTY.paint("hint    :", .dim) + " cocker daemon start")
            return
        }
        if !isAlive(pid) {
            UX.Failure.emit(
                headline: "Daemon cockerd is not running",
                reason: "stale pid file at \(paths.pidFile.path)",
                hint: "run `cocker daemon start` to bring it back up"
            )
            try? FileManager.default.removeItem(at: paths.pidFile)
            return
        }

        // Process started-at via getpriority/proc_pidinfo would need extra
        // syscalls ; the mtime of the PID file is good enough as an uptime
        // proxy.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: paths.pidFile.path)[.modificationDate]) as? Date
        let uptime = mtime.map { Date().timeIntervalSince($0) }
        let uptimeStr: String = {
            guard let u = uptime else { return "" }
            let h = Int(u) / 3600, m = (Int(u) % 3600) / 60, s = Int(u) % 60
            return ", uptime \(String(format: "%02d:%02d:%02d", h, m, s))"
        }()

        let trailing = "pid \(pid)\(uptimeStr)"
        print(UX.ActionLine(
            icon: .success, type: .daemon, name: "cockerd",
            status: "Running", trailing: trailing
        ).render())

        // Sub-lines — dim labels for "log", "ipc", "leases", "helper".
        // Charter §12 names macOS daemons (launchd, bootpd) explicitly.
        let plist = launchdPlistPath(for: paths.root)
        if FileManager.default.fileExists(atPath: plist.path) {
            print("   " + UX.TTY.paint("launchd :", .dim) + " " + plist.path)
        }
        print("   " + UX.TTY.paint("log     :", .dim) + " " + paths.logFile.path)
        let socketState = FileManager.default.fileExists(atPath: paths.ipcSock.path)
            ? UX.TTY.paint("reachable", .success)
            : UX.TTY.paint("MISSING (daemon may still be booting)", .warn)
        print("   " + UX.TTY.paint("ipc     :", .dim) + " " + paths.ipcSock.path + " — " + socketState)

        // Lease pool + helper status (vmnet bootpd caps at ~256). Operator
        // spots saturation without having to tail the daemon log.
        let leaseFile = "/var/db/dhcpd_leases"
        if let leases = try? String(contentsOfFile: leaseFile, encoding: .utf8) {
            let count = leases.components(separatedBy: "ip_address=").count - 1
            let leaseColor: UX.Color
            let marker: String
            switch count {
            case 0..<200:   leaseColor = .success; marker = "OK"
            case 200..<240: leaseColor = .warn;    marker = "elevated"
            case 240..<252: leaseColor = .warn;    marker = "WARNING"
            default:        leaseColor = .failure; marker = "SATURATED"
            }
            let body = "\(count)/256 (" + UX.TTY.paint(marker, leaseColor) + ")"
            print("   " + UX.TTY.paint("leases  :", .dim) + " " + body)
        }
        let helperPath = "/Library/LaunchDaemons/com.cocker.leases-helper.plist"
        if FileManager.default.fileExists(atPath: helperPath) {
            print("   " + UX.TTY.paint("helper  :", .dim) + " " + UX.TTY.paint("installed", .success) + " (auto-clears at >200 leases)")
        } else {
            print("   " + UX.TTY.paint("helper  :", .dim) + " " + UX.TTY.paint("not installed", .dim) + " — `cocker daemon helper-install` to fix forever")
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

        let useColor = !noColor && isatty(fileno(stdout)) != 0
        let interactive = follow && isatty(fileno(stdin)) != 0

        if interactive {
            // Docker Compose-style detach UX : show a one-line hint at
            // the top, capture single keystrokes so the user can hit
            // `d` to bail out without killing the daemon and without
            // the ugly "^C" + traceback Ctrl-C usually leaves behind.
            //
            // The hint mirrors `cocker compose up`'s footer so muscle
            // memory transfers — both flows use the same helper
            // (Sources/CockerCLI/InteractiveDetach.swift).
            // Capture by value so the @Sendable closure doesn't drag
            // `self` (a mutating command struct) in.
            let capturedArgs = args
            let capturedUseColor = useColor
            _ = try await InteractiveDetach.run(
                prompt: " " + ANSIStyle.dim + "Following " + paths.logFile.path
                    + ". Press " + ANSIStyle.reset + ANSIStyle.bold + "d" + ANSIStyle.reset
                    + ANSIStyle.dim + " to detach (daemon keeps running), "
                    + ANSIStyle.reset + ANSIStyle.bold + "Ctrl-C" + ANSIStyle.reset
                    + ANSIStyle.dim + " to stop." + ANSIStyle.reset
            ) { token in
                try await Self.runTailStream(
                    args: capturedArgs, useColor: capturedUseColor, token: token
                )
            }
            return
        }

        // Non-interactive : same behaviour as before — straight pipe to
        // stdout, exits on EOF or Ctrl-C. No keystroke handling, no
        // detach hint (would be misleading in a piped / non-TTY context).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        proc.arguments = args

        if !useColor {
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

    /// Interactive tail loop that respects a DetachToken : runs `tail`
    /// in a child process, streams its output through (optionally) the
    /// LogColorizer, and tears the child down cleanly when the token is
    /// canceled (user pressed `d`).
    ///
    /// Implementation note : the read loop has to be both responsive to
    /// the detach signal AND not spin-wait on the read syscall. We
    /// achieve this by setting the pipe's fd to non-blocking and polling
    /// at ~20 Hz when there's no data, which is invisible to the user
    /// but lets `token.isCanceled` win the race within ~50 ms of a key
    /// press. The previous synchronous `availableData` loop would have
    /// blocked indefinitely on a quiet log file even after detach.
    private static func runTailStream(
        args: [String], useColor: Bool, token: DetachToken
    ) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()

        // Non-blocking so the read loop can yield to the detach poll.
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let colorizer = useColor ? LogColorizer() : nil
        var carry = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)

        defer {
            if proc.isRunning {
                proc.terminate()
                // Don't waitUntilExit() — we're inside an async context
                // and tail terminates quickly on SIGTERM. Re-parent
                // takes over reaping.
            }
            // Flush whatever was left in the line buffer so the user
            // doesn't lose a partial trailing line on Ctrl-C / detach.
            if !carry.isEmpty, let line = String(data: carry, encoding: .utf8) {
                print(colorizer?.render(line) ?? line)
            }
        }

        while !token.isCanceled && proc.isRunning {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                carry.append(contentsOf: buf.prefix(Int(n)))
                while let nlRange = carry.range(of: Data([0x0A])) {
                    let lineData = carry.subdata(in: 0..<nlRange.lowerBound)
                    carry.removeSubrange(0..<nlRange.upperBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        print(colorizer?.render(line) ?? line)
                    }
                }
            } else if n == 0 {
                // EOF — tail finished (file rotated, or `-f` with no
                // input mode? unlikely but be safe).
                break
            } else {
                // n < 0 → EAGAIN (no data right now). Sleep a tiny bit
                // and re-check the token. 50 ms keeps detach feel-time
                // under "instant" while staying invisible CPU-wise.
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
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

        let timestamp = UX.TTY.paint(leveled.timestamp, .dim)
        let levelColor: UX.Color
        switch leveled.level {
        case "INFO":            levelColor = .success
        case "WARN", "WARNING": levelColor = .warn
        case "ERROR", "FATAL":  levelColor = .failure
        case "DEBUG", "TRACE":  levelColor = .dim
        default:                levelColor = .default
        }
        let level = UX.TTY.paint(leveled.level.padding(toLength: 5, withPad: " ", startingAt: 0), levelColor)
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
        return UX.TTY.paint(module, .progress) + tail
    }
}
