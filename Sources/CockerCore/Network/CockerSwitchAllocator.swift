import Foundation

// Pure allocator for the cocker L2 switch private network (10.42.0.0/16).
// Each container that plugs into the switch gets :
//   - a unique IPv4 in 10.42.HI.LO
//   - a MAC built deterministically from the IP : 02:42:0a:2a:HI:LO
//     (matches Docker's 02:42:* locally-administered convention)
//
// The allocator hands them out linearly from .2 (skipping .0 = network and
// .1 = gateway). When the host id space (>= 65534) wraps, we restart from
// .2 — collisions only happen if 65k+ containers actually run concurrently
// (extremely unlikely on a single Mac).
//
// State (the in-use map) lives in NetworkManager ; this type just owns the
// transformation logic and is therefore unit-testable without any actor.

public enum CockerSwitchAllocator {
    /// CIDR of the private switch network.
    public static let subnet: String = "10.42.0.0/16"

    /// Default gateway address presented to containers (no one actually
    /// answers ARP on it ; Linux just wants something on the same subnet).
    public static let gateway: String = "10.42.0.1"

    /// First usable host id (1 is reserved for the gateway).
    public static let firstHost: UInt16 = 2

    /// Last usable host id before we wrap around. 10.42.255.254 is the
    /// broadcast-1 address.
    public static let lastHost: UInt16 = 65534

    /// Encode a 16-bit host id into a "10.42.HI.LO" address.
    public static func ip(forHost host: UInt16) -> String {
        let hi = UInt8((host >> 8) & 0xFF)
        let lo = UInt8(host & 0xFF)
        return "10.42.\(hi).\(lo)"
    }

    /// Compute the Docker-style MAC for a given IPv4 on the switch network.
    /// "10.42.HI.LO" → "02:42:0a:2a:HI:LO". Returns "02:42:0a:2a:00:00" if
    /// the input doesn't parse as four octets.
    public static func mac(forIP ip: String) -> String {
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return "02:42:0a:2a:00:00" }
        return String(format: "02:42:0a:2a:%02x:%02x", octets[2], octets[3])
    }

    /// Advance the cursor : returns the host id we should give out and the
    /// new cursor to remember. Wraps to `firstHost` once we pass `lastHost`.
    public static func nextHost(from cursor: UInt16) -> (host: UInt16, nextCursor: UInt16) {
        let h = cursor
        let next: UInt16 = (cursor < lastHost) ? cursor + 1 : firstHost
        return (h, next)
    }
}
