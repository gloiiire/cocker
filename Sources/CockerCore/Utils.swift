import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Retourne l'adresse IPv4 du host accessible depuis les interfaces réseau actives.
/// Cherche en priorité les interfaces en* (Wi-Fi / Ethernet) non-loopback.
public func localHostIP() -> String {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return "127.0.0.1" }
    defer { freeifaddrs(ifaddr) }

    var current = ifaddr
    while let addr = current {
        let name = String(cString: addr.pointee.ifa_name)
        if addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) && name.hasPrefix("en") {
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = addr.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                inet_ntop(AF_INET, &sin.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: buf)
            if !ip.hasPrefix("127.") && !ip.isEmpty {
                return ip
            }
        }
        current = addr.pointee.ifa_next
    }
    return "127.0.0.1"
}
