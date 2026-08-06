import Foundation
import CockerCore
import Darwin

/// Port forwarding TCP host → container.
///
/// Implémentation : spawn d'un sous-process `cocker-portfwd` par mapping
/// de port. Ce binaire séparé est signé SANS l'entitlement
/// `com.apple.security.virtualization`, donc pas de sandbox macOS sur les
/// bridges vmnet privés (192.168.64.0/24). Avant cette approche, le
/// forwarder intégré dans `cockerd` recevait EHOSTUNREACH au `connect()`
/// upstream malgré une route valide et un ping qui passait.
///
/// Lifecycle : un process par (containerID, hostPort). Cocker garde leur
/// PID et les SIGTERM au stop/kill/remove du container.
public actor PortForwarder {
    /// Path du binaire cocker-portfwd, résolu au démarrage du daemon.
    private let portFwdBinary: URL

    private var processes: [String: [Process]] = [:]  // containerID → [Process]

    public init(portFwdBinary: URL) {
        self.portFwdBinary = portFwdBinary
    }

    /// Démarre le forwarding pour un container.
    public func start(
        containerID: String,
        containerIP: String,
        mappings: [PortMapping]
    ) async {
        // Replacement is atomic from the listener's point of view: stop and
        // reap the previous processes before trying to bind the same ports.
        await stop(containerID: containerID)
        var procs: [Process] = []
        for port in mappings {
            // No UDP relay exists — the forwarder pipes TCP through
            // /usr/bin/nc. This was a `debug` line, invisible at the default
            // level, while `ps` went on advertising `0.0.0.0:53->53/udp`.
            // `warn` so an operator reading the log finds out why their DNS
            // container answers nobody.
            guard port.proto == .tcp else {
                CockerLog.shared.warn("portfwd",
                    "host port \(port.hostPort)/\(port.proto.rawValue) is NOT forwarded — "
                    + "cocker forwards TCP only")
                continue
            }
            do {
                let proc = try spawnForwarder(
                    hostIP: port.hostIP,
                    hostPort: port.hostPort,
                    containerIP: containerIP,
                    containerPort: port.containerPort
                )
                procs.append(proc)
                CockerLog.shared.info("portfwd",
                    "\(port.hostIP):\(port.hostPort) → \(containerIP):\(port.containerPort) " +
                    "(pid \(proc.processIdentifier), container \(String(containerID.prefix(12))))")
            } catch {
                CockerLog.shared.error("portfwd", "error spawning forwarder for \(port.hostPort): \(error)")
            }
        }
        if !procs.isEmpty {
            processes[containerID] = procs
        }
    }

    /// Arrête tous les forwards d'un container (SIGTERM).
    public func stop(containerID: String) async {
        guard let procs = processes[containerID] else { return }
        for proc in procs {
            if proc.isRunning {
                proc.terminate()
            }
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if proc.isRunning {
                Darwin.kill(proc.processIdentifier, SIGKILL)
                while proc.isRunning { try? await Task.sleep(nanoseconds: 10_000_000) }
            }
        }
        processes.removeValue(forKey: containerID)
        CockerLog.shared.debug("portfwd", "stopped all forwarders for container \(String(containerID.prefix(12)))")
    }

    /// Cleanup au shutdown du daemon.
    public func stopAll() async {
        for (_, procs) in processes {
            for proc in procs where proc.isRunning {
                proc.terminate()
            }
        }
        processes.removeAll()
    }

    // MARK: - Preflight

    /// Refuse a mapping we cannot actually take, *before* the VM boots.
    ///
    /// `spawnForwarder` only proves the child process started. The `bind`
    /// happens inside it, and failing there is an `exit(1)` nobody waits on —
    /// so a host port already in use produced a running container whose
    /// published port existed only in `ps`, `cocker port` and `inspect`, all
    /// of which read back the requested config rather than an observed
    /// listener. `run` exited 0. Docker refuses the run instead.
    ///
    /// Binds with the same `SO_REUSEADDR` the forwarder uses, so this accepts
    /// exactly what the forwarder would accept — a stricter probe would
    /// refuse ports sitting in `TIME_WAIT` that are genuinely usable.
    ///
    /// Not a lock: something can still take the port between this check and
    /// the forwarder's own bind. It closes the window that actually bites —
    /// a port held by a long-running process — and never widens it.
    ///
    /// UDP is skipped: those mappings are not forwarded at all today, which
    /// is a separate lie with its own fix.
    public nonisolated static func preflight(mappings: [PortMapping]) throws {
        for m in mappings where m.proto == .tcp {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            // Out of descriptors is not evidence the port is taken. Let the
            // run proceed rather than invent a reason to refuse it.
            guard sock >= 0 else { continue }
            defer { close(sock) }

            var yes: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes,
                       socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = m.hostPort.bigEndian
            if m.hostIP == "0.0.0.0" || m.hostIP.isEmpty {
                addr.sin_addr.s_addr = INADDR_ANY
            } else {
                inet_pton(AF_INET, m.hostIP, &addr.sin_addr)
            }

            let rc = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard rc == 0 else {
                throw CockerError.portAlreadyAllocated("\(m.hostIP):\(m.hostPort)")
            }
        }
    }

    // MARK: - Spawn helper

    private func spawnForwarder(
        hostIP: String,
        hostPort: UInt16,
        containerIP: String,
        containerPort: UInt16
    ) throws -> Process {
        guard FileManager.default.fileExists(atPath: portFwdBinary.path) else {
            throw CockerError.internalError("cocker-portfwd binary not found: \(portFwdBinary.path)")
        }

        let proc = Process()
        proc.executableURL = portFwdBinary
        proc.arguments = [
            "--listen", "\(hostIP):\(hostPort)",
            "--target", "\(containerIP):\(containerPort)",
        ]
        // Pipe stderr du forwarder dans celui du daemon (logs centralisés)
        proc.standardError = FileHandle.standardError
        proc.standardOutput = FileHandle.standardError
        try proc.run()
        return proc
    }
}
