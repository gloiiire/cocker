import Foundation
import CockerCore
import Network

// Network manager using vmnet.framework for NAT and bridge networking
// Manages subnets, IP allocation, and port forwarding

actor NetworkManager {
    private let store: StateStore
    private var allocatedIPs: [String: String] = [:]    // containerID -> IPv4
    private var allocatedIPv6s: [String: String] = [:]  // containerID -> IPv6
    private var allocatedCockerIPs: [String: String] = [:]  // containerID -> 10.42.x.x
    private var cockerHostCounter: UInt16 = CockerSwitchAllocator.firstHost

    // Préfixe IPv6 pour les réseaux cocker : fd00:c0c4::/48
    private static let ipv6Prefix = "fd00:c0c4::"

    // Default networks
    private static let defaultNetworks: [NetworkInfo] = [
        NetworkInfo(id: "bridge", name: "bridge", driver: .bridge, subnet: "172.17.0.0/16", gateway: "172.17.0.1"),
        NetworkInfo(id: "host", name: "host", driver: .host, subnet: "0.0.0.0/0", gateway: "0.0.0.0"),
        NetworkInfo(id: "none", name: "none", driver: .none, subnet: "127.0.0.1/8", gateway: "127.0.0.1"),
    ]

    init(store: StateStore) async throws {
        self.store = store
        // Ensure default networks exist
        for net in Self.defaultNetworks {
            if await store.network(id: net.name) == nil {
                try await store.store(network: net)
            }
        }
    }

    // MARK: - Network CRUD

    func create(request: NetworkCreateRequest) async throws -> NetworkInfo {
        if await store.network(id: request.name) != nil {
            throw CockerError.networkAlreadyExists(request.name)
        }

        let subnet = request.subnet ?? generateSubnet()
        let gateway = request.gateway ?? deriveGateway(from: subnet)

        let network = NetworkInfo(
            name: request.name,
            driver: request.driver,
            subnet: subnet,
            gateway: gateway,
            // `--label` reached this far and was then dropped on the floor,
            // so `network ls --filter label=…` could never match anything.
            labels: request.labels
        )

        try await store.store(network: network)
        return network
    }

    func get(_ id: String) async throws -> NetworkInfo {
        guard let net = await store.network(id: id) else {
            throw CockerError.networkNotFound(id)
        }
        return net
    }

    func list() async -> [NetworkInfo] {
        await store.allNetworks()
    }

    func remove(_ id: String, force: Bool = false) async throws {
        let net = try await get(id)

        // Prevent deletion of default networks
        guard net.name != "bridge" && net.name != "host" && net.name != "none" else {
            throw CockerError.networkInUse(id)
        }

        // Si force=true, on disconnect tous les containers (utile pour `compose down`
        // où les containers ont été stoppés/supprimés mais leur référence dans
        // network.containers persiste).
        if force {
            var cleaned = net
            cleaned.containers.removeAll()
            try await store.store(network: cleaned)
        } else {
            // Mode strict : on filtre les containers qui n'existent plus
            let stillExisting = await store.allContainers(includeAll: true)
                .compactMap { $0.id }
            let activeRefs = net.containers.filter { stillExisting.contains($0) }
            guard activeRefs.isEmpty else {
                throw CockerError.networkInUse(net.name)
            }
            if activeRefs.count != net.containers.count {
                var cleaned = net
                cleaned.containers = activeRefs
                try await store.store(network: cleaned)
            }
        }

        try await store.removeNetwork(id: net.id)
    }

    func connect(containerID: String, networkID: String) async throws {
        guard var net = await store.network(id: networkID) else {
            throw CockerError.networkNotFound(networkID)
        }
        if !net.containers.contains(containerID) {
            net.containers.append(containerID)
            try await store.store(network: net)
        }
    }

    func disconnect(containerID: String, networkID: String) async throws {
        guard var net = await store.network(id: networkID) else {
            throw CockerError.networkNotFound(networkID)
        }
        net.containers.removeAll { $0 == containerID }
        try await store.store(network: net)
    }

    // MARK: - IP allocation

    func allocateIP(for containerID: String, subnet: String = "172.17.0.0/16") -> String {
        if let existing = allocatedIPs[containerID] { return existing }

        // Take the lowest free host address rather than counting containers.
        //
        // `2 + allocatedIPs.count` hands out duplicates the moment anything
        // is released: start three containers (.2 .3 .4), stop the middle
        // one, start another — count is 2 again, so the newcomer gets .4,
        // which is already taken. Past 253 it wrapped to .2 unconditionally.
        // DHCP overwrites `container.ip` later, but this is what lands in
        // state.json and what `inspect` shows until then.
        let base = parseSubnetBase(subnet)
        let taken = Set(allocatedIPs.values)
        for octet in 2...254 {
            let candidate = "\(base).\(octet)"
            if !taken.contains(candidate) {
                allocatedIPs[containerID] = candidate
                return candidate
            }
        }
        // 253 containers on one subnet — the lease pool gives out long
        // before this, so returning the last address is honest enough.
        let exhausted = "\(base).254"
        allocatedIPs[containerID] = exhausted
        return exhausted
    }

    func releaseIP(for containerID: String) {
        allocatedIPs.removeValue(forKey: containerID)
        allocatedIPv6s.removeValue(forKey: containerID)
        allocatedCockerIPs.removeValue(forKey: containerID)
    }

    // MARK: - Cocker switch network (10.42.0.0/16)
    //
    // Each container gets a second NIC plugged into the userspace L2 switch
    // running inside cockerd. IPs are allocated linearly from 10.42.0.2.
    // The MAC encodes the same 2-byte host id in its last two bytes:
    //   IP  = 10.42.HI.LO
    //   MAC = 02:42:0A:2A:HI:LO
    // (locally-administered, similar to Docker's 02:42:* range)

    func allocateCockerIPAndMAC(for containerID: String) -> (ip: String, mac: String) {
        if let ip = allocatedCockerIPs[containerID] {
            return (ip, CockerSwitchAllocator.mac(forIP: ip))
        }
        let (host, next) = CockerSwitchAllocator.nextHost(from: cockerHostCounter)
        cockerHostCounter = next
        let ip = CockerSwitchAllocator.ip(forHost: host)
        allocatedCockerIPs[containerID] = ip
        return (ip, CockerSwitchAllocator.mac(forIP: ip))
    }

    static let cockerSwitchSubnet = CockerSwitchAllocator.subnet
    static let cockerSwitchGateway = CockerSwitchAllocator.gateway

    func allocateIPv6(for containerID: String, networkName: String = "bridge") -> String {
        if let existing = allocatedIPv6s[containerID] { return existing }

        // Derive the suffix from a *stable* hash of the container id.
        //
        // This used to use `containerID.hashValue`, which Swift seeds per
        // process — so a container's IPv6 changed every time cockerd
        // restarted, while `container.ipv6` in state.json kept the old value.
        // Unlike `container.ip`, nothing later corrects it, so `inspect`
        // reported an address the container did not have.
        //
        // FNV-1a: tiny, dependency-free, and identical across runs.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in containerID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }

        // Probe for a free suffix instead of trusting a 16-bit hash to be
        // unique — birthday collisions start around 300 containers, and a
        // collision here means two containers share an address.
        let taken = Set(allocatedIPv6s.values)
        var suffix = UInt16(truncatingIfNeeded: hash)
        for _ in 0..<UInt16.max {
            if suffix == 0 { suffix = 1 }  // ::0 is the subnet itself
            let candidate = "\(Self.ipv6Prefix)\(String(format: "%x", suffix))"
            if !taken.contains(candidate) {
                allocatedIPv6s[containerID] = candidate
                return candidate
            }
            suffix = suffix &+ 1
        }
        // 65k containers on one host is not a case worth handling gracefully.
        let fallback = "\(Self.ipv6Prefix)\(String(format: "%x", suffix))"
        allocatedIPv6s[containerID] = fallback
        return fallback
    }

    // MARK: - Port forwarding
    // vmnet.framework handles NAT; port forwarding configured at VM boot via kernel cmdline
    // The VZNATNetworkDeviceAttachment handles basic connectivity; for port forwarding
    // we use the VZVirtualMachine's socket API (future: pf rules)

    func configurePortForwarding(containerID: String, ports: [PortMapping]) async {
        // Port forwarding with VZNATNetworkDeviceAttachment is handled automatically
        // for outbound traffic. For inbound (host -> container), we'd set up pf rules.
        // This is a simplified implementation that logs the intent.
        for port in ports {
            print("[network] Port forward: 0.0.0.0:\(port.hostPort) -> container:\(port.containerPort)/\(port.proto.rawValue)")
        }
    }

    // MARK: - Subnet utilities

    private func generateSubnet() -> String {
        // Use 172.20.x.0/24 range, incrementing for each network
        let count = (allocatedIPs.count % 200) + 20
        return "172.\(count).0.0/16"
    }

    private func deriveGateway(from subnet: String) -> String {
        let base = parseSubnetBase(subnet)
        return "\(base).1"
    }

    private func parseSubnetBase(_ subnet: String) -> String {
        // "172.17.0.0/16" -> "172.17.0"
        let withoutMask = subnet.split(separator: "/").first ?? ""
        let octets = withoutMask.split(separator: ".").prefix(3).joined(separator: ".")
        return octets
    }
}
