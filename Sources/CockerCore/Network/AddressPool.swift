import Foundation

/// Lowest-free allocation over a bounded range of host ids.
///
/// This replaces the pattern it is named after: a monotonically advancing
/// cursor held in memory. A cursor is only correct while the process that
/// owns it stays alive — restart the daemon and it resets to the start of
/// the range while previously handed-out addresses are still in use, so it
/// hands out duplicates. `NetworkManager` did exactly that, and containers
/// that survived a `cockerd` restart could end up sharing an address with a
/// container created afterwards.
///
/// Taking the set of addresses actually in use and returning the lowest
/// free one has no such state to lose. The caller derives `inUse` from
/// whatever the durable source of truth is — for cocker, the persisted
/// container list — so "who has what" cannot drift from reality.
public enum AddressPool {

    /// Lowest id in `first...last` that is not in `inUse`, or nil when every
    /// id in the range is taken.
    ///
    /// Deliberately returns nil rather than wrapping. Wrapping around a full
    /// pool means handing out an address somebody already has, which fails
    /// later, somewhere else, as mysterious traffic going to the wrong
    /// container. Refusing is the honest answer and lets the caller say so.
    public static func lowestFree(first: UInt32,
                                  last: UInt32,
                                  inUse: Set<UInt32>) -> UInt32? {
        guard first <= last else { return nil }
        var id = first
        while id <= last {
            if !inUse.contains(id) { return id }
            // `last` may be UInt32.max in principle; avoid overflowing past it.
            if id == last { break }
            id += 1
        }
        return nil
    }

    /// Parse a dotted-quad into its four octets, or nil if it isn't one.
    public static func octets(of ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { UInt8($0) }
        guard values.count == 4 else { return nil }
        return values
    }

    /// Last octet of `ip`, but only when the first three match `prefix`
    /// (e.g. "192.168.64"). Used to read "which hosts of *my* /24 are
    /// already taken" out of a list that also contains other subnets.
    public static func hostInSubnet(_ ip: String, prefix: String) -> UInt32? {
        guard let o = octets(of: ip) else { return nil }
        guard "\(o[0]).\(o[1]).\(o[2])" == prefix else { return nil }
        return UInt32(o[3])
    }
}
