import Foundation
import CockerCore

/// Proxy TCP pour le port forwarding host → container.
///
/// Apple VZNATNetworkDeviceAttachment fait juste du NAT outbound (container
/// peut accéder à internet). Pour faire `-p 8080:80` qui marche, on doit
/// écouter côté host sur 0.0.0.0:8080 et forwarder chaque connexion vers
/// l'IP NAT du container sur le port 80.
///
/// Implémentation : Unix sockets POSIX directs (pas de dépendance NIO).
/// Pour chaque mapping, on crée un thread accept(), et chaque connection
/// accepted est handlée par un pump bidirectionnel sur deux DispatchSources.
///
/// Limitation : on suppose que le container répond sur son IPv4 alloué par
/// le NAT vmnet. En pratique le container reçoit son IP via DHCP géré par
/// vmnet, et il faut soit (a) la connaître via cocker-init qui la rapporte
/// au daemon, soit (b) sniff DHCP côté host. Pour le PoC on essaie l'IP
/// allouée par notre NetworkManager (qui doit matcher si on configure le
/// container init avec).
public actor PortForwarder {
    private var listeners: [String: ListenerHandle] = [:]  // key = "containerID:hostPort"

    private final class ListenerHandle: @unchecked Sendable {
        let fd: Int32
        let source: DispatchSourceRead
        var connectionFDs: [Int32] = []
        let lock = NSLock()
        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    public init() {}

    /// Active le forwarding pour un container et ses mappings.
    /// `containerIP` : l'IP IPv4 attribuée au container (côté NAT vmnet).
    public func start(
        containerID: String,
        containerIP: String,
        mappings: [PortMapping]
    ) async {
        for port in mappings {
            // UDP non supporté pour l'instant (NIO/PF requis pour faire ça
            // proprement). On log mais ne plante pas.
            guard port.proto == .tcp else {
                print("[portfwd] skip \(port.hostPort)/\(port.proto.rawValue) (TCP only for now)")
                continue
            }
            do {
                try startTCPListener(
                    containerID: containerID,
                    hostPort: port.hostPort,
                    containerIP: containerIP,
                    containerPort: port.containerPort
                )
                fputs("[portfwd] 0.0.0.0:\(port.hostPort) → \(containerIP):\(port.containerPort) (container \(String(containerID.prefix(12))))\n", stderr); fflush(stderr)
            } catch {
                print("[portfwd] error binding \(port.hostPort): \(error)")
            }
        }
    }

    /// Arrête tous les forwards d'un container.
    public func stop(containerID: String) async {
        let keys = listeners.keys.filter { $0.hasPrefix("\(containerID):") }
        for key in keys {
            guard let handle = listeners[key] else { continue }
            handle.source.cancel()
            close(handle.fd)
            handle.lock.lock()
            for cfd in handle.connectionFDs { close(cfd) }
            handle.lock.unlock()
            listeners.removeValue(forKey: key)
            print("[portfwd] stopped \(key)")
        }
    }

    public func stopAll() async {
        for (_, handle) in listeners {
            handle.source.cancel()
            close(handle.fd)
            handle.lock.lock()
            for cfd in handle.connectionFDs { close(cfd) }
            handle.lock.unlock()
        }
        listeners.removeAll()
    }

    // MARK: - Listener TCP

    private func startTCPListener(
        containerID: String,
        hostPort: UInt16,
        containerIP: String,
        containerPort: UInt16
    ) throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw CockerError.internalError("socket(): \(errStr())") }

        // SO_REUSEADDR pour éviter "Address already in use" entre restarts
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = hostPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY  // 0.0.0.0

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(sock)
            throw CockerError.internalError("bind(:\(hostPort)): \(errStr())")
        }
        guard Darwin.listen(sock, 128) == 0 else {
            close(sock)
            throw CockerError.internalError("listen(:\(hostPort)): \(errStr())")
        }

        // Mode non-bloquant pour accept via DispatchSource
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let queue = DispatchQueue(label: "cocker.portfwd.\(containerID).\(hostPort)")
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)

        let handle = ListenerHandle(fd: sock, source: source)
        listeners["\(containerID):\(hostPort)"] = handle

        source.setEventHandler { [weak handle] in
            guard let handle else { return }
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(sock, sa, &clientLen)
                }
            }
            guard client >= 0 else {
                fputs("[portfwd] accept failed: \(String(cString: strerror(errno)))\n", stderr); fflush(stderr)
                return
            }
            fputs("[portfwd] accepted connection on :\(hostPort), connecting upstream \(containerIP):\(containerPort)\n", stderr); fflush(stderr)

            // Connect au container
            let upstream = connectToContainer(ip: containerIP, port: containerPort)
            guard upstream >= 0 else {
                fputs("[portfwd] upstream connect failed: \(containerIP):\(containerPort)\n", stderr); fflush(stderr)
                close(client)
                return
            }
            fputs("[portfwd] upstream connected, pumping...\n", stderr); fflush(stderr)

            handle.lock.lock()
            handle.connectionFDs.append(client)
            handle.connectionFDs.append(upstream)
            handle.lock.unlock()

            pumpBidirectional(client: client, upstream: upstream)
        }
        source.resume()
    }
}

// MARK: - Helpers (top-level, libres de capture pour @Sendable)

private func errStr() -> String {
    String(cString: strerror(errno))
}

private func connectToContainer(ip: String, port: UInt16) -> Int32 {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else {
        fputs("[portfwd] socket() failed: \(String(cString: strerror(errno)))\n", stderr); fflush(stderr)
        return -1
    }

    // Bind explicite sur l'IP du bridge vmnet (192.168.64.1) si le target
    // est sur ce subnet. Sans ça, le routing par défaut de cockerd (sandbox
    // virtualization) ne sait pas atteindre les IPs du bridge depuis le
    // process daemon → "No route to host".
    if ip.hasPrefix("192.168.64.") {
        var srcAddr = sockaddr_in()
        srcAddr.sin_family = sa_family_t(AF_INET)
        srcAddr.sin_port = 0  // OS pick
        inet_pton(AF_INET, "192.168.64.1", &srcAddr.sin_addr)
        let bindRes = withUnsafePointer(to: &srcAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRes != 0 {
            fputs("[portfwd] bind on 192.168.64.1 failed: \(String(cString: strerror(errno))) (non-fatal, continuing)\n", stderr); fflush(stderr)
        }
    }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    let ptonResult = inet_pton(AF_INET, ip, &addr.sin_addr)
    guard ptonResult == 1 else {
        fputs("[portfwd] inet_pton failed for '\(ip)' (returned \(ptonResult))\n", stderr); fflush(stderr)
        close(sock)
        return -1
    }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if result != 0 {
        fputs("[portfwd] connect(\(ip):\(port)) failed: \(String(cString: strerror(errno))) (errno \(errno))\n", stderr); fflush(stderr)
        close(sock)
        return -1
    }
    return sock
}

private func pumpBidirectional(client: Int32, upstream: Int32) {
    // Deux threads détachés, un par direction. Simple et qui marche.
    // Quand l'un voit EOF/erreur, il close les deux FDs → l'autre voit aussi
    // EOF et termine.
    let q1 = DispatchQueue(label: "cocker.portfwd.pump.c2u", qos: .userInitiated)
    let q2 = DispatchQueue(label: "cocker.portfwd.pump.u2c", qos: .userInitiated)
    let closed = AtomicFlag()

    q1.async { pump(from: client, to: upstream, closeBoth: closed, fd1: client, fd2: upstream) }
    q2.async { pump(from: upstream, to: client, closeBoth: closed, fd1: client, fd2: upstream) }
}

private func pump(from src: Int32, to dst: Int32, closeBoth: AtomicFlag, fd1: Int32, fd2: Int32) {
    var buf = [UInt8](repeating: 0, count: 16 * 1024)
    while !closeBoth.isSet {
        let n = Darwin.read(src, &buf, buf.count)
        if n <= 0 { break }
        // Write tout dans le closure pour garder le pointer valide
        let writeOK = buf.withUnsafeBufferPointer { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            var written = 0
            while written < n {
                let w = Darwin.write(dst, base + written, n - written)
                if w <= 0 { return false }
                written += w
            }
            return true
        }
        if !writeOK { closeBoth.set(); break }
    }
    if closeBoth.tryClose() {
        close(fd1)
        close(fd2)
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
    func tryClose() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}
