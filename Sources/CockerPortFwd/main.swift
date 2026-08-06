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
    /// `--udp` relays datagrams instead of streams. TCP stays the default so
    /// nothing that already spawns this binary changes shape.
    var udp: Bool = false

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
            case "--udp":
                args.udp = true
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

// MARK: - UDP relay

/// Forward UDP datagrams host → container, and the replies back.
///
/// UDP mappings used to be accepted, shown by `ps` and never forwarded: the
/// TCP path pipes through /usr/bin/nc and there was no datagram path at all,
/// so a DNS container published on `-p 53:53/udp` answered nobody.
///
/// There is no connection to hang a session's lifetime on, so the mapping is
/// keyed by client address with an idle timeout. Without expiry the table —
/// and the descriptor count — would grow for as long as the container runs,
/// which for a public DNS port is a slow leak with a hostile trigger.
func runUDPRelay(addr: String, port: UInt16, targetIP: String, targetPort: UInt16) -> Never {
    let listenFD = socket(AF_INET, SOCK_DGRAM, 0)
    guard listenFD >= 0 else { log("socket() failed: \(errStr())"); exit(1) }

    var yes: Int32 = 1
    setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var bindAddr = sockaddr_in()
    bindAddr.sin_family = sa_family_t(AF_INET)
    bindAddr.sin_port = port.bigEndian
    if addr == "0.0.0.0" || addr.isEmpty {
        bindAddr.sin_addr.s_addr = INADDR_ANY
    } else {
        inet_pton(AF_INET, addr, &bindAddr.sin_addr)
    }
    let bound = withUnsafePointer(to: &bindAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else {
        log("bind \(addr):\(port)/udp failed: \(errStr())"); exit(1)
    }

    var target = sockaddr_in()
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = targetPort.bigEndian
    inet_pton(AF_INET, targetIP, &target.sin_addr)

    log("listening on \(addr):\(port)/udp → \(targetIP):\(targetPort)")

    /// One upstream socket per client address. `connect()`ing it means the
    /// kernel filters replies to this peer for us, and recv() needs no
    /// source check of our own.
    struct Session {
        let fd: Int32
        var lastSeen: time_t
    }
    var sessions: [String: Session] = [:]
    let idleTimeout: time_t = 60
    // Each session costs a descriptor. Past this the oldest is reaped rather
    // than refusing new clients outright.
    let maxSessions = 128

    func key(_ sa: sockaddr_in) -> String {
        var a = sa
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return "\(String(cString: buf)):\(UInt16(bigEndian: a.sin_port))"
    }

    var buf = [UInt8](repeating: 0, count: 65535)

    while true {
        var readSet = fd_set()
        fdZero(&readSet)
        fdSet(listenFD, &readSet)
        var maxFD = listenFD
        for (_, s) in sessions {
            fdSet(s.fd, &readSet)
            if s.fd > maxFD { maxFD = s.fd }
        }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        let ready = select(maxFD + 1, &readSet, nil, nil, &tv)
        let now = time(nil)

        if ready > 0 {
            // Host → container.
            if fdIsSet(listenFD, &readSet) {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(listenFD, &buf, buf.count, 0, sa, &fromLen)
                    }
                }
                if n > 0 {
                    let k = key(from)
                    if sessions[k] == nil {
                        if sessions.count >= maxSessions,
                           let oldest = sessions.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
                            close(oldest.value.fd)
                            sessions.removeValue(forKey: oldest.key)
                        }
                        let up = socket(AF_INET, SOCK_DGRAM, 0)
                        if up >= 0 {
                            let ok = withUnsafePointer(to: &target) { ptr in
                                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                    connect(up, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                            if ok == 0 {
                                sessions[k] = Session(fd: up, lastSeen: now)
                            } else {
                                close(up)
                            }
                        }
                    }
                    if var s = sessions[k] {
                        _ = send(s.fd, buf, n, 0)
                        s.lastSeen = now
                        sessions[k] = s
                    }
                }
            }

            // Container → host. The reply goes back to the client whose
            // datagram opened this session, which is the whole reason the
            // table is keyed that way.
            for (k, s) in sessions where fdIsSet(s.fd, &readSet) {
                let n = recv(s.fd, &buf, buf.count, 0)
                if n > 0 {
                    var to = parseClientKey(k)
                    _ = withUnsafePointer(to: &to) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(listenFD, buf, n, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    var updated = s
                    updated.lastSeen = now
                    sessions[k] = updated
                }
            }
        }

        // Reap idle sessions. UDP gives no close, so this is the only thing
        // that bounds the table.
        for (k, s) in sessions where now - s.lastSeen > idleTimeout {
            close(s.fd)
            sessions.removeValue(forKey: k)
        }
    }
}

/// "1.2.3.4:5678" back into a sockaddr_in.
private func parseClientKey(_ k: String) -> sockaddr_in {
    var sa = sockaddr_in()
    sa.sin_family = sa_family_t(AF_INET)
    guard let colon = k.lastIndex(of: ":") else { return sa }
    let host = String(k[k.startIndex..<colon])
    let port = UInt16(k[k.index(after: colon)...]) ?? 0
    sa.sin_port = port.bigEndian
    inet_pton(AF_INET, host, &sa.sin_addr)
    return sa
}

// Swift doesn't surface the FD_* macros.
private func fdZero(_ set: inout fd_set) { bzero(&set, MemoryLayout<fd_set>.size) }
private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set.fds_bits) { raw in
        let words = raw.bindMemory(to: Int32.self)
        words[Int(fd) / 32] |= Int32(1 << (Int(fd) % 32))
    }
}
private func fdIsSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
    withUnsafeMutableBytes(of: &set.fds_bits) { raw in
        let words = raw.bindMemory(to: Int32.self)
        return words[Int(fd) / 32] & Int32(1 << (Int(fd) % 32)) != 0
    }
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

if args.udp {
    runUDPRelay(addr: args.listenAddr, port: args.listenPort,
                targetIP: args.targetIP, targetPort: args.targetPort)
}
runListener(addr: args.listenAddr, port: args.listenPort,
            targetIP: args.targetIP, targetPort: args.targetPort)
