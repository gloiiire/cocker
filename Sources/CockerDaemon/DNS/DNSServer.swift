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
        fputs("[cockerd] DNS resolver listening on 0.0.0.0:\(port) (UDP)\n", stderr)
        fflush(stderr)

        // TCP listener — used by cocker-init's in-VM DNS proxy. Apple's
        // App Sandbox blocks UDP packets from vmnet to user-signed daemons,
        // but TCP from VM works. See start_dns_proxy() in cocker-init/init.c.
        if let tfd = Self.bindTCP(port: port) {
            self.tcpFD = tfd
            fputs("[cockerd] DNS resolver listening on 0.0.0.0:\(port) (TCP)\n", stderr)
            fflush(stderr)
            Task { await self.tcpAcceptLoop(fd: tfd) }
        } else {
            fputs("[cockerd] WARN: TCP DNS listener bind failed\n", stderr)
            fflush(stderr)
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
            let cfd = await Task.detached(priority: .userInitiated) { [fd] in
                Darwin.accept(fd, nil, nil)
            }.value
            if cfd < 0 { try? await Task.sleep(nanoseconds: 50_000_000); continue }
            Task { await self.handleTCPClient(fd: cfd) }
        }
    }

    private func handleTCPClient(fd: Int32) async {
        defer { close(fd) }
        var lenBuf: [UInt8] = [0, 0]
        guard Self.readAll(fd: fd, into: &lenBuf, count: 2) else { return }
        let msgLen = (Int(lenBuf[0]) << 8) | Int(lenBuf[1])
        guard msgLen > 0, msgLen <= 65535 else { return }

        var msgBuf = [UInt8](repeating: 0, count: msgLen)
        guard Self.readAll(fd: fd, into: &msgBuf, count: msgLen) else { return }
        let query = Data(msgBuf)

        guard query.count > DNSHeader.size else { return }
        let header = DNSHeader(data: query)
        guard header.isQuery, header.opcode == 0 else { return }

        let (questions, _) = parseDNSQuestions(from: query, count: Int(header.qdCount))
        guard let question = questions.first else { return }

        let response: Data
        if let ip = await resolve(name: question.name), (question.isA || question.isAny) {
            response = buildAResponse(header: header, question: question, ip: ip)
            logDNS(question.name, result: ip, authoritative: true)
        } else if question.isAAAA {
            if let ipv6 = await resolveIPv6(name: question.name) {
                response = buildAAAAResponse(header: header, question: question, ipv6: ipv6)
            } else {
                response = buildEmptyResponse(header: header, question: question)
            }
        } else {
            response = forwardToUpstream(query, upstream: Self.upstreamDNS)
                ?? buildNXDomain(header: header, question: question)
            logDNS(question.name, result: "upstream(tcp)", authoritative: false)
        }

        // Send back with 2-byte length prefix
        let prefix: [UInt8] = [UInt8((response.count >> 8) & 0xFF), UInt8(response.count & 0xFF)]
        _ = prefix.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, 2) }
        _ = response.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, response.count) }
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

    private func bridgeBindLoop() async {
        while isRunning {
            if bridgeFD < 0 {
                if let ip = Self.vmnetGatewayIP(),
                   let fd = Self.bindUDP(on: ip, port: port) {
                    bridgeFD = fd
                    fputs("[cockerd] DNS resolver also listening on \(ip):\(port) (bridge100)\n", stderr)
                    fflush(stderr)
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
        var buf = [UInt8](repeating: 0, count: 4096)
        var clientAddr = sockaddr_in()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while isRunning {
            let n = await Task.detached(priority: .userInitiated) { [fd] in
                withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buf, buf.count, 0, sa, &clientAddrLen)
                    }
                }
            }.value

            guard n > DNSHeader.size else { continue }
            let packet = Data(buf.prefix(n))

            // Capture des infos client pour la réponse
            let clientPort = clientAddr.sin_port.bigEndian
            let clientIP = withUnsafeBytes(of: clientAddr.sin_addr) { bytes -> String in
                let b = bytes.bindMemory(to: UInt8.self)
                return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            }

            Task { await self.handlePacket(packet, clientIP: clientIP, clientPort: clientPort, viaFD: fd) }
        }
    }

    // MARK: - Packet handler

    private func handlePacket(_ data: Data, clientIP: String, clientPort: UInt16, viaFD: Int32) async {
        let header = DNSHeader(data: data)
        guard header.isQuery, header.opcode == 0 else { return }  // Standard query only

        let (questions, _) = parseDNSQuestions(from: data, count: Int(header.qdCount))
        guard let question = questions.first else { return }

        // Résolution
        let response: Data

        if let ip = await resolve(name: question.name), (question.isA || question.isAny) {
            // Réponse authoritative avec l'IP du container
            response = buildAResponse(header: header, question: question, ip: ip)
            logDNS(question.name, result: ip, authoritative: true)
        } else if question.isAAAA {
            // AAAA → chercher l'adresse IPv6 du container si elle existe
            if let ipv6 = await resolveIPv6(name: question.name) {
                response = buildAAAAResponse(header: header, question: question, ipv6: ipv6)
                logDNS(question.name, result: ipv6, authoritative: true)
            } else {
                response = buildEmptyResponse(header: header, question: question)
            }
        } else {
            // Forwarding vers upstream DNS
            response = forwardToUpstream(data, upstream: Self.upstreamDNS) ?? buildNXDomain(header: header, question: question)
            logDNS(question.name, result: "upstream", authoritative: false)
        }

        sendResponse(response, toIP: clientIP, port: clientPort, viaFD: viaFD)
    }

    // MARK: - Name resolution

    private func resolve(name: String) async -> String? {
        // Cache hit
        if let cached = cache[name] { return cached }

        let ip = await lookupInState(name: name)
        if let ip { cache[name] = ip }
        return ip
    }

    private func lookupInState(name: String) async -> String? {
        let containers = await state.allContainers(includeAll: false)  // running only

        // Nom à tester après normalisation (retire le domaine .cocker si présent)
        let candidates = normalizedNames(from: name)

        for container in containers {
            // Prefer the cocker switch IP (10.42.x.x) when present : container-to-
            // container traffic goes through the userspace L2 switch and that IP
            // is the only one reachable from peer VMs. Fall back to the legacy
            // vmnet IP for installs that haven't yet been migrated.
            guard let ip = container.cockerIP ?? container.ip else { continue }

            // Match direct sur le nom du container
            if candidates.contains(container.name) { return ip }

            // Match sur le service compose (label com.cocker.service)
            if let service = container.labels["com.cocker.service"],
               candidates.contains(service) { return ip }

            // Match sur le short ID
            if candidates.contains(String(container.id.prefix(12))) { return ip }

            // Match sur le hostname
            if candidates.contains(container.hostname) { return ip }

            // Match sur les aliases réseau (label com.cocker.aliases)
            if let aliases = container.labels["com.cocker.aliases"]?.split(separator: ",") {
                for alias in aliases {
                    if candidates.contains(String(alias).trimmingCharacters(in: .whitespaces)) {
                        return ip
                    }
                }
            }
        }

        return nil
    }

    // Génère toutes les variantes d'un nom DNS à tester
    // "web.myproject_default.cocker" → ["web", "web.myproject_default", ...]
    private func normalizedNames(from name: String) -> Set<String> {
        var candidates = Set<String>()
        candidates.insert(name)

        // Retire le domaine .cocker
        let withoutCocker = name.hasSuffix(".\(Self.cockerDomain)")
            ? String(name.dropLast(Self.cockerDomain.count + 1))
            : name

        candidates.insert(withoutCocker)

        // Premier segment uniquement ("web.default" → "web")
        let firstPart = withoutCocker.split(separator: ".").first.map(String.init) ?? withoutCocker
        candidates.insert(firstPart)

        // Sans le trailing dot DNS (FQDN)
        let withoutDot = name.hasSuffix(".") ? String(name.dropLast()) : name
        candidates.insert(withoutDot)

        return candidates
    }

    // MARK: - IPv6 resolution

    private func resolveIPv6(name: String) async -> String? {
        let candidates = normalizedNames(from: name)
        let containers = await state.allContainers(includeAll: false)
        for container in containers {
            guard let ipv6 = container.ipv6 else { continue }
            if candidates.contains(container.name) { return ipv6 }
            if let service = container.labels["com.cocker.service"],
               candidates.contains(service) { return ipv6 }
            if candidates.contains(String(container.id.prefix(12))) { return ipv6 }
            if candidates.contains(container.hostname) { return ipv6 }
        }
        return nil
    }

    // MARK: - Response builders

    private func buildAResponse(header: DNSHeader, question: DNSQuestion, ip: String) -> Data {
        var responseHeader = header
        responseHeader.flags = header.responseFlags(rcode: 0, authoritative: true)
        responseHeader.anCount = 1

        var builder = DNSResponseBuilder()
        builder.appendHeader(responseHeader)
        builder.appendQuestion(question)
        builder.appendARecord(ip: ip, ttl: 10)  // TTL court → cohérence après restart container
        return builder.build()
    }

    private func buildEmptyResponse(header: DNSHeader, question: DNSQuestion) -> Data {
        var responseHeader = header
        responseHeader.flags = header.responseFlags(rcode: 0, authoritative: true)
        responseHeader.anCount = 0

        var builder = DNSResponseBuilder()
        builder.appendHeader(responseHeader)
        builder.appendQuestion(question)
        return builder.build()
    }

    private func buildAAAAResponse(header: DNSHeader, question: DNSQuestion, ipv6: String) -> Data {
        var responseHeader = header
        responseHeader.flags = header.responseFlags(rcode: 0, authoritative: true)
        responseHeader.anCount = 1

        var builder = DNSResponseBuilder()
        builder.appendHeader(responseHeader)
        builder.appendQuestion(question)
        builder.appendAAAARecord(ip: ipv6, ttl: 10)
        return builder.build()
    }

    private func buildNXDomain(header: DNSHeader, question: DNSQuestion) -> Data {
        var responseHeader = header
        responseHeader.flags = header.responseFlags(rcode: 3, authoritative: true)  // NXDOMAIN
        responseHeader.anCount = 0

        var builder = DNSResponseBuilder()
        builder.appendHeader(responseHeader)
        builder.appendQuestion(question)
        return builder.build()
    }

    // MARK: - Send response

    private func sendResponse(_ data: Data, toIP ip: String, port: UInt16, viaFD: Int32) {
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

    private func logDNS(_ name: String, result: String, authoritative: Bool) {
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
