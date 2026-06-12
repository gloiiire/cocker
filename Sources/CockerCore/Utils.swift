import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// **I8 helper** : every socket call in cocker performs the same
/// `withUnsafePointer(to:) → withMemoryRebound(to: sockaddr.self)` dance
/// to satisfy POSIX's `bind/connect/sendto` signatures. The pattern is
/// safe but extremely verbose ; this helper encapsulates the
/// pointer-massaging so new socket code reads like a straight call.
///
/// Existing call sites still use the inline pattern — migrating them is
/// mechanical but risks regression in code paths we don't have full
/// integration coverage for, so we add the helper now and let new code
/// adopt it. Audit task I8 deliverable.
///
/// Usage :
///   var addr = sockaddr_in(...)
///   let rc = withSockaddr(&addr) { sa, len in
///       Darwin.bind(fd, sa, len)
///   }
@inlinable
public func withSockaddr<T, R>(
    _ addr: inout T,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
) -> R {
    let size = socklen_t(MemoryLayout<T>.size)
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            body(sa, size)
        }
    }
}

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
