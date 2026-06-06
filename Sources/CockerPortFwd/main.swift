import Foundation
import Darwin

// cocker-portfwd — TCP port forwarder.
//
// Architecture : on accept des connexions client soi-même (binaire user-signed,
// pas de problème pour accept() sur 0.0.0.0), puis pour chaque connexion on
// spawn /usr/bin/nc (binaire Apple système) qui se charge du connect() vers
// l'IP container du bridge vmnet privé. macOS Sequoia bloque connect() vers
// 192.168.64.0/24 depuis tout binaire NON-Apple-signed, mais autorise
// /usr/bin/nc même quand il est lancé comme subprocess d'un binaire user-signed.
//
// Le pipe stdin/stdout du nc est branché sur le socket client → forwarding
// bidirectionnel via deux pumps.

// MARK: - Args

struct Args {
    var listenAddr: String = "0.0.0.0"
    var listenPort: UInt16 = 0
    var targetIP: String = ""
    var targetPort: UInt16 = 0

    static func parse() -> Args? {
        var args = Args()
        var i = 1
        let argv = CommandLine.arguments
        while i < argv.count {
            switch argv[i] {
            case "--listen":
                i += 1
                guard i < argv.count else { return nil }
                let parts = argv[i].split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    args.listenAddr = String(parts[0])
                    args.listenPort = UInt16(parts[1]) ?? 0
                }
            case "--target":
                i += 1
                guard i < argv.count else { return nil }
                let parts = argv[i].split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                args.targetIP = String(parts[0])
                args.targetPort = UInt16(parts[1]) ?? 0
            case "--help", "-h":
                printUsage(); exit(0)
            default:
                fputs("cocker-portfwd: unknown arg \(argv[i])\n", stderr)
                printUsage(); exit(2)
            }
            i += 1
        }
        guard args.listenPort > 0, !args.targetIP.isEmpty, args.targetPort > 0 else {
            return nil
        }
        return args
    }
}

func printUsage() {
    print("""
    Usage: cocker-portfwd --listen ADDR:PORT --target IP:PORT

    For each incoming TCP connection on ADDR:PORT, spawns /usr/bin/nc to
    forward bidirectionally to IP:PORT. /usr/bin/nc is an Apple system
    binary that can traverse the macOS Sequoia sandbox restricting
    connect() to private vmnet bridges from user-signed binaries.
    """)
}

func log(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    fputs("[portfwd \(getpid())] \(stamp) \(msg)\n", stderr)
    fflush(stderr)
}

func errStr() -> String { String(cString: strerror(errno)) }

// MARK: - Per-connection handler using /usr/bin/nc

func forward(clientFD: Int32, targetIP: String, targetPort: UInt16) {
    // Spawn /usr/bin/nc avec stdin = client socket (read), stdout = client socket (write)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    proc.arguments = ["\(targetIP)", "\(targetPort)"]

    // Brancher le socket client directement sur stdin/stdout de nc
    let clientHandle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: false)
    proc.standardInput = clientHandle
    proc.standardOutput = clientHandle
    // stderr de nc → stderr du daemon (pour debug)
    proc.standardError = FileHandle.standardError

    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        log("spawn /usr/bin/nc failed: \(error)")
    }
    close(clientFD)
}

// MARK: - Listener

func runListener(addr: String, port: UInt16, targetIP: String, targetPort: UInt16) -> Never {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else {
        log("socket() failed: \(errStr())"); exit(1)
    }

    var yes: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var bindAddr = sockaddr_in()
    bindAddr.sin_family = sa_family_t(AF_INET)
    bindAddr.sin_port = port.bigEndian
    if addr == "0.0.0.0" || addr.isEmpty {
        bindAddr.sin_addr.s_addr = INADDR_ANY
    } else {
        inet_pton(AF_INET, addr, &bindAddr.sin_addr)
    }

    let bindResult = withUnsafePointer(to: &bindAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        log("bind \(addr):\(port) failed: \(errStr())"); exit(1)
    }
    guard Darwin.listen(sock, 128) == 0 else {
        log("listen failed: \(errStr())"); exit(1)
    }

    log("listening on \(addr):\(port) → \(targetIP):\(targetPort) (via /usr/bin/nc)")

    signal(SIGTERM) { _ in fputs("[portfwd] SIGTERM\n", stderr); exit(0) }
    signal(SIGINT) { _ in fputs("[portfwd] SIGINT\n", stderr); exit(0) }
    signal(SIGPIPE, SIG_IGN)

    // Accept loop : pour chaque connexion, spawn un nc dédié dans un thread.
    while true {
        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(sock, sa, &clientLen)
            }
        }
        guard client >= 0 else {
            if errno == EINTR { continue }
            log("accept failed: \(errStr())")
            continue
        }

        // Spawn nc dans un thread dédié pour ne pas bloquer l'accept loop
        DispatchQueue.global(qos: .userInitiated).async {
            forward(clientFD: client, targetIP: targetIP, targetPort: targetPort)
        }
    }
}

// MARK: - Entry

guard let args = Args.parse() else {
    fputs("cocker-portfwd: missing required args\n", stderr)
    printUsage()
    exit(2)
}

runListener(addr: args.listenAddr, port: args.listenPort,
            targetIP: args.targetIP, targetPort: args.targetPort)
