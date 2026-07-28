import Foundation
import CockerCore

// Internal DNS server for container name resolution
//
// Résolution par ordre de priorité :
//   1. Nom exact de container         → "web"          → 172.17.0.3
//   2. Nom de service compose         → "db"           → 172.17.0.4
//   3. FQDN container                 → "web.cocker"   → 172.17.0.3
//   4. Alias réseau                   → "api.frontend" → 172.17.0.5
//   5. Forwarding upstream (1.1.1.1)  → tout le reste
//
// Le DNS écoute sur port 5300 (pas besoin de root)
// Les VMs reçoivent l'IP du host via kernel cmdline → /etc/resolv.conf

actor DNSServer {
    static let defaultPort: UInt16 = 5300
    static let listenAddress = "0.0.0.0"
    static let upstreamDNS = "1.1.1.1"
    static let cockerDomain = "cocker"

    private let state: StateStore
    private let port: UInt16
    private var serverFD: Int32 = -1
    private var bridgeFD: Int32 = -1  // second listener bound on bridge100 IP
    private var tcpFD: Int32 = -1     // TCP listener (used by VMs via cocker-init DNS proxy)
    private var isRunning = false

    // Cache de résolution : name → ip, invalidé à chaque changement
    private var cache: [String: String] = [:]
    private var cacheVersion: Int = 0

    init(state: StateStore, port: UInt16 = DNSServer.defaultPort) {
        self.state = state
        self.port = port
    }

    // MARK: - Start / Stop

    func start() async throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw CockerError.internalError("DNS: socket() failed: \(String(cString: strerror(errno)))")
        }

        // Réutilisation du port pour les redémarrages rapides
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw CockerError.internalError("DNS: bind() failed on port \(port): \(String(cString: strerror(errno)))")
        }

        self.serverFD = fd
        self.isRunning = true
        CockerLog.shared.info("dns", "listening on 0.0.0.0:\(port) (UDP)")

        // TCP listener — used by cocker-init's in-VM DNS proxy. Apple's
        // App Sandbox blocks UDP packets from vmnet to user-signed daemons,
        // but TCP from VM works. See start_dns_proxy() in cocker-init/init.c.
        if let tfd = Self.bindTCP(port: port) {
            self.tcpFD = tfd
            CockerLog.shared.info("dns", "listening on 0.0.0.0:\(port) (TCP)")
            Task { await self.tcpAcceptLoop(fd: tfd) }
        } else {
            CockerLog.shared.warn("dns", "TCP listener bind failed")
        }

        // Bonus UDP bind on bridge100 (in case the sandbox ever relaxes).
        Task { await self.bridgeBindLoop() }

        await receiveLoop(fd: serverFD)
    }

    // MARK: - TCP DNS (RFC 1035 §4.2.2)

    private static func bindTCP(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindOK != 0 { close(fd); return nil }
        if listen(fd, 128) != 0 { close(fd); return nil }
        return fd
    }

    private func tcpAcceptLoop(fd: Int32) async {
        while isRunning {
            let cfd = await Self.acceptConnection(on: fd)
            if cfd < 0 { try? await Task.sleep(nanoseconds: 50_000_000); continue }
            Task { [weak self] in
                await self?.handleTCPClient(fd: cfd)
            }
        }
    }

    nonisolated private func handleTCPClient(fd: Int32) async {
        await handleStreamedDNSQuery(fd: fd)
    }

    /// Read a DNS-over-TCP framed query from `fd`, build a response, write it
    /// back framed, close the fd. Used by both the TCP listener and the vsock
    /// listener — the wire is identical (RFC 1035 §4.2.2). Caller transfers
    /// fd ownership.
    ///
    /// **Why this is nonisolated** : the heavy step is `forwardToUpstream`,
    /// a synchronous UDP roundtrip to 1.1.1.1 with a 2-second timeout.
    /// Inside actor isolation, every concurrent query would serialize
    /// behind that 2-second wait (uv pip install fires 7+ A+AAAA pairs
    /// in parallel → 28+ seconds of head-of-line blocking → EAI_AGAIN).
    /// Making this nonisolated lets each Task.detached run the resolver
    /// in true parallel ; the only shared state we touch is `state.
    /// allContainers` which is itself an actor and handles concurrent
    /// reads cleanly.
    nonisolated func handleStreamedDNSQuery(fd: Int32) async {
        defer { close(fd) }
        guard let query = await Self.readStreamedQuery(fd: fd) else { return }

        let containers = await state.allContainers(includeAll: false)
        guard let result = await Self.resolve(query: query, containers: containers) else { return }

        Self.logResult(result.kind)

        let response = result.response
        let prefix: [UInt8] = [UInt8((response.count >> 8) & 0xFF), UInt8(response.count & 0xFF)]
        await Self.writeStreamedResponse(fd: fd, prefix: prefix, response: response)
    }

    nonisolated private static func logResult(_ kind: DNSQueryAnswerKind) {
        switch kind {
        case .authoritativeA(let n, let ip):     logDNS(n, result: ip, authoritative: true)
        case .authoritativeAAAA(let n, let ip6): logDNS(n, result: ip6, authoritative: true)
        case .empty(let n):                       logDNS(n, result: "empty", authoritative: true)
        case .upstream(let n):                    logDNS(n, result: "upstream", authoritative: false)
        case .nxdomain(let n):                    logDNS(n, result: "NXDOMAIN", authoritative: true)
        }
    }

    private static func readAll(fd: Int32, into buf: inout [UInt8], count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base.advanced(by: off), count - off)
            }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    private nonisolated static func acceptConnection(on fd: Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Darwin.accept(fd, nil, nil))
            }
        }
    }

    private nonisolated static func readStreamedQuery(fd: Int32) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var length = [UInt8](repeating: 0, count: 2)
                guard readAll(fd: fd, into: &length, count: 2) else {
                    continuation.resume(returning: nil); return
                }
                let count = (Int(length[0]) << 8) | Int(length[1])
                guard count > 0, count <= 65_535 else {
                    continuation.resume(returning: nil); return
                }
                var bytes = [UInt8](repeating: 0, count: count)
                continuation.resume(returning:
                    readAll(fd: fd, into: &bytes, count: count) ? Data(bytes) : nil)
            }
        }
    }

    private nonisolated static func resolve(query: Data, containers: [Container]) async -> DNSQueryResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: DNSQueryProcessor.process(
                    query: query,
                    containers: containers,
                    forwardUpstream: { forwardToUpstream($0, upstream: upstreamDNS) }
                ))
            }
        }
    }

    private nonisolated static func writeStreamedResponse(
        fd: Int32, prefix: [UInt8], response: Data
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = prefix.withUnsafeBytes { writeAll(fd: fd, base: $0.baseAddress, count: $0.count) }
                _ = response.withUnsafeBytes { writeAll(fd: fd, base: $0.baseAddress, count: $0.count) }
                continuation.resume()
            }
        }
    }

    private nonisolated static func writeAll(fd: Int32, base: UnsafeRawPointer?, count: Int) -> Bool {
        guard let base else { return count == 0 }
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, base.advanced(by: offset), count - offset)
            if n > 0 { offset += n }
            else if n < 0, errno == EINTR { continue }
            else { return false }
        }
        return true
    }

    private func bridgeBindLoop() async {
        while isRunning {
            if bridgeFD < 0 {
                if let ip = Self.vmnetGatewayIP(),
                   let fd = Self.bindUDP(on: ip, port: port) {
                    bridgeFD = fd
                    CockerLog.shared.info("dns", "also listening on \(ip):\(port) (bridge100)")
                    Task { await self.receiveLoop(fd: fd) }
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func bindUDP(on ip: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, ip, &addr.sin_addr) != 1 {
            close(fd); return nil
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        if bridgeFD >= 0 { close(bridgeFD); bridgeFD = -1 }
        if tcpFD >= 0 { close(tcpFD); tcpFD = -1 }
    }

    // Invalide le cache quand un container démarre/s'arrête
    func invalidateCache() {
        cache.removeAll()
        cacheVersion += 1
    }

    // MARK: - Receive loop

    private func receiveLoop(fd: Int32) async {
        while isRunning {
            guard let datagram = await Self.receiveDatagram(on: fd) else { continue }
            Task { [weak self] in
                await self?.handlePacket(datagram.data, clientIP: datagram.ip,
                                         clientPort: datagram.port, viaFD: fd)
            }
        }
    }

    private struct Datagram: Sendable { let data: Data; let ip: String; let port: UInt16 }

    private nonisolated static func receiveDatagram(on fd: Int32) async -> Datagram? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: 4096)
                var address = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &address) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buffer, buffer.count, 0, sa, &length)
                    }
                }
                guard n > DNSHeader.size else { continuation.resume(returning: nil); return }
                let ip = withUnsafeBytes(of: address.sin_addr) { raw -> String in
                    let b = raw.bindMemory(to: UInt8.self)
                    return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
                }
                continuation.resume(returning: Datagram(
                    data: Data(buffer.prefix(n)), ip: ip, port: address.sin_port.bigEndian))
            }
        }
    }

    // MARK: - Packet handler

    /// Nonisolated UDP handler — same reasoning as `handleStreamedDNSQuery` :
    /// forwardToUpstream blocks for up to 2s, and isolating it on the
    /// DNSServer actor serialized every concurrent query (uv pip
    /// install's parallel A+AAAA bursts hit 8+ second pile-ups → EAI_AGAIN).
    nonisolated private func handlePacket(_ data: Data, clientIP: String, clientPort: UInt16, viaFD: Int32) async {
        let containers = await state.allContainers(includeAll: false)
        guard let result = await Self.resolve(query: data, containers: containers) else { return }

        Self.logResult(result.kind)
        Self.sendResponse(result.response, toIP: clientIP, port: clientPort, viaFD: viaFD)
    }

    // MARK: - Send response

    /// Nonisolated so the per-query Tasks can write back without
    /// re-entering the actor.
    nonisolated private static func sendResponse(_ data: Data, toIP ip: String, port: UInt16, viaFD: Int32) {
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &dest.sin_addr)

        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            withUnsafePointer(to: &dest) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(viaFD, ptr, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - Logging

    nonisolated private static func logDNS(_ name: String, result: String, authoritative: Bool) {
        let tag = authoritative ? "✓" : "→"
        print("[dns] \(tag) \(name) → \(result)")
    }

    // MARK: - Host IP helper

    // IP du host accessible depuis les VMs container.
    //
    // VZNATNetworkDeviceAttachment d'Apple utilise un subnet vmnet privé
    // 192.168.64.0/24 avec le host à .1. Cette convention est stable depuis
    // macOS 11 et utilisée par tous les VMM Mac (Lima, tart, multipass…).
    // Les autres interfaces du host (bridge0/en0 = LAN, utun = VPN…) ne
    // sont pas routables depuis les VMs vmnet.
    //
    // On préfère détecter dynamiquement bridge100 si elle existe (au cas où
    // Apple change l'IP par défaut), sinon on retombe sur 192.168.64.1.
    static func hostIP() -> String {
        if let ip = vmnetGatewayIP() { return ip }
        return "192.168.64.1"
    }

    private static func vmnetGatewayIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = current {
            defer { current = addr.pointee.ifa_next }

            let name = String(cString: addr.pointee.ifa_name)
            // Apple's vmnet bridge for VZNATNetworkDeviceAttachment is
            // always named bridge100 / bridge101 / … (vmenet* on older OS).
            guard name.hasPrefix("bridge1") || name.hasPrefix("vmenet") else { continue }
            guard addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            addr.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                _ = inet_ntop(AF_INET, &sin.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: buf)
            if !ip.isEmpty && !ip.hasPrefix("127.") { return ip }
        }
        return nil
    }
}
