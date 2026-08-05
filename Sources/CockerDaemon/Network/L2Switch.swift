import Foundation
import Darwin
import CockerCore

// Userspace Layer-2 Ethernet switch
//
// Each running container exposes a second virtual NIC (eth1) to its VM via
// VZFileHandleNetworkDeviceAttachment. The VZ side reads/writes raw Ethernet
// frames over a datagram socket (one datagram = one frame). The other end of
// the socketpair lives here — that's the "switch port".
//
// What this switch does, per frame received on port P :
//   1. Learn  : srcMAC → P (MAC learning table)
//   2. Decide :
//        - dst is broadcast (ff:ff:ff:ff:ff:ff) or multicast (low bit of first
//          byte set) → flood to all other ports
//        - dst MAC is known in the table → unicast to that port
//        - dst MAC is unknown → flood (standard learning-switch behavior)
//
// Each VM also has eth0 attached to Apple's NAT for outbound internet. eth1
// is purely the inter-container fabric ; we don't bridge it to anything host
// side. Containers reach each other through this switch and nothing else.
//
// Frame size is capped at 1518 bytes (standard Ethernet MTU + headers); we
// configure the VZ attachment with MTU=1500.

actor L2Switch: L2Switching {
    static let mtu = 1500
    private static let maxFrame = 1518  // MTU + 14-byte Ethernet header + 4-byte FCS slack

    /// Shared, **concurrent** GCD queue that drives every port's DispatchSource.
    /// We don't park a cooperative-pool slot per port — that's exactly what the
    /// previous `Task.detached { ... blocking read ... }` design did, and with
    /// ~8 ports it was enough to deadlock the entire daemon because every
    /// background async (watcher, healthcheck, signal source) shares the same
    /// pool. GCD's worker threads scale automatically with load, decoupled
    /// from the Swift Concurrency runtime.
    private static let readQueue = DispatchQueue(
        label: "cocker.l2switch.read", qos: .userInitiated, attributes: .concurrent)

    private struct Port: Sendable {
        let containerID: String
        let switchFD: Int32    // our end of the socketpair
        let staticMAC: UInt64  // MAC we assigned at VM-creation time
        /// The user-defined network this port belongs to. Frames never cross
        /// between different values — that is the whole of the isolation
        /// `cocker network create` has always claimed and never had.
        let network: String
    }

    private var ports: [String: Port] = [:]
    private var macTable: [UInt64: String] = [:]  // MAC → containerID
    private var readSources: [String: DispatchSourceRead] = [:]

    private var verboseLogging: Bool = false

    init(verboseLogging: Bool = false) {
        self.verboseLogging = verboseLogging
    }

    // MARK: - Public API

    /// Create a socketpair, register one end as a port, return the other end
    /// wrapped in a FileHandle so the caller can hand it to VZFileHandle…
    /// attachment. Pre-seeds the MAC learning table with `staticMAC`.
    func addPort(containerID: String, staticMAC: String, network: String) -> FileHandle? {
        guard let macInt = Self.parseMAC(staticMAC) else {
            log("addPort: invalid MAC \(staticMAC) for \(containerID)")
            return nil
        }
        if ports[containerID] != nil {
            log("addPort: port already exists for \(containerID), removing first")
            removePort(containerID: containerID)
        }

        var fds: [Int32] = [-1, -1]
        let rc = socketpair(AF_LOCAL, SOCK_DGRAM, 0, &fds)
        guard rc == 0 else {
            log("addPort: socketpair failed: \(String(cString: strerror(errno)))")
            return nil
        }
        // Generous send/receive buffers — bursts of small frames otherwise lose
        // packets under load. 2 MiB each is well under macOS defaults.
        var bufSize: Int32 = 2 * 1024 * 1024
        let sz = socklen_t(MemoryLayout<Int32>.size)
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, sz)
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, sz)
        }

        let switchFD = fds[0]
        let vzFD = fds[1]

        let port = Port(containerID: containerID, switchFD: switchFD,
                        staticMAC: macInt, network: network)
        ports[containerID] = port
        macTable[macInt] = containerID

        log("addPort: \(containerID) MAC=\(staticMAC) net=\(network) switchFD=\(switchFD) vzFD=\(vzFD)")

        // DispatchSourceRead drains frames as they arrive without parking a
        // pool thread on a blocking read(). On EOF / error / port removal,
        // the source cancels and its buffer is deallocated.
        attachReadSource(fd: switchFD, containerID: containerID)

        return FileHandle(fileDescriptor: vzFD, closeOnDealloc: true)
    }

    /// Remove the port and clean up MAC table entries pointing to it. Cancels
    /// our DispatchSource (which deallocates its buffer in setCancelHandler)
    /// and closes our side of the socketpair.
    func removePort(containerID: String) {
        guard let port = ports.removeValue(forKey: containerID) else { return }
        macTable = macTable.filter { $0.value != containerID }
        if let source = readSources.removeValue(forKey: containerID) {
            source.cancel()
        }
        close(port.switchFD)
        log("removePort: \(containerID) (switchFD \(port.switchFD) closed)")
    }

    // MARK: - Read source

    private func attachReadSource(fd: Int32, containerID: String) {
        let bufPtr = UnsafeMutableRawPointer.allocate(byteCount: Self.maxFrame, alignment: 1)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.readQueue)
        source.setEventHandler { [weak self] in
            let n = read(fd, bufPtr, Self.maxFrame)
            if n <= 0 {
                if n < 0 && errno == EINTR { return }
                source.cancel()
                return
            }
            let frame = Data(bytes: bufPtr, count: n)
            // Hop into the actor to update the MAC table and route the frame.
            // The actor's serial executor is independent of the GCD queue so
            // there's no deadlock risk.
            guard let self else { source.cancel(); return }
            Task { await self.forward(frame: frame, from: containerID) }
        }
        source.setCancelHandler {
            bufPtr.deallocate()
        }
        source.resume()
        readSources[containerID] = source
    }

    private func forward(frame: Data, from sourceContainerID: String) {
        guard frame.count >= 14 else { return }  // need an Ethernet header

        // Bytes 0..5 = dst MAC, 6..11 = src MAC, 12..13 = ethertype
        let dstMAC = Self.macFromBytes(frame, offset: 0)
        let srcMAC = Self.macFromBytes(frame, offset: 6)

        // Anti-spoofing : the source MAC on a frame coming out of `port` must
        // equal the MAC we assigned to that port when the container booted.
        // If a container tries to spoof someone else's MAC (to intercept
        // their traffic by poisoning the learning table), we drop the frame
        // and don't update the learning table.
        guard let sourcePort = ports[sourceContainerID] else { return }
        if srcMAC != sourcePort.staticMAC {
            if verboseLogging {
                log("drop spoofed src MAC from \(sourceContainerID): claimed=\(Self.macToString(srcMAC)) expected=\(Self.macToString(sourcePort.staticMAC))")
            }
            return
        }

        // MAC learning : remember which port the source MAC lives on.
        macTable[srcMAC] = sourceContainerID

        let isBroadcast = dstMAC == 0xFFFF_FFFF_FFFF
        let isMulticast = (frame[0] & 0x01) != 0  // low bit of first MAC byte = multicast/broadcast

        if isBroadcast || isMulticast {
            flood(frame: frame, except: sourceContainerID,
                  onNetwork: sourcePort.network,
                  reason: isBroadcast ? "bcast" : "mcast")
            return
        }

        if let targetID = macTable[dstMAC], targetID != sourceContainerID,
           let targetPort = ports[targetID] {
            // Network isolation. `cocker network create` has always accepted
            // a name and a subnet, stored them, and enforced nothing: every
            // container shared one flat segment, so two "separate" networks
            // could reach each other. A user who splits two stacks apart for
            // isolation got none, and was told nothing.
            guard targetPort.network == sourcePort.network else {
                if verboseLogging {
                    log("drop \(sourceContainerID)[\(sourcePort.network)] → "
                        + "\(targetID)[\(targetPort.network)]: different networks")
                }
                return
            }
            sendFrame(frame, to: targetPort.switchFD)
            if verboseLogging {
                log("\(sourceContainerID) → \(targetID) (\(frame.count) B)")
            }
            return
        }

        // Unknown unicast : flood (standard learning switch behavior), but
        // only within the sender's own network.
        flood(frame: frame, except: sourceContainerID,
              onNetwork: sourcePort.network, reason: "unknown-dst")
    }

    private func flood(frame: Data, except sourceID: String,
                       onNetwork network: String, reason: String) {
        // Broadcast and unknown-unicast flooding are how ARP finds a peer, so
        // scoping them is what actually stops one network discovering another
        // — a MAC that never floods across is never learned across.
        for (id, port) in ports where id != sourceID && port.network == network {
            sendFrame(frame, to: port.switchFD)
        }
        if verboseLogging {
            log("flood (\(reason)) from \(sourceID) (\(frame.count) B) to \(ports.count - 1) ports")
        }
    }

    private nonisolated func sendFrame(_ frame: Data, to fd: Int32) {
        _ = frame.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base, raw.count)
        }
    }

    // MARK: - Helpers

    private static func parseMAC(_ s: String) -> UInt64? {
        let parts = s.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var result: UInt64 = 0
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else { return nil }
            result = (result << 8) | UInt64(byte)
        }
        return result
    }

    private static func macFromBytes(_ data: Data, offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<6 {
            result = (result << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return result
    }

    private static func macToString(_ mac: UInt64) -> String {
        String(format: "%02x:%02x:%02x:%02x:%02x:%02x",
               (mac >> 40) & 0xFF, (mac >> 32) & 0xFF, (mac >> 24) & 0xFF,
               (mac >> 16) & 0xFF, (mac >>  8) & 0xFF,  mac        & 0xFF)
    }

    private nonisolated func log(_ msg: String) {
        CockerLog.shared.debug("l2switch", "\(msg)")
    }
}
