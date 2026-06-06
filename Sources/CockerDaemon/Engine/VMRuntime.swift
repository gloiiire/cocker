import Foundation
import Virtualization
import CockerCore

// Apple Virtualization.framework runtime
// Each container = one lightweight Linux VM booted via VZLinuxBootLoader
// Rootfs shared via virtiofs (VZVirtioFileSystemDeviceConfiguration)
// Communication via VZVirtioSocketDevice (vsock port 9000)

@MainActor
final class VMRuntime: NSObject {
    struct RunningVM {
        let vm: VZVirtualMachine
        let containerID: String
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        var logBuffer: [StreamEvent] = []
        let logBufferLock = NSLock()
    }

    private var runningVMs: [String: RunningVM] = [:]
    private let kernelPath: URL
    private let initrdPath: URL
    private let rootDir: URL

    init(rootDir: URL) throws {
        self.rootDir = rootDir
        self.kernelPath = rootDir.appendingPathComponent("kernel/vmlinuz")
        self.initrdPath = rootDir.appendingPathComponent("kernel/initrd.img")
        super.init()
    }

    // MARK: - Setup check

    func ensureKernelAvailable() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: kernelPath.path) {
            throw CockerError.kernelNotFound(kernelPath.path)
        }
        if !fm.fileExists(atPath: initrdPath.path) {
            throw CockerError.initrdNotFound(initrdPath.path)
        }
    }

    func isSetup() -> Bool {
        FileManager.default.fileExists(atPath: kernelPath.path) &&
        FileManager.default.fileExists(atPath: initrdPath.path)
    }

    // MARK: - VM creation

    func createVM(for container: Container, rootfsPath: URL) throws -> VZVirtualMachine {
        let config = VZVirtualMachineConfiguration()

        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelPath)
        bootLoader.initialRamdiskURL = initrdPath
        bootLoader.commandLine = buildKernelCommandLine(for: container, rootfsPath: rootfsPath)
        config.bootLoader = bootLoader

        // CPU & Memory
        config.cpuCount = max(1, min(container.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        config.memorySize = container.memoryMB * 1024 * 1024

        // Validate memory constraints
        config.memorySize = max(config.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        config.memorySize = min(config.memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // Entropy (needed for Linux boot)
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon (allows host to reclaim memory)
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Serial console — capture stdout/stderr from the VM
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let port0 = VZVirtioConsolePortConfiguration()
        port0.isConsole = true
        consoleDevice.ports[0] = port0
        config.consoleDevices = [consoleDevice]

        // Virtio FS for rootfs (container image layers)
        let sharedDir = VZSharedDirectory(url: rootfsPath, readOnly: false)
        let sharing = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "root")
        fsConfig.share = sharing
        var fsDevices: [VZVirtioFileSystemDeviceConfiguration] = [fsConfig]

        // Additional volume mounts via virtiofs
        for (i, mount) in container.volumes.enumerated() {
            let hostURL: URL
            if mount.source.hasPrefix("/") {
                hostURL = URL(fileURLWithPath: mount.source)
            } else {
                // Named volume
                hostURL = rootDir.appendingPathComponent("volumes/\(mount.source)/_data")
            }
            try FileManager.default.createDirectory(at: hostURL, withIntermediateDirectories: true)
            let volShare = VZSingleDirectoryShare(directory: VZSharedDirectory(url: hostURL, readOnly: mount.readOnly))
            let volFS = VZVirtioFileSystemDeviceConfiguration(tag: "vol\(i)")
            volFS.share = volShare
            fsDevices.append(volFS)
        }

        config.directorySharingDevices = fsDevices

        // Network
        let netDevice = VZVirtioNetworkDeviceConfiguration()
        switch container.networkMode {
        case .nat, .host:
            netDevice.attachment = VZNATNetworkDeviceAttachment()
        case .none:
            break  // No network device
        case .bridged:
            if let iface = VZBridgedNetworkInterface.networkInterfaces.first {
                netDevice.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
            } else {
                netDevice.attachment = VZNATNetworkDeviceAttachment()
            }
        }

        if container.networkMode != .none {
            config.networkDevices = [netDevice]
        }

        // Socket device (vsock for exec, health checks)
        let socketDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [socketDevice]

        try config.validate()
        return VZVirtualMachine(configuration: config)
    }

    // MARK: - Kernel command line

    private func buildKernelCommandLine(for container: Container, rootfsPath: URL) -> String {
        // Injecte l'IP du DNS interne de cockerd dans chaque VM
        let dnsIP = DNSServer.hostIP()
        let dnsPort = DNSServer.defaultPort

        var parts = [
            "console=hvc0",
            "root=virtiofs",
            "rootfstype=virtiofs",
            "rw",
            "quiet",
            "cocker.id=\(container.id)",
            "cocker.name=\(container.name)",
            "cocker.dns=\(dnsIP)",
            "cocker.dns_port=\(dnsPort)",
        ]

        if let hostname = container.hostname.isEmpty ? nil : container.hostname {
            parts.append("cocker.hostname=\(hostname)")
        }

        if !container.command.isEmpty {
            let cmd = container.command.joined(separator: " ")
            parts.append("cocker.cmd=\(cmd)")
        }

        // Environment variables
        for (key, value) in container.env {
            parts.append("cocker.env.\(key)=\(value)")
        }

        // Port forward info (handled by host-side vmnet, but pass info to init)
        for port in container.ports {
            parts.append("cocker.port.\(port.containerPort)=\(port.hostPort)/\(port.proto.rawValue)")
        }

        // Volume mounts
        for (i, mount) in container.volumes.enumerated() {
            parts.append("cocker.vol\(i)=vol\(i):\(mount.destination)")
        }

        if let workdir = container.config_workdir {
            parts.append("cocker.workdir=\(workdir)")
        }

        if let user = container.config_user {
            parts.append("cocker.user=\(user)")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Start/Stop

    func start(container: Container, rootfsPath: URL) async throws {
        try ensureKernelAvailable()

        // Écrit resolv.conf dans le rootfs pour que le container utilise le DNS interne
        try writeResolvConf(to: rootfsPath, container: container)

        let vm = try createVM(for: container, rootfsPath: rootfsPath)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let runningVM = RunningVM(
            vm: vm,
            containerID: container.id,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        runningVMs[container.id] = runningVM

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: CockerError.vmStartFailed(error.localizedDescription))
                }
            }
        }
    }

    func stop(containerID: String, timeout: TimeInterval = 10) async throws {
        guard let running = runningVMs[containerID] else {
            throw CockerError.containerNotRunning(containerID)
        }

        // Try graceful shutdown first
        if running.vm.canRequestStop {
            try running.vm.requestStop()
            // Give it timeout to stop
            let deadline = Date().addingTimeInterval(timeout)
            while running.vm.state != .stopped && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // Force stop if still running
        if running.vm.state == .running {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                running.vm.stop { error in
                    if let error {
                        continuation.resume(throwing: CockerError.vmStopFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        runningVMs.removeValue(forKey: containerID)
    }

    func pause(containerID: String) async throws {
        guard let running = runningVMs[containerID] else {
            throw CockerError.containerNotRunning(containerID)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            running.vm.pause { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: CockerError.vmStopFailed(error.localizedDescription))
                }
            }
        }
    }

    func resume(containerID: String) async throws {
        guard let running = runningVMs[containerID] else {
            throw CockerError.containerNotRunning(containerID)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            running.vm.resume { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: CockerError.vmStopFailed(error.localizedDescription))
                }
            }
        }
    }

    func isRunning(containerID: String) -> Bool {
        runningVMs[containerID]?.vm.state == .running
    }

    func state(containerID: String) -> VZVirtualMachine.State? {
        runningVMs[containerID]?.vm.state
    }

    // MARK: - DNS resolv.conf injection

    private func writeResolvConf(to rootfsPath: URL, container: Container) throws {
        let etcDir = rootfsPath.appendingPathComponent("etc")
        try? FileManager.default.createDirectory(at: etcDir, withIntermediateDirectories: true)

        let hostIP = DNSServer.hostIP()
        let dnsPort = DNSServer.defaultPort

        // Port 53 standard → on utilise socat/iptables dans init si dnsPort != 53
        // Pour l'instant on écrit l'IP host + un search domain
        let resolvConf = """
        # Generated by cockerd — internal DNS
        nameserver \(hostIP)
        search cocker
        options ndots:1
        options timeout:1
        options attempts:2

        """

        // Fichier resolv.conf dans le rootfs
        let resolvPath = etcDir.appendingPathComponent("resolv.conf")
        try resolvConf.write(to: resolvPath, atomically: true, encoding: .utf8)

        // Aussi hosts pour les entrées statiques connues
        let hostsPath = etcDir.appendingPathComponent("hosts")
        var hosts = """
        127.0.0.1   localhost
        ::1         localhost

        """
        // Ajoute l'IP du container lui-même
        if let ip = container.ip {
            hosts += "\(ip)   \(container.name) \(container.hostname)\n"
        }

        // N'écrase pas un hosts existant qui a du contenu important
        if !FileManager.default.fileExists(atPath: hostsPath.path) {
            try hosts.write(to: hostsPath, atomically: true, encoding: .utf8)
        }

        print("[dns] resolv.conf → \(resolvPath.path) (nameserver \(hostIP):\(dnsPort))")
    }

    // MARK: - Logs

    func logs(containerID: String, tail: Int) -> [StreamEvent] {
        guard let running = runningVMs[containerID] else { return [] }
        running.logBufferLock.lock()
        defer { running.logBufferLock.unlock() }
        let all = running.logBuffer
        if tail <= 0 { return all }
        return Array(all.suffix(tail))
    }

    func appendLog(containerID: String, event: StreamEvent) {
        guard var running = runningVMs[containerID] else { return }
        running.logBufferLock.lock()
        defer { running.logBufferLock.unlock() }
        running.logBuffer.append(event)
        // Cap buffer at 10k lines
        if running.logBuffer.count > 10000 {
            running.logBuffer.removeFirst(running.logBuffer.count - 10000)
        }
        runningVMs[containerID] = running
    }

    // MARK: - Exec via vsock

    func exec(containerID: String, command: [String], env: [String: String]) async throws -> AsyncStream<StreamEvent> {
        guard let running = runningVMs[containerID] else {
            throw CockerError.containerNotRunning(containerID)
        }

        // Connect to vsock port 9000 (cocker-init exec listener)
        guard let socketDevice = running.vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw CockerError.vmCommunicationFailed("No vsock device")
        }

        return AsyncStream { continuation in
            socketDevice.connect(toPort: 9000) { result in
                switch result {
                case .failure(let error):
                    continuation.yield(StreamEvent(stream: .error, data: "exec failed: \(error)"))
                    continuation.finish()
                case .success(let connection):
                    // Use the file descriptor directly for vsock communication
                    struct ExecReq: Codable { let cmd: [String]; let env: [String: String] }
                    let req = ExecReq(cmd: command, env: env)
                    if let data = try? JSONEncoder().encode(req) {
                        let fd = connection.fileDescriptor
                        // Write request + newline
                        data.withUnsafeBytes { buf in _ = Darwin.write(fd, buf.baseAddress!, buf.count) }
                        var nl: UInt8 = 0x0A
                        Darwin.write(fd, &nl, 1)

                        // Read output line by line
                        Task.detached {
                            var buffer = Data()
                            var chunk = [UInt8](repeating: 0, count: 4096)
                            while true {
                                let n = Darwin.read(fd, &chunk, chunk.count)
                                if n <= 0 { continuation.finish(); break }
                                buffer.append(contentsOf: chunk.prefix(n))
                                while let nlIdx = buffer.firstIndex(of: 0x0A) {
                                    let line = Data(buffer[..<nlIdx])
                                    buffer = Data(buffer[buffer.index(after: nlIdx)...])
                                    if let text = String(data: line, encoding: .utf8) {
                                        continuation.yield(StreamEvent(stream: .stdout, data: text + "\n"))
                                    }
                                }
                            }
                        }
                    } else {
                        continuation.yield(StreamEvent(stream: .error, data: "Failed to encode exec request"))
                        continuation.finish()
                    }
                }
            }
        }
    }
}

// Extensions to access Container config fields (optional stored in env)
private extension Container {
    var config_workdir: String? { env["WORKDIR"] }
    var config_user: String? { env["USER"] }
}
