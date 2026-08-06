import Foundation
import Testing
import Darwin
@testable import CockerCore
@testable import CockerDaemon

/// Publishing a port that is already taken used to report success.
///
/// `spawnForwarder` proves only that the child process started; the `bind`
/// happens inside it and failing there is an `exit(1)` nobody waits on. So
/// `cocker run -d -p 18080:80` exited 0, `ps` showed `0.0.0.0:18080->80/tcp`
/// and `cocker port` agreed — while `lsof` showed the unrelated process that
/// actually held the port. Everything the user could see was read back from
/// the requested config, never from an observed listener.
@Suite("Published ports — preflight")
struct PortPublishPreflightTests {

    /// Bind a real socket so the test asserts against the kernel's answer
    /// rather than a model of it. Returns the port actually assigned.
    private func occupy(_ ip: String = "0.0.0.0") -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // let the kernel pick a free one
        if ip == "0.0.0.0" {
            addr.sin_addr.s_addr = INADDR_ANY
        } else {
            inet_pton(AF_INET, ip, &addr.sin_addr)
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return nil }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard got == 0 else { close(fd); return nil }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    @Test func refusesAHostPortSomethingElseIsListeningOn() throws {
        guard let held = occupy() else {
            Issue.record("could not bind a probe socket")
            return
        }
        defer { close(held.fd) }

        #expect(throws: CockerError.self) {
            try PortForwarder.preflight(
                mappings: [PortMapping(hostPort: held.port, containerPort: 80)])
        }
    }

    /// The error has to name the address, because a compose file publishing
    /// six ports needs to say *which* one is taken.
    @Test func theRefusalNamesTheAddress() throws {
        guard let held = occupy() else {
            Issue.record("could not bind a probe socket")
            return
        }
        defer { close(held.fd) }

        do {
            try PortForwarder.preflight(
                mappings: [PortMapping(hostPort: held.port, containerPort: 80)])
            Issue.record("preflight accepted a port that is in use")
        } catch let error as CockerError {
            #expect(error.description.contains("\(held.port)"))
            #expect(error.description.contains("0.0.0.0"))
            // 125 — cocker itself could not carry out the run, which is what
            // docker reports for the same condition.
            #expect(error.exitCode == 125)
        }
    }

    @Test func acceptsAFreeHostPort() throws {
        // Take a port, learn its number, release it. The kernel handed it out
        // as free a moment ago, so this is a port nothing is listening on.
        guard let held = occupy() else {
            Issue.record("could not bind a probe socket")
            return
        }
        let port = held.port
        close(held.fd)

        try PortForwarder.preflight(
            mappings: [PortMapping(hostPort: port, containerPort: 80)])
    }

    /// A mapping on loopback must not be refused because something holds the
    /// same port on another interface — and vice versa. Binding `0.0.0.0`
    /// conflicts with everything, which is why the probe uses the real
    /// address rather than assuming every-interface.
    @Test func theProbeUsesTheRequestedBindAddress() throws {
        guard let held = occupy("127.0.0.1") else {
            Issue.record("could not bind a probe socket")
            return
        }
        defer { close(held.fd) }

        #expect(throws: CockerError.self) {
            try PortForwarder.preflight(
                mappings: [PortMapping(hostPort: held.port, containerPort: 80,
                                       hostIP: "127.0.0.1")])
        }
    }

    /// UDP mappings are not forwarded at all today. Refusing them here would
    /// report the wrong reason for the wrong problem.
    @Test func udpMappingsAreNotProbed() throws {
        guard let held = occupy() else {
            Issue.record("could not bind a probe socket")
            return
        }
        defer { close(held.fd) }

        try PortForwarder.preflight(
            mappings: [PortMapping(hostPort: held.port, containerPort: 53, proto: .udp)])
    }

    @Test func noMappingsIsNotAFailure() throws {
        try PortForwarder.preflight(mappings: [])
    }
}
