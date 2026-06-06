import Foundation
import CockerCore
import Network

// Network manager using vmnet.framework for NAT and bridge networking
// Manages subnets, IP allocation, and port forwarding

actor NetworkManager {
    private let store: StateStore
    private var allocatedIPs: [String: String] = [:]    // containerID -> IPv4
    private var allocatedIPv6s: [String: String] = [:]  // containerID -> IPv6

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
            gateway: gateway
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

    func remove(_ id: String) async throws {
        let net = try await get(id)

        // Prevent deletion of default networks
        guard net.name != "bridge" && net.name != "host" && net.name != "none" else {
            throw CockerError.networkInUse(id)
        }

        // Check if any container is connected
        guard net.containers.isEmpty else {
            throw CockerError.networkInUse(net.name)
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

        // Parse subnet to generate IP in range
        let base = parseSubnetBase(subnet)
        var octet4 = 2 + allocatedIPs.count  // Start at .2 (.1 is gateway)
        if octet4 > 254 { octet4 = 2 }       // Wrap around (simplified)
        let ip = "\(base).\(octet4)"
        allocatedIPs[containerID] = ip
        return ip
    }

    func releaseIP(for containerID: String) {
        allocatedIPs.removeValue(forKey: containerID)
        allocatedIPv6s.removeValue(forKey: containerID)
    }

    func allocateIPv6(for containerID: String, networkName: String = "bridge") -> String {
        if let existing = allocatedIPv6s[containerID] { return existing }
        // Générer une adresse IPv6 unique dans fd00:c0c4::/48
        // abs() crash sur Int.min — on cast via bitPattern pour être safe
        let hash = UInt(bitPattern: containerID.hashValue)
        let suffix = UInt16(truncatingIfNeeded: hash) & 0xFFFF
        let ipv6 = "\(Self.ipv6Prefix)\(String(format: "%x", suffix))"
        allocatedIPv6s[containerID] = ipv6
        return ipv6
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
