import Foundation

/// Addresses for `eth0`, the NIC attached to Apple's vmnet bridge.
///
/// Containers used to get this address from vmnet's DHCP server. That pool
/// is host-wide, capped at ~256 entries, never reclaimed and `root:wheel`,
/// so a machine that had started 256 containers stopped working until
/// somebody with root truncated a file — see
/// `docs/DESIGN-network-without-vmnet.md`. Choosing the address ourselves
/// removes the ceiling entirely; what it does not remove is the need to
/// know who already has what, which is this type's job.
///
/// Two populations share the subnet and neither is under our control:
///
///   * anything else on the host that vmnet gave a lease to — other VMs,
///     another cocker installation, `container`;
///   * our own containers, including ones that outlived a daemon restart.
///
/// So the caller must feed both into `allocate`. Getting that wrong is not
/// a theoretical concern: two containers on one address is silent, and
/// shows up as traffic arriving at the wrong one.
public enum NATAddressAllocator {

    /// Bottom of the range we allocate from.
    ///
    /// vmnet's `bootpd` hands out leases from the low end of the subnet, so
    /// staying high keeps self-assigned addresses clear of anything it
    /// issues later. Checking the lease file already covers what it has
    /// issued *so far*; this covers what it issues *next*, which we cannot
    /// see. Belt and braces, and free.
    public static let firstHost: UInt32 = 128

    /// Top of the range. `.255` is the broadcast address for a /24.
    public static let lastHost: UInt32 = 254

    /// Number of addresses this pool can hand out at once.
    public static var capacity: Int { Int(lastHost - firstHost) + 1 }

    /// Pick an address in `prefix`.0/24 that nothing else is using.
    ///
    /// - Parameters:
    ///   - prefix: first three octets of the vmnet subnet, e.g. "192.168.64".
    ///     Read from the bridge at runtime rather than hardcoded, because
    ///     vmnet does not always choose the same one.
    ///   - leased: every address currently in the host DHCP lease file.
    ///     Entries outside `prefix` are ignored.
    ///   - assigned: addresses cocker has already given to its own
    ///     containers, from persisted state.
    /// - Returns: the lowest free address, or nil when the range is full.
    public static func allocate(prefix: String,
                                leased: Set<String>,
                                assigned: Set<String>) -> String? {
        var inUse = Set<UInt32>()
        for ip in leased.union(assigned) {
            if let host = AddressPool.hostInSubnet(ip, prefix: prefix) {
                inUse.insert(host)
            }
        }
        // The gateway owns .1, which is below firstHost — but a caller could
        // narrow the range one day, so exclude it explicitly rather than
        // rely on the constant.
        inUse.insert(1)
        guard let host = AddressPool.lowestFree(first: firstHost,
                                                last: lastHost,
                                                inUse: inUse) else { return nil }
        return "\(prefix).\(host)"
    }

    /// First three octets of a dotted-quad gateway address, e.g.
    /// "192.168.64.1" → "192.168.64". nil if it isn't an IPv4 address.
    public static func subnetPrefix(ofGateway gateway: String) -> String? {
        guard let o = AddressPool.octets(of: gateway) else { return nil }
        return "\(o[0]).\(o[1]).\(o[2])"
    }
}
