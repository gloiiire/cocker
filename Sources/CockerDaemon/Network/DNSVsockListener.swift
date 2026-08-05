import Foundation
import Virtualization
import Darwin
import CockerCore

// VZVirtioSocketListener delegate that accepts vsock connections from
// container VMs and feeds them to the DNS resolver.
//
// Why vsock and not UDP/TCP via vmnet : Apple's App Sandbox silently
// drops payload data from the vmnet kernel extension to user-signed
// daemons (cockerd). UDP packets are dropped outright ; TCP accept()
// succeeds but read() returns 0 immediately. vsock bypasses vmnet
// entirely — it's a direct host↔VM channel exposed by Apple's
// Virtualization.framework.
//
// Wire format : same as DNS-over-TCP (RFC 1035 §4.2.2) — 2-byte length
// prefix followed by the DNS message. cocker-init's in-VM DNS proxy
// connects on AF_VSOCK CID=2 (host) port=5353 per query, sends the
// framed request, reads the framed response, closes.

@MainActor
final class DNSVsockListener: NSObject, VZVirtioSocketListenerDelegate {
    static let vsockPort: UInt32 = 5353

    private let dnsServer: DNSServer

    /// Which container a vsock connection came from.
    ///
    /// One listener instance is shared across every VM, so this callback is
    /// the only place the asker can be identified — and it is handed the
    /// `VZVirtioSocketDevice`, which belongs to exactly one VM. `VMRuntime`
    /// registers the owner when it attaches the listener.
    ///
    /// This exists so DNS can be scoped to the querier's network. Without
    /// it every container resolves every other container's name, including
    /// ones it cannot reach — which is how `cocker network create` managed
    /// to look like it isolated things while isolating nothing.
    private let ownerOfDevice: @MainActor @Sendable (VZVirtioSocketDevice) -> String?

    init(dnsServer: DNSServer,
         ownerOfDevice: @escaping @MainActor @Sendable (VZVirtioSocketDevice) -> String?) {
        self.dnsServer = dnsServer
        self.ownerOfDevice = ownerOfDevice
        super.init()
    }

    /// Wrap the delegate in a VZVirtioSocketListener. The caller registers
    /// this listener on each VM's socket device after the VM starts.
    func makeListener() -> VZVirtioSocketListener {
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        return listener
    }

    // MARK: - VZVirtioSocketListenerDelegate

    nonisolated func listener(_ listener: VZVirtioSocketListener,
                              shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                              from socketDevice: VZVirtioSocketDevice) -> Bool {
        // Apple hands us a connection. Duplicate the fd so the connection
        // object can be released while we own a working fd on a detached
        // task that handles the DNS roundtrip.
        let originalFD = connection.fileDescriptor
        let fd = Darwin.dup(originalFD)
        guard fd >= 0 else {
            CockerLog.shared.error("dns/vsock", "dup() failed: \(String(cString: strerror(errno)))")
            return false
        }

        // Forward the fd to the DNS server's existing TCP-style handler.
        // The DNS wire is exactly the same on vsock as it is on TCP.
        let server = dnsServer
        let resolveOwner = ownerOfDevice
        Task.detached(priority: .userInitiated) {
            let asker = await MainActor.run { resolveOwner(socketDevice) }
            await server.handleStreamedDNSQuery(fd: fd, askedBy: asker)
        }
        return true
    }
}
