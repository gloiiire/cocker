import Foundation
import CockerCore

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
        var procs: [Process] = []
        for port in mappings {
            guard port.proto == .tcp else {
                fputs("[portfwd] skip \(port.hostPort)/\(port.proto.rawValue) (TCP only)\n", stderr)
                fflush(stderr)
                continue
            }
            do {
                let proc = try spawnForwarder(
                    hostPort: port.hostPort,
                    containerIP: containerIP,
                    containerPort: port.containerPort
                )
                procs.append(proc)
                fputs("[portfwd] 0.0.0.0:\(port.hostPort) → \(containerIP):\(port.containerPort) " +
                      "(pid \(proc.processIdentifier), container \(String(containerID.prefix(12))))\n", stderr)
                fflush(stderr)
            } catch {
                fputs("[portfwd] error spawning forwarder for \(port.hostPort): \(error)\n", stderr)
                fflush(stderr)
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
        }
        processes.removeValue(forKey: containerID)
        fputs("[portfwd] stopped all forwarders for container \(String(containerID.prefix(12)))\n", stderr)
        fflush(stderr)
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

    // MARK: - Spawn helper

    private func spawnForwarder(
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
            "--listen", "0.0.0.0:\(hostPort)",
            "--target", "\(containerIP):\(containerPort)",
        ]
        // Pipe stderr du forwarder dans celui du daemon (logs centralisés)
        proc.standardError = FileHandle.standardError
        proc.standardOutput = FileHandle.standardError
        try proc.run()
        return proc
    }
}
