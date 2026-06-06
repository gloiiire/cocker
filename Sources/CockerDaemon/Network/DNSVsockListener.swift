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

    init(dnsServer: DNSServer) {
        self.dnsServer = dnsServer
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
            fputs("[dns/vsock] dup() failed: \(String(cString: strerror(errno)))\n", stderr)
            fflush(stderr)
            return false
        }

        // Forward the fd to the DNS server's existing TCP-style handler.
        // The DNS wire is exactly the same on vsock as it is on TCP.
        let server = dnsServer
        Task.detached(priority: .userInitiated) {
            await server.handleStreamedDNSQuery(fd: fd)
        }
        return true
    }
}
