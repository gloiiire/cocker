import Foundation

// cocker-portfwd — TCP port forwarder dédié.
//
// Pourquoi un binaire séparé : `cockerd` est signé avec l'entitlement
// `com.apple.security.virtualization`, qui implique un sandbox macOS qui
// bloque les `connect()` outbound vers les bridges privés vmnet
// (192.168.64.0/24). Erreur observée : EHOSTUNREACH ("No route to host")
// alors que `curl` direct depuis le terminal marche.
//
// Ce binaire-ci est signé SANS cet entitlement (ad-hoc suffit) → pas de
// sandbox → peut connect aux IPs vmnet.
//
// Usage :
//   cocker-portfwd --listen 0.0.0.0:8080 --target 192.168.64.5:80
//
// Lance un listener et forward chaque connexion entrante. Reste online
// jusqu'à SIGTERM/SIGINT.

import Darwin

// MARK: - Args parsing

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
            let arg = argv[i]
            switch arg {
            case "--listen":
                i += 1
                guard i < argv.count else { return nil }
                let parts = argv[i].split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    args.listenAddr = String(parts[0])
                    args.listenPort = UInt16(parts[1]) ?? 0
                } else {
                    args.listenPort = UInt16(arg) ?? 0
                }
            case "--target":
                i += 1
                guard i < argv.count else { return nil }
                let parts = argv[i].split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                args.targetIP = String(parts[0])
                args.targetPort = UInt16(parts[1]) ?? 0
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                fputs("cocker-portfwd: unknown arg \(arg)\n", stderr)
                printUsage()
                exit(2)
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

      --listen ADDR:PORT  Bind interface and port (use 0.0.0.0 for all)
      --target IP:PORT    Container IP and port to forward to
      --help              Show this message

    Spawned by cockerd as a subprocess per port mapping. The separate process
    avoids the macOS sandbox attached to com.apple.security.virtualization.
    """)
}

// MARK: - Logging

func log(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    fputs("[portfwd \(getpid())] \(stamp) \(msg)\n", stderr)
    fflush(stderr)
}

func errStr() -> String { String(cString: strerror(errno)) }

// MARK: - Bidirectional pump

func pumpBidirectional(client: Int32, upstream: Int32) {
    let q1 = DispatchQueue(label: "pump.c2u", qos: .userInitiated)
    let q2 = DispatchQueue(label: "pump.u2c", qos: .userInitiated)
    let closeOnce = ClosedFlag()

    q1.async { pump(src: client, dst: upstream, closed: closeOnce, fd1: client, fd2: upstream) }
    q2.async { pump(src: upstream, dst: client, closed: closeOnce, fd1: client, fd2: upstream) }
}

func pump(src: Int32, dst: Int32, closed: ClosedFlag, fd1: Int32, fd2: Int32) {
    var buf = [UInt8](repeating: 0, count: 16 * 1024)
    while !closed.isSet {
        let n = Darwin.read(src, &buf, buf.count)
        if n <= 0 { break }
        let ok = buf.withUnsafeBufferPointer { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            var written = 0
            while written < n {
                let w = Darwin.write(dst, base + written, n - written)
                if w <= 0 { return false }
                written += w
            }
            return true
        }
        if !ok { break }
    }
    if closed.tryClose() {
        close(fd1)
        close(fd2)
    }
}

final class ClosedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func tryClose() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

// MARK: - Upstream connect

func connectUpstream(ip: String, port: UInt16) -> Int32 {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return -1 }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    let pton = inet_pton(AF_INET, ip, &addr.sin_addr)
    guard pton == 1 else { close(sock); return -1 }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if result != 0 {
        log("connect \(ip):\(port) failed: \(errStr())")
        close(sock)
        return -1
    }
    return sock
}

// MARK: - Listener

func runListener(addr: String, port: UInt16, targetIP: String, targetPort: UInt16) -> Never {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else {
        log("socket() failed: \(errStr())")
        exit(1)
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
        log("bind \(addr):\(port) failed: \(errStr())")
        exit(1)
    }
    guard Darwin.listen(sock, 128) == 0 else {
        log("listen failed: \(errStr())")
        exit(1)
    }

    log("listening on \(addr):\(port) → \(targetIP):\(targetPort)")

    // Handle SIGTERM/SIGINT to clean up
    signal(SIGTERM) { _ in
        fputs("[portfwd] SIGTERM, exiting\n", stderr)
        exit(0)
    }
    signal(SIGINT) { _ in
        fputs("[portfwd] SIGINT, exiting\n", stderr)
        exit(0)
    }
    signal(SIGPIPE, SIG_IGN)  // sinon Darwin.write peut killer le process

    // Accept loop
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

        let upstream = connectUpstream(ip: targetIP, port: targetPort)
        if upstream < 0 {
            close(client)
            continue
        }
        pumpBidirectional(client: client, upstream: upstream)
    }
}

// MARK: - Entry point

guard let args = Args.parse() else {
    fputs("cocker-portfwd: missing required args\n", stderr)
    printUsage()
    exit(2)
}

runListener(
    addr: args.listenAddr,
    port: args.listenPort,
    targetIP: args.targetIP,
    targetPort: args.targetPort
)
