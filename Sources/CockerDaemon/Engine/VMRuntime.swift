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
    let l2Switch: L2Switch
    // Injected by ContainerEngine after DNSServer exists. Registered on each
    // VM's socket device right after the VM boots so the in-VM DNS proxy
    // can reach cockerd over vsock instead of UDP/TCP via vmnet (which the
    // App Sandbox blocks for user-signed daemons).
    var dnsVsockListener: VZVirtioSocketListener?

    init(rootDir: URL, l2Switch: L2Switch) throws {
        self.rootDir = rootDir
        self.kernelPath = rootDir.appendingPathComponent("kernel/vmlinuz")
        self.initrdPath = rootDir.appendingPathComponent("kernel/initrd.img")
        self.l2Switch = l2Switch
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

    func createVM(for container: Container, rootfsPath: URL, stdoutPipe: Pipe) async throws -> VZVirtualMachine {
        fputs("[vm] createVM enter\n", stderr); fflush(stderr)
        let config = VZVirtualMachineConfiguration()

        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelPath)
        bootLoader.initialRamdiskURL = initrdPath
        let cmdline = buildKernelCommandLine(for: container, rootfsPath: rootfsPath)
        bootLoader.commandLine = cmdline
        fputs("[vm] cmdline (\(cmdline.count) chars): \(cmdline)\n", stderr); fflush(stderr)
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

        // Serial console — branche le stdout du VM (kernel + cocker-init + container)
        // sur un Pipe qu'on lit côté hôte pour alimenter le log buffer.
        // /dev/null en lecture car la VM n'a pas besoin d'input pour l'instant.
        let nullDev = FileHandle(forReadingAtPath: "/dev/null") ?? FileHandle.standardInput
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let port0 = VZVirtioConsolePortConfiguration()
        port0.isConsole = true
        port0.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nullDev,
            fileHandleForWriting: stdoutPipe.fileHandleForWriting
        )
        consoleDevice.ports[0] = port0
        config.consoleDevices = [consoleDevice]

        // Virtio FS for rootfs — Apple's VZSharedDirectory n'aime pas certains paths
        // avec caractères spéciaux. On normalise via un symlink propre si nécessaire.
        let normalizedRootfs: URL
        if rootfsPath.path.contains(":") {
            // Crée un symlink dans tmp avec un nom propre
            let safeName = rootfsPath.lastPathComponent.replacingOccurrences(of: ":", with: "_")
            let safeLink = rootDir.appendingPathComponent("tmp/rootfs_\(safeName)")
            try? FileManager.default.removeItem(at: safeLink)
            try FileManager.default.createSymbolicLink(at: safeLink, withDestinationURL: rootfsPath)
            normalizedRootfs = safeLink
            fputs("[vm] symlinked rootfs: \(safeLink.path) -> \(rootfsPath.path)\n", stderr); fflush(stderr)
        } else {
            normalizedRootfs = rootfsPath
        }

        let sharedDir = VZSharedDirectory(url: normalizedRootfs, readOnly: false)
        let sharing = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "root")
        fsConfig.share = sharing
        fputs("[vm] virtiofs root config OK\n", stderr); fflush(stderr)
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

        // eth0 — outbound NAT to the internet (Apple-managed vmnet)
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

        var netDevices: [VZVirtioNetworkDeviceConfiguration] = []
        if container.networkMode != .none {
            netDevices.append(netDevice)
        }

        // eth1 — inter-container fabric routed through the userspace L2 switch.
        // We only add it when networking is enabled AND the container has a
        // cocker switch IP/MAC allocated (it always does for normal runs).
        if container.networkMode != .none,
           let macStr = container.cockerMAC,
           let fh = await l2Switch.addPort(containerID: container.id, staticMAC: macStr) {
            let switchDev = VZVirtioNetworkDeviceConfiguration()
            let attach = VZFileHandleNetworkDeviceAttachment(fileHandle: fh)
            attach.maximumTransmissionUnit = L2Switch.mtu
            switchDev.attachment = attach
            if let macAddr = VZMACAddress(string: macStr) {
                switchDev.macAddress = macAddr
            }
            netDevices.append(switchDev)
            fputs("[vm] eth1 attached to L2 switch (mac=\(macStr))\n", stderr); fflush(stderr)
        }

        if !netDevices.isEmpty {
            config.networkDevices = netDevices
        }

        // Socket device (vsock for exec, health checks)
        let socketDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [socketDevice]

        do {
            try config.validate()
            fputs("[vm] config.validate() OK\n", stderr); fflush(stderr)
        } catch {
            fputs("[vm] config.validate() FAILED: \(error)\n", stderr); fflush(stderr)
            throw error
        }
        let vm = VZVirtualMachine(configuration: config)
        fputs("[vm] VZVirtualMachine instance created\n", stderr); fflush(stderr)
        return vm
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
            "cocker.dns_vsock_port=5353",
        ]

        if let hostname = container.hostname.isEmpty ? nil : container.hostname {
            parts.append("cocker.hostname=\(hostname)")
        }

        // L2 switch (eth1) — inter-container fabric. cocker-init brings up
        // eth1 statically with this IP. Gateway is virtual (no host answers
        // ARP for it) but Linux needs one to consider the subnet usable.
        if let cIP = container.cockerIP, let cMAC = container.cockerMAC {
            parts.append("cocker.cnet_ip=\(cIP)/16")
            parts.append("cocker.cnet_gw=\(NetworkManager.cockerSwitchGateway)")
            parts.append("cocker.cnet_mac=\(cMAC)")
        }

        // La commande container et les env vars sont écrites dans /cocker-spec
        // au lieu de la kernel cmdline (qui ne supporte pas les espaces / quotes
        // dans les valeurs). Voir writeContainerSpec().

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

    /// Lance une VM éphémère pour exécuter une commande (RUN dans Dockerfile),
    /// attend la fin du process container (PID 1 reboot via cocker-init fork+wait),
    /// puis retourne. Le rootfs est modifié en place (virtiofs rw).
    ///
    /// Pour le build seulement — pas tracké dans runningVMs.
    func runEphemeral(
        rootfsPath: URL,
        command: [String],
        env: [String: String],
        workdir: String?,
        timeout: TimeInterval = 600
    ) async throws -> Int32 {
        fputs("[vm-build] runEphemeral cmd=\(command.joined(separator: " ")) rootfs=\(rootfsPath.path)\n", stderr)
        fflush(stderr)
        try ensureKernelAvailable()

        // Build un Container synthétique pour réutiliser la même config
        let ephID = "build-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        var container = Container(
            id: ephID,
            name: ephID,
            image: "build-context",
            command: command,
            ports: [],
            volumes: [],
            env: env,
            labels: ["com.cocker.build": "true"],
            networkMode: .nat,
            cpuCount: 2,
            memoryMB: 1024,
            hostname: ephID
        )
        if let w = workdir { container.env["WORKDIR"] = w }

        // Écrit /cocker-spec + /etc/resolv.conf dans le rootfs partagé
        try writeResolvConf(to: rootfsPath, container: container)
        try writeContainerSpec(to: rootfsPath, container: container)

        // Crée et démarre la VM
        let pipe = Pipe()
        let vm = try await createVM(for: container, rootfsPath: rootfsPath, stdoutPipe: pipe)

        // Capture la sortie via une closure (qui doit être appelée sans capture
        // d'actor pour pouvoir l'invoquer depuis le readability handler).
        let outputBuffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outputBuffer.append(chunk)
        }

        // Boot la VM
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: CockerError.vmStartFailed(error.localizedDescription))
                }
            }
        }
        fputs("[vm-build] VM booted\n", stderr); fflush(stderr)

        // Attendre que la VM s'arrête d'elle-même (cocker-init reboot après le
        // child exit) — poll vm.state avec timeout.
        let deadline = Date().addingTimeInterval(timeout)
        while vm.state != .stopped && vm.state != .error && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        if vm.state == .running {
            fputs("[vm-build] timeout after \(timeout)s — force stopping\n", stderr); fflush(stderr)
            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vm.stop { _ in continuation.resume() }
            }
        }

        pipe.fileHandleForReading.readabilityHandler = nil

        // Parse l'exit code dans la sortie de cocker-init :
        //   "[cocker-init] container exited with code N"
        let output = outputBuffer.text()
        let exitCode = parseExitCode(from: output) ?? 0
        fputs("[vm-build] VM stopped, exitCode=\(exitCode)\n", stderr); fflush(stderr)

        // Cleanup spec/resolv files for next iteration
        try? FileManager.default.removeItem(at: rootfsPath.appendingPathComponent("cocker-spec"))

        return exitCode
    }

    private func parseExitCode(from log: String) -> Int32? {
        // Cherche "exited with code N"
        guard let range = log.range(of: "exited with code ") else { return nil }
        let after = log[range.upperBound...]
        let codeStr = after.prefix { $0.isNumber }
        return Int32(codeStr)
    }

    func start(container: Container, rootfsPath: URL) async throws {
        fputs("[vm] start: container=\(container.id) rootfs=\(rootfsPath.path)\n", stderr)
        fflush(stderr)
        try ensureKernelAvailable()
        fputs("[vm] kernel OK\n", stderr); fflush(stderr)

        // Écrit resolv.conf dans le rootfs pour que le container utilise le DNS interne
        try writeResolvConf(to: rootfsPath, container: container)
        fputs("[vm] resolv.conf OK\n", stderr); fflush(stderr)

        // Écrit la spec container (cmd, env, workdir) dans /cocker-spec
        // car la kernel cmdline ne supporte pas les espaces/quotes
        try writeContainerSpec(to: rootfsPath, container: container)
        fputs("[vm] cocker-spec OK\n", stderr); fflush(stderr)

        // Pipes pour capturer console (stdout) du VM
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()  // réservé pour usage futur

        let vm = try await createVM(for: container, rootfsPath: rootfsPath, stdoutPipe: stdoutPipe)
        fputs("[vm] createVM OK\n", stderr); fflush(stderr)

        let runningVM = RunningVM(
            vm: vm,
            containerID: container.id,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        runningVMs[container.id] = runningVM

        // Démarre la lecture asynchrone du pipe console → log buffer
        startConsoleReader(containerID: container.id, pipe: stdoutPipe)

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

        // Register the DNS vsock listener on this VM's socket device. Done
        // after start so vm.socketDevices is populated. Same listener
        // instance is shared across all VMs.
        if let listener = dnsVsockListener,
           let socketDev = vm.socketDevices.first as? VZVirtioSocketDevice {
            socketDev.setSocketListener(listener, forPort: 5353)
            fputs("[vm] DNS vsock listener attached on port 5353\n", stderr); fflush(stderr)
        }
    }

    // Lit en continu la console série du VM (kernel + cocker-init + container)
    // et alimente le ring buffer logBuffer du RunningVM. Le handler tourne sur
    // une queue dédiée fournie par FileHandle.
    private func startConsoleReader(containerID: String, pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            // Le handler est appelé hors main actor — on relaie via Task @MainActor
            let id = containerID
            Task { @MainActor [weak self] in
                self?.appendLog(containerID: id, event: StreamEvent(stream: .stdout, data: text))
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
        await l2Switch.removePort(containerID: containerID)
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

    // Écrit /cocker-spec dans le rootfs. Format: NUL-séparé (comme /proc/PID/cmdline).
    // cocker-init lit ce fichier au lieu de parser la kernel cmdline pour la commande,
    // ce qui évite tous les problèmes de quoting/spaces.
    //
    // Structure:
    //   Section ARGV : args du child terminé par "\n\0\n\0" (marqueur fin)
    //   Section ENV  : KEY=VALUE\0 par variable, terminé par "\n\0" final
    //   Section WORKDIR : workdir\0
    //
    // Représentation simple : 3 lignes, chaque champ NUL-séparé :
    //   <argv0>\0<argv1>\0...\n
    //   <env0>\0<env1>\0...\n
    //   <workdir>\n
    private func writeContainerSpec(to rootfsPath: URL, container: Container) throws {
        let specPath = rootfsPath.appendingPathComponent("cocker-spec")

        var data = Data()

        // Ligne 1 : argv (NUL séparé)
        for (i, arg) in container.command.enumerated() {
            if i > 0 { data.append(0) }
            data.append(arg.data(using: .utf8) ?? Data())
        }
        data.append(0x0A)  // \n

        // Ligne 2 : env (KEY=VALUE NUL séparé)
        var envEntries: [String] = []
        // Default PATH/HOME/TERM si absents
        if container.env["PATH"] == nil {
            envEntries.append("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        }
        if container.env["HOME"] == nil {
            envEntries.append("HOME=/root")
        }
        if container.env["TERM"] == nil {
            envEntries.append("TERM=xterm")
        }
        for (k, v) in container.env {
            envEntries.append("\(k)=\(v)")
        }
        for (i, entry) in envEntries.enumerated() {
            if i > 0 { data.append(0) }
            data.append(entry.data(using: .utf8) ?? Data())
        }
        data.append(0x0A)  // \n

        // Ligne 3 : workdir
        let workdir = container.env["WORKDIR"] ?? "/"
        data.append(workdir.data(using: .utf8) ?? Data())
        data.append(0x0A)  // \n

        try data.write(to: specPath, options: .atomic)
    }

    private func writeResolvConf(to rootfsPath: URL, container: Container) throws {
        let etcDir = rootfsPath.appendingPathComponent("etc")
        try? FileManager.default.createDirectory(at: etcDir, withIntermediateDirectories: true)

        let hostIP = DNSServer.hostIP()
        let dnsPort = DNSServer.defaultPort

        // Port 53 standard → on utilise socat/iptables dans init si dnsPort != 53
        // Pour l'instant on écrit l'IP host + un search domain
        let resolvConf = """
        # Generated by cockerd
        nameserver \(hostIP)
        nameserver ::1
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

/// Buffer thread-safe pour accumuler la sortie d'une VM ephémère.
/// Le readabilityHandler de Pipe tourne sur une queue dédiée non-actor.
final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
