import Foundation
@preconcurrency import Virtualization
import CockerCore

/// Write all `count` bytes at `base` to `fd`, looping over short writes and
/// retrying on EINTR. Returns false on a real write error. A bare
/// `Darwin.write` may accept only part of the buffer (or be interrupted by a
/// signal), so callers that must deliver a complete framed message — like the
/// NL-terminated exec request over vsock — need this instead of a single call.
fileprivate func writeAllFD(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int) -> Bool {
    var off = 0
    while off < count {
        let w = Darwin.write(fd, base.advanced(by: off), count - off)
        if w < 0 {
            if errno == EINTR { continue }
            return false
        }
        if w == 0 { return false }
        off += w
    }
    return true
}

// Apple Virtualization.framework runtime
// Each container = one lightweight Linux VM booted via VZLinuxBootLoader
// Rootfs shared via virtiofs (VZVirtioFileSystemDeviceConfiguration)
// Communication via VZVirtioSocketDevice (vsock port 9000)

@MainActor
final class VMRuntime: NSObject {

    /// Docker-compatible volume seeding : when a fresh managed volume
    /// is about to mount on `destination`, populate it with whatever
    /// the image baked at that path. Mirrors docker's "anonymous volume
    /// initialization" behaviour so node stacks (`/app/node_modules`),
    /// Python virtualenvs (`/app/.venv`), Ruby gems, etc. don't vanish
    /// when the user adds a bind mount on the parent dir.
    ///
    /// Safe to call unconditionally : it no-ops when `volumeDir` is
    /// already populated, or when the image has nothing at
    /// `destination`. The check is cheap (one `contentsOfDirectory`).
    static func seedFromImageIfFresh(
        volumeDir: URL,
        imageRootfs: URL,
        destination: String
    ) {
        // Already populated → never overwrite. Docker semantics : the
        // seeding only happens on FIRST mount.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: volumeDir.path)) ?? []
        if !existing.isEmpty { return }

        // S5 fix : the `destination` string comes from the OCI image config.
        // A malicious image can declare a volume on `/../../../host_secret`
        // and (without this guard) we'd happily `cp -Rp imageRootfs/host_secret`
        // into the volume — which then becomes mountable by other containers.
        // PathConfinement.confine refuses any `..` that escapes imageRootfs.
        let imageContentPath: URL
        do {
            imageContentPath = try PathConfinement.confine(destination, to: imageRootfs)
        } catch {
            CockerLog.shared.debug("vm", "refuse to seed volume from path that escapes image rootfs: \(destination)")
            return
        }
        var srcIsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: imageContentPath.path, isDirectory: &srcIsDir),
              srcIsDir.boolValue else { return }

        // `cp -Rp src/. dst` copies the CONTENTS into dst rather than
        // nesting src under dst. Use a subprocess so symlinks / mode
        // bits / mtimes survive correctly — Foundation's copy APIs
        // mangle some of these on macOS. A pathological image with
        // gigabytes baked under `destination` could otherwise stall
        // container boot indefinitely ; we cap the wait at 60 s and
        // log a warning so the user can spot the problem.
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-Rp", imageContentPath.path + "/.", volumeDir.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        cp.standardOutput = outPipe
        cp.standardError = errPipe
        do {
            try cp.run()
        } catch {
            CockerLog.shared.error("vm", "cp failed to launch for volume seeding: \(error)")
            return
        }
        // Daemon-side budget : 60 s is generous for a typical
        // node_modules / venv ; anything past that and we abandon
        // (the half-seeded volume will still be writable from the
        // container, just not pre-populated).
        let deadline = Date().addingTimeInterval(60)
        while cp.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if cp.isRunning {
            cp.terminate()
            cp.waitUntilExit()
            CockerLog.shared.warn("vm", "volume seed from \(destination) exceeded 60 s — abandoned")
            return
        }
        cp.waitUntilExit()
        if cp.terminationStatus != 0 {
            let errOut = errPipe.fileHandleForReading.availableData
            let msg = String(data: errOut, encoding: .utf8) ?? ""
            CockerLog.shared.warn("vm", "cp -Rp for \(destination) exited \(cp.terminationStatus): \(msg.prefix(200))")
        }
    }

    /// **A8 fix** : RunningVM used to be a `struct` stored by value in
    /// `runningVMs: [String: RunningVM]`. Mutating `logBuffer` then required
    /// the copy-mutate-write-back dance everywhere
    /// (`var running = runningVMs[id]; running.logBuffer.append(...);
    /// runningVMs[id] = running`) and relied on `NSLock` (a class) being
    /// shared by reference across copies for thread-safety. That worked
    /// "by accident" : every mutation site already lives on `@MainActor`
    /// so concurrency was never really a worry, and the lock was vestigial.
    /// Promoting to a final class kills the write-back step, lets us drop
    /// the lock, and produces straightforward in-place mutation.
    final class RunningVM {
        let vm: VZVirtualMachine
        let containerID: String
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        var logBuffer: [StreamEvent] = []
        /// Subscribers to live console output. `appendLog` yields directly
        /// to them, so `cocker logs -f` no longer wakes MainActor every
        /// 100 ms to compare array lengths. UUID ownership makes removal
        /// deterministic when a consumer cancels.
        var logContinuations: [UUID: AsyncStream<StreamEvent>.Continuation] = [:]
        /// Where the virtiofs root is mounted from on the host. Carried
        /// here so `stop()` can read `/cocker-exit-code` from the
        /// container's rootfs after the VM is gone — the console-pipe
        /// path drops the "exited with code N" line if the kernel
        /// powers off before stdio drains.
        let rootfsPath: URL?

        init(vm: VZVirtualMachine, containerID: String,
             stdoutPipe: Pipe, stderrPipe: Pipe, rootfsPath: URL?) {
            self.vm = vm
            self.containerID = containerID
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.rootfsPath = rootfsPath
        }
    }

    private var runningVMs: [String: RunningVM] = [:]
    /// MAC the VZ framework auto-assigned to each VM's eth0 NIC. ContainerEngine
    /// drains this map after `start()` returns so it can persist the value
    /// and use it for /var/db/dhcpd_leases lookup if /cocker-ip polling times
    /// out. Cleared on container stop / remove.
    fileprivate var pendingNATMACs: [String: String] = [:]

    /// Pop and return the auto-assigned eth0 MAC for `containerID` after a
    /// successful start. Returns nil if createVM never recorded one (e.g.
    /// network mode .none).
    func takeNATMAC(forContainer containerID: String) -> String? {
        guard let m = pendingNATMACs.removeValue(forKey: containerID),
              !m.isEmpty else { return nil }
        return m
    }
    private let kernelPath: URL
    private let initrdPath: URL
    private let rootDir: URL
    let l2Switch: any L2Switching
    // Injected by ContainerEngine after DNSServer exists. Registered on each
    // VM's socket device right after the VM boots so the in-VM DNS proxy
    // can reach cockerd over vsock instead of UDP/TCP via vmnet (which the
    // App Sandbox blocks for user-signed daemons).
    var dnsVsockListener: VZVirtioSocketListener?

    init(rootDir: URL, l2Switch: any L2Switching) throws {
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

    /// Identity of this runtime for the build cache.
    ///
    /// A `RUN` layer is only replayable under the runtime that captured
    /// it : `cocker-init` decides what the guest filesystem looks like
    /// (0.7.13.13 mounted a tmpfs over `/run` and swallowed writes there,
    /// 0.7.13.14 does not). Folding the initrd and kernel digests in means
    /// `brew upgrade` invalidates exactly the affected steps by itself,
    /// with no `--no-cache` to remember.
    func buildFingerprint() -> String {
        BuildRuntimeFingerprint.forRuntime(
            kernel: kernelPath,
            initrd: initrdPath,
            legacyBuildPath: ProcessInfo.processInfo.environment["COCKER_BUILD_LEGACY"] != nil
        )
    }

    // MARK: - VM creation

    func createVM(for container: Container, rootfsPath: URL, stdoutPipe: Pipe) async throws -> VZVirtualMachine {
        CockerLog.shared.debug("vm", "createVM enter")
        let config = VZVirtualMachineConfiguration()

        // Boot loader — cmdline gets assigned AFTER volume processing
        // below so it can include the block-device paths for each volume
        // (resolved dynamically based on whether the source is a .img file
        // or a directory).
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelPath)
        bootLoader.initialRamdiskURL = initrdPath
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
            CockerLog.shared.debug("vm", "symlinked rootfs: \(safeLink.path) -> \(rootfsPath.path)")
        } else {
            normalizedRootfs = rootfsPath
        }

        // Build-overlay (PRO-73) : the "root" share is the overlay LOWER
        // (base image), mounted read-only in the guest ; all writes go to
        // the ext4 upper attached below. Normal runs keep it read-write.
        let rootReadOnly = container.labels["com.cocker.build-overlay-dev"] != nil
        let sharedDir = VZSharedDirectory(url: normalizedRootfs, readOnly: rootReadOnly)
        let sharing = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "root")
        fsConfig.share = sharing
        CockerLog.shared.debug("vm", "virtiofs root config OK")
        var fsDevices: [VZVirtioFileSystemDeviceConfiguration] = [fsConfig]

        // Additional volume mounts. Two backends :
        //   1. Block storage (.img file) — attached as VZVirtioBlockDevice.
        //      Used for named volumes that need real Linux fs semantics
        //      (chown/chmod inside the guest). Default for new volumes
        //      created by VolumeManager since 0.5.13.
        //   2. Virtiofs (directory) — attached as VZVirtioFileSystem.
        //      Used for bind mounts (`/host/path:/container/path`) and
        //      legacy directory-based named volumes.
        //
        // For each volume we emit a cmdline spec (collected in
        // `volumeSpecs`) that tells cocker-init what kind of attachment
        // to mount where. Block devices land at /dev/vd[a-z] in PCI
        // attachment order ; we track the index so the cmdline gets the
        // right path.
        var storageDevices: [VZStorageDeviceConfiguration] = []
        var volumeSpecs: [String] = []
        var blockIdx = 0

        // Build-overlay (PRO-73) : the ext4 upper is attached as the FIRST
        // block device so it lands at /dev/vda (the value the cmdline's
        // `cocker.rootfs=overlay:/dev/vda` and cocker-init agree on). It
        // must precede any volume block device so the /dev/vd<letter>
        // accounting below stays correct.
        if let ext4Path = container.labels["com.cocker.build-ext4-img"] {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: ext4Path), readOnly: false)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
            blockIdx += 1 // /dev/vda consumed by the ext4 upper
        }

        for (i, mount) in container.volumes.enumerated() {
            let hostURL: URL
            if mount.source.hasPrefix("/") {
                // Bind mount — always virtiofs (no .img conversion).
                hostURL = URL(fileURLWithPath: mount.source)
            } else {
                // Named volume — managed by VolumeManager. New volumes
                // are .img files ; legacy ones are _data directories.
                hostURL = rootDir.appendingPathComponent("volumes/\(mount.source)/data.img")
                if !FileManager.default.fileExists(atPath: hostURL.path) {
                    // Fallback : legacy layout from <0.5.13.
                    let legacyDir = rootDir.appendingPathComponent("volumes/\(mount.source)/_data")
                    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
                    // Same image-content seeding as the block-storage path :
                    // a fresh anonymous volume is populated from whatever the
                    // image baked at the destination path. Without this,
                    // mounting `/app/node_modules` as an empty anon volume
                    // hides nodemon / ts-node / etc. that `npm install`
                    // baked into the image.
                    Self.seedFromImageIfFresh(
                        volumeDir: legacyDir,
                        imageRootfs: rootfsPath,
                        destination: mount.destination
                    )
                    let volShare = VZSingleDirectoryShare(directory: VZSharedDirectory(url: legacyDir, readOnly: mount.readOnly))
                    let volFS = VZVirtioFileSystemDeviceConfiguration(tag: "vol\(i)")
                    volFS.share = volShare
                    fsDevices.append(volFS)
                    volumeSpecs.append("virtiofs:vol\(i):\(mount.destination)")
                    continue
                }
            }

            // Detect block-storage (.img file) vs virtiofs (directory).
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir)
            if exists && !isDir.boolValue {
                // Block storage path. Attach as virtio block device, build
                // a cmdline spec that points cocker-init at /dev/vd<X>.
                let attachment = try VZDiskImageStorageDeviceAttachment(url: hostURL, readOnly: mount.readOnly)
                let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                storageDevices.append(blockDevice)
                // /dev/vd[a-z] follows attach order. We track our own
                // index to stay aligned even if other (non-volume) block
                // devices get added later.
                let letter = String(UnicodeScalar(0x61 + blockIdx)!) // a, b, c…
                volumeSpecs.append("blk:/dev/vd\(letter):\(mount.destination)")
                blockIdx += 1
            } else {
                // Virtiofs path (directory bind mount, or legacy named
                // volume whose data.img wasn't found above).
                try FileManager.default.createDirectory(at: hostURL, withIntermediateDirectories: true)

                if !mount.source.hasPrefix("/") {
                    Self.seedFromImageIfFresh(
                        volumeDir: hostURL,
                        imageRootfs: rootfsPath,
                        destination: mount.destination
                    )
                }

                let volShare = VZSingleDirectoryShare(directory: VZSharedDirectory(url: hostURL, readOnly: mount.readOnly))
                let volFS = VZVirtioFileSystemDeviceConfiguration(tag: "vol\(i)")
                volFS.share = volShare
                fsDevices.append(volFS)
                volumeSpecs.append("virtiofs:vol\(i):\(mount.destination)")
            }
        }
        config.storageDevices = storageDevices

        // Cross-arch builds : if the build container is labelled with
        // `com.cocker.qemu-arch`, share `~/.cocker/qemu` so the in-VM
        // qemu_register_binfmt path in cocker-init can find the binary
        // it advertises on the kernel cmdline. cocker-init mounts the
        // "qemu" virtiofs tag at /opt/cocker/qemu (see init.c).
        if container.labels["com.cocker.qemu-arch"] != nil,
           let qemuDir = Self.qemuHostDir() {
            let qemuShare = VZSingleDirectoryShare(directory: VZSharedDirectory(url: qemuDir, readOnly: true))
            let qemuFS = VZVirtioFileSystemDeviceConfiguration(tag: "qemu")
            qemuFS.share = qemuShare
            fsDevices.append(qemuFS)
        }

        // Build-overlay (PRO-73) : the "outbox" share is a host dir the
        // guest RUN wrapper writes the produced layer tarball into, which
        // the daemon then reads back as the OCI layer. cocker-init mounts
        // it at /.cocker-outbox inside the build root.
        if let outboxPath = container.labels["com.cocker.build-outbox"] {
            let outboxShare = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: URL(fileURLWithPath: outboxPath), readOnly: false))
            let outboxFS = VZVirtioFileSystemDeviceConfiguration(tag: "outbox")
            outboxFS.share = outboxShare
            fsDevices.append(outboxFS)
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
        // Let VZ pick the MAC for eth0. Surface it back to cockerd through
        // a side channel so it can match the corresponding lease in
        // /var/db/dhcpd_leases. Pinning our own MAC didn't work — vmnet's
        // bootpd silently refused to hand out leases for our 02:cc:* prefix.
        let natMACString: String = {
            guard container.networkMode != .none else { return "" }
            let s = netDevice.macAddress.string
            CockerLog.shared.debug("vm", "eth0 MAC=\(s)")
            return s
        }()
        pendingNATMACs[container.id] = natMACString

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
            CockerLog.shared.debug("vm", "eth1 attached to L2 switch (mac=\(macStr))")
        }

        if !netDevices.isEmpty {
            config.networkDevices = netDevices
        }

        // Socket device (vsock for exec, health checks)
        let socketDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [socketDevice]

        // Now that volumes have been resolved (block device indices
        // assigned, virtiofs tags emitted), build the kernel cmdline
        // with the per-volume specs and hand it to the boot loader.
        let cmdline = buildKernelCommandLine(for: container, rootfsPath: rootfsPath, volumeSpecs: volumeSpecs)
        bootLoader.commandLine = cmdline
        CockerLog.shared.debug("vm", "cmdline (\(cmdline.count) chars): \(cmdline)")

        do {
            try config.validate()
            CockerLog.shared.debug("vm", "config.validate() OK")
        } catch {
            CockerLog.shared.error("vm", "config.validate() FAILED: \(error)")
            throw error
        }
        let vm = VZVirtualMachine(configuration: config)
        CockerLog.shared.debug("vm", "VZVirtualMachine instance created")
        return vm
    }

    // MARK: - Kernel command line

    private func buildKernelCommandLine(for container: Container, rootfsPath: URL, volumeSpecs: [String]) -> String {
        // For cross-arch builds, label "com.cocker.qemu-arch" is stamped
        // on the synthetic build container so we know which qemu binary
        // to plumb. Production runs leave it empty.
        let qemuArch = container.labels["com.cocker.qemu-arch"]
        let qemuPath = qemuArch.map { _ in "/opt/cocker/qemu/qemu-\(qemuArch!)-static" }
        // Build-overlay (PRO-73) : when the synthetic build container is
        // stamped with the ext4-upper device, emit the overlay rootfs spec
        // + outbox tag so cocker-init boots the base-virtiofs/ext4-upper
        // overlay instead of a plain virtiofs root.
        let overlayDev = container.labels["com.cocker.build-overlay-dev"]
        let outboxTag = container.labels["com.cocker.build-outbox"] != nil ? "outbox" : nil
        return KernelCommandLine.build(KernelCommandLineParams(
            container: container,
            dnsIP: DNSServer.hostIP(),
            dnsPort: DNSServer.defaultPort,
            dnsVsockPort: 5353,
            cockerSwitchGateway: NetworkManager.cockerSwitchGateway,
            qemuArch: qemuArch,
            qemuPath: qemuPath,
            volumeSpecs: volumeSpecs,
            rootDevice: overlayDev,
            buildOverlay: overlayDev != nil,
            outboxTag: outboxTag
        ))
    }

    /// Resolve the host directory holding qemu-user-static binaries the
    /// daemon will mount into cross-arch VMs at `/opt/cocker/qemu/`.
    /// Returns nil when the user hasn't dropped any binaries in there.
    /// Binaries must be Linux aarch64 ELF (they run inside the build VM,
    /// not on macOS), one per target arch :
    ///   ~/.cocker/qemu/qemu-x86_64-static
    ///   ~/.cocker/qemu/qemu-riscv64-static
    static func qemuHostDir() -> URL? {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cocker/qemu")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return dir
    }

    // MARK: - Start/Stop

    /// Lance une VM éphémère pour exécuter une commande (RUN dans Dockerfile),
    /// attend la fin du process container (PID 1 reboot via cocker-init fork+wait),
    /// puis retourne. Le rootfs est modifié en place (virtiofs rw).
    ///
    /// Pour le build seulement — pas tracké dans runningVMs.
    /// Result of a build `RUN` : the exit code plus the VM console output
    /// so the caller can surface a failed step's real error at the terminal
    /// instead of the bare "exited with code N" (PRO-73 — the apt EACCES was
    /// invisible because this output only went to cockerd.log).
    struct EphemeralRunResult {
        let exitCode: Int32
        let output: String
    }

    func runEphemeral(
        rootfsPath: URL,
        command: [String],
        env: [String: String],
        workdir: String?,
        timeout: TimeInterval = 600,
        targetArch: String? = nil,
        buildOverlayOutbox: URL? = nil
    ) async throws -> EphemeralRunResult {
        CockerLog.shared.debug("vm-build", "runEphemeral cmd=\(command.joined(separator: " ")) rootfs=\(rootfsPath.path)")
        try ensureKernelAvailable()

        // Build un Container synthétique pour réutiliser la même config
        let ephID = "build-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        // Stamp the qemu arch label when cross-arch is requested so
        // createVM mounts the qemu directory + buildKernelCommandLine
        // emits the binfmt registration params. Host arch builds get
        // a nil label and the cmdline params are omitted.
        var labels: [String: String] = ["com.cocker.build": "true"]
        if let arch = targetArch?.lowercased(), arch != "arm64", arch != "aarch64" {
            // Normalise Docker-style "amd64" → kernel-style "x86_64".
            let kernelArch: String
            switch arch {
            case "amd64": kernelArch = "x86_64"
            case "arm/v7", "armhf": kernelArch = "arm"
            case "riscv64": kernelArch = "riscv64"
            default: kernelArch = arch
            }
            labels["com.cocker.qemu-arch"] = kernelArch
        }

        // Build-overlay (PRO-73) : back the RUN step's writes with a fresh
        // ext4 upper instead of writing straight through Apple virtiofs
        // (which EACCESes on dpkg's mode-000 file creates). createVM keys
        // off these labels to attach the ext4 image at /dev/vda + the
        // outbox share ; the upper is the produced layer, tarred into the
        // outbox by the caller's wrapper. The image is ephemeral — one per
        // RUN, removed on the way out.
        var ext4Upper: URL?
        if let outbox = buildOverlayOutbox {
            let img = FileManager.default.temporaryDirectory
                .appendingPathComponent("cocker-upper-\(ephID).img")
            // 16 GiB sparse : big enough for heavy `RUN`s (full toolchains,
            // node_modules), costs only the bytes actually written on APFS.
            try Ext4Image.createSparse(at: img, size: 16 * 1024 * 1024 * 1024)
            // Format host-side with brew mke2fs when available (fast, common
            // case). If e2fsprogs isn't installed, leave it unformatted —
            // cocker-init's switch_to_overlay runs mkfs.ext4 in the VM if the
            // base image bundles e2fsprogs. Only if neither is present does
            // the build fail, with a clear mount error.
            if Ext4Image.mke2fsPath() != nil {
                try Ext4Image.format(at: img)
            } else {
                CockerLog.shared.warn("vm-build",
                    "mke2fs not found on host (brew install e2fsprogs) — " +
                    "deferring ext4 format to the VM (needs mkfs.ext4 in the base image)")
            }
            ext4Upper = img
            labels["com.cocker.build-overlay-dev"] = "/dev/vda"
            labels["com.cocker.build-ext4-img"] = img.path
            labels["com.cocker.build-outbox"] = outbox.path
        }
        defer { if let u = ext4Upper { try? FileManager.default.removeItem(at: u) } }

        var container = Container(
            id: ephID,
            name: ephID,
            image: "build-context",
            command: command,
            ports: [],
            volumes: [],
            env: env,
            labels: labels,
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
        CockerLog.shared.debug("vm-build", "VM booted")

        // Same DNS vsock wiring as `start()` — without this, DNS in the
        // build VM fails and `RUN apk add …` / `RUN apt-get …` break.
        if let listener = dnsVsockListener,
           let socketDev = vm.socketDevices.first as? VZVirtioSocketDevice {
            socketDev.setSocketListener(listener, forPort: 5353)
            CockerLog.shared.debug("vm-build", "DNS vsock listener attached on port 5353")
        }

        // Attendre que la VM s'arrête d'elle-même (cocker-init reboot après le
        // child exit) — poll vm.state avec timeout.
        let deadline = Date().addingTimeInterval(timeout)
        while vm.state != .stopped && vm.state != .error && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // PRO-52: capture whether the timeout branch fires BEFORE we
        // ask VZ to stop, so the exit-code synthesis below can return
        // 124 instead of falling back to the optimistic `?? 0` that
        // made a hung RUN look like a success and silently produced
        // half-baked images.
        let timedOut = (vm.state == .running)
        if timedOut {
            CockerLog.shared.debug("vm-build", "timeout after \(timeout)s — force stopping (treating as exit 124)")
            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vm.stop { _ in continuation.resume() }
            }
        }

        // **B13 fix** : the readabilityHandler closure runs on a GCD queue
        // that's not synchronized with our actor. Detach + close both ends
        // explicitly so the next `cocker build` step doesn't race against a
        // residual append into `outputBuffer` (and so the FDs are freed
        // immediately instead of waiting for ARC + Pipe.deinit).
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()

        // Parse l'exit code dans la sortie de cocker-init :
        //   "[cocker-init] container exited with code N"
        let output = outputBuffer.text()
        // PRO-52 exit-code synthesis :
        //   - Marker present → trust it (cocker-init said the user's
        //     command exited with that code, whether the VM was killed or
        //     not).
        //   - Marker missing + we force-stopped on timeout → 124 (matches
        //     GNU `timeout`'s convention so error messages feel familiar).
        //   - Marker missing + no timeout (cocker-init crashed before
        //     printing the marker, kernel oops, etc.) → 125 so we never
        //     silently swallow that as success.
        let exitCode: Int32 = Self.synthesizeExitCode(
            parsed: parseExitCode(from: output), timedOut: timedOut
        )
        CockerLog.shared.debug("vm-build", "VM stopped, exitCode=\(exitCode)")
        if exitCode != 0 {
            // Surface the failed step's output instead of swallowing it.
            // Otherwise the user only sees "exit code 1" with no clue.
            // Build-failure output goes out at ERROR level : the user's
            // build just failed, this is not optional debug noise.
            let tail = output.suffix(4096)
            CockerLog.shared.error("vm-build", "--- captured output (last 4 KB) ---\n\(String(tail))\n[vm-build] --- end output ---")
        }

        // Cleanup spec/resolv files for next iteration
        try? FileManager.default.removeItem(at: rootfsPath.appendingPathComponent("cocker-spec"))
        // Also wipe /cocker-ip — build VMs go through DHCP and persist their
        // IP into the image rootfs. Containers launched from that image
        // would then race against their own cocker-init writing the
        // correct value, surfacing as portfwd pointing at the build VM's
        // dead IP. The defence in net.c truncates this file before each
        // boot, but cleaning here keeps built images well-formed.
        try? FileManager.default.removeItem(at: rootfsPath.appendingPathComponent("cocker-ip"))

        return EphemeralRunResult(exitCode: exitCode, output: output)
    }

    /// PRO-52 — turn (parsed marker, timedOut) into a single exit code
    /// the rest of the build pipeline can react to.
    ///
    ///   parsed != nil → trust cocker-init's marker; the user's command
    ///                   really exited with that code.
    ///   parsed == nil + timedOut → 124, matches GNU `timeout`.
    ///   parsed == nil + !timedOut → 125, "VM exited without a marker"
    ///                   (cocker-init crashed, kernel oops, etc).
    ///
    /// `static` + `nonisolated` so unit tests can hit it without spinning
    /// a real VM and without crossing the actor boundary. The body is pure.
    nonisolated static func synthesizeExitCode(parsed: Int32?, timedOut: Bool) -> Int32 {
        if let code = parsed { return code }
        return timedOut ? 124 : 125
    }

    private func parseExitCode(from log: String) -> Int32? {
        // Search backwards : a container that prints a literal "exited with
        // code 0" mid-run and crashes later with exit 1 used to surface as
        // exit 0 because we matched the first occurrence. The kernel /
        // cocker-init "exited with code N" line is the very last marker
        // written to the console buffer before VZ flips the VM state, so
        // last-wins is the correct rule for our log shape.
        guard let range = log.range(of: "exited with code ", options: .backwards)
        else { return nil }
        let after = log[range.upperBound...]
        let codeStr = after.prefix { $0.isNumber }
        return Int32(codeStr)
    }

    /// Best-effort exit code for a container that has stopped. Returns nil
    /// if cocker-init's "exited with code N" marker wasn't seen in the
    /// console buffer — caller falls back to 0. Used by watchContainer to
    /// decide whether to honour on-failure restart policy.
    func exitCode(forContainer containerID: String) -> Int32? {
        guard let running = runningVMs[containerID] else { return nil }
        // No lock — VMRuntime is @MainActor so every read/write of
        // logBuffer is already serialized. RunningVM is now a class so
        // the read sees the live buffer without a copy.
        let combined = running.logBuffer.map { $0.data }.joined()
        return parseExitCode(from: combined)
    }

    func start(container: Container, rootfsPath: URL) async throws {
        CockerLog.shared.debug("vm", "start: container=\(container.id) rootfs=\(rootfsPath.path)")
        try ensureKernelAvailable()
        CockerLog.shared.debug("vm", "kernel OK")

        // Écrit resolv.conf dans le rootfs pour que le container utilise le DNS interne
        try writeResolvConf(to: rootfsPath, container: container)
        CockerLog.shared.debug("vm", "resolv.conf OK")

        // Écrit la spec container (cmd, env, workdir) dans /cocker-spec
        // car la kernel cmdline ne supporte pas les espaces/quotes
        try writeContainerSpec(to: rootfsPath, container: container)
        CockerLog.shared.debug("vm", "cocker-spec OK")

        // Pipes pour capturer console (stdout) du VM
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()  // réservé pour usage futur

        let vm = try await createVM(for: container, rootfsPath: rootfsPath, stdoutPipe: stdoutPipe)
        CockerLog.shared.debug("vm", "createVM OK")

        let runningVM = RunningVM(
            vm: vm,
            containerID: container.id,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            rootfsPath: rootfsPath
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
                    let ns = error as NSError
                    CockerLog.shared.error("vm", "start FAILED domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
                    CockerLog.shared.debug("vm", "userInfo=\(ns.userInfo)")
                    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                        CockerLog.shared.debug("vm", "underlying: domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)")
                        CockerLog.shared.debug("vm", "underlying userInfo=\(underlying.userInfo)")
                    }
                    continuation.resume(throwing: CockerError.vmStartFailed("\(ns.localizedDescription) [code=\(ns.code)]"))
                }
            }
        }

        // Register the DNS vsock listener on this VM's socket device. Done
        // after start so vm.socketDevices is populated. Same listener
        // instance is shared across all VMs.
        if let listener = dnsVsockListener,
           let socketDev = vm.socketDevices.first as? VZVirtioSocketDevice {
            socketDev.setSocketListener(listener, forPort: 5353)
            CockerLog.shared.debug("vm", "DNS vsock listener attached on port 5353")
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

    /// Returns the container's exit code (parsed from cocker-init's
    /// console log) when the VM stopped gracefully — `nil` if we had to
    /// force-stop and the init line never landed. ContainerEngine writes
    /// this to `state.exitCode` instead of the hardcoded 0 the prior
    /// path used, so `cocker inspect` and the Docker API's
    /// `State.ExitCode` reflect what really happened (137 on SIGKILL,
    /// `exit N` from a STOPSIGNAL trap, etc.).
    @discardableResult
    func stop(containerID: String, timeout: TimeInterval = 10,
              stopSignal: String? = nil) async throws -> Int32? {
        guard let running = runningVMs[containerID] else {
            throw CockerError.containerNotRunning(containerID)
        }

        // Phase 1 — In-VM signal relay via vsock. VZ's `requestStop()`
        // sends an ACPI shutdown which the Linux kernel doesn't reliably
        // turn into a SIGTERM at PID 1 (no systemd to broker it). For
        // STOPSIGNAL semantics (nginx wants SIGQUIT, etc.) we hand the
        // signal to the exec_listener over vsock — it reads /cocker-child.pid
        // that init wrote and delivers the signal directly to the
        // container's main process.
        let signalName = stopSignal ?? "SIGTERM"
        await sendStopSignal(vm: running.vm, containerID: containerID, signal: signalName)

        // Phase 2 — Poll for the child to exit. The signal handler in the
        // container does its graceful shutdown ; PID 1 reaps it and
        // reboots the VM. VZ surfaces this as state == .stopped.
        let deadline = Date().addingTimeInterval(timeout)
        while running.vm.state != .stopped && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Phase 3 — Fallback to ACPI shutdown if still running. Container
        // ignored the signal (or had no handler installed) — request
        // graceful via VZ, then force-stop after the timeout.
        if running.vm.state == .running && running.vm.canRequestStop {
            try running.vm.requestStop()
            let acpiDeadline = Date().addingTimeInterval(timeout)
            while running.vm.state != .stopped && Date() < acpiDeadline {
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

        // Exit code resolution. cocker-init writes its decimal exit
        // code to `/cocker-exit-code` on the shared rootfs right before
        // reboot — reading that file is the source of truth here. We
        // fall back to parseExitCode on the console buffer for
        // backwards compatibility with older cocker-init builds that
        // don't write the file yet.
        let rootfs = running.rootfsPath
        var detectedExit: Int32? = nil
        if let rootfs {
            let ecPath = rootfs.appendingPathComponent("cocker-exit-code")
            if let s = try? String(contentsOf: ecPath, encoding: .utf8),
               let n = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                detectedExit = n
            }
        }
        if detectedExit == nil {
            detectedExit = parseExitCode(from: running.logBuffer.map { $0.data }.joined())
        }
        for continuation in running.logContinuations.values {
            continuation.finish()
        }
        running.logContinuations.removeAll()
        runningVMs.removeValue(forKey: containerID)
        await l2Switch.removePort(containerID: containerID)
        return detectedExit
    }

    /// Reap the FDs / handlers held for a container whose VM stopped on
    /// its own (no explicit `stop()` call). Without this, every short-
    /// lived `cocker run --rm` cycle leaked ~8 FDs into cockerd (mainly
    /// console + stderr pipes + /dev/null + vsock IPC channels).
    func cleanup(containerID: String) async {
        guard let running = runningVMs[containerID] else { return }
        // Finish live log streams before dropping the RunningVM. Consumers
        // receive a clean end-of-stream immediately instead of polling
        // isRunning() until their next timer tick.
        for continuation in running.logContinuations.values {
            continuation.finish()
        }
        running.logContinuations.removeAll()
        // Tear down the readability handler first so it stops capturing
        // the file handle, then close both ends of each pipe explicitly.
        // FileHandle.deinit closes the FD, but the handler closure can
        // outlive deinit if the GCD queue is still draining it.
        running.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? running.stdoutPipe.fileHandleForReading.close()
        try? running.stdoutPipe.fileHandleForWriting.close()
        running.stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? running.stderrPipe.fileHandleForReading.close()
        try? running.stderrPipe.fileHandleForWriting.close()
        runningVMs.removeValue(forKey: containerID)
        pendingNATMACs.removeValue(forKey: containerID)
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
        try RootfsBootstrap.writeSpec(
            to: rootfsPath,
            command: container.command,
            env: container.env,
            workdir: container.config_workdir,
            user: container.config_user,
            privileged: container.privileged,
            capAdd: container.capAdd,
            capDrop: container.capDrop,
            stopSignal: container.stopSignal
        )
    }

    private func writeResolvConf(to rootfsPath: URL, container: Container) throws {
        try RootfsBootstrap.writeResolvConf(to: rootfsPath, dnsIP: DNSServer.hostIP())
        try RootfsBootstrap.writeHostsIfAbsent(
            to: rootfsPath,
            containerName: container.name,
            hostname: container.hostname,
            ip: container.ip
        )
    }

    // MARK: - Logs

    func logs(containerID: String, tail: Int) -> [StreamEvent] {
        // Fast path : container still running, serve from in-memory ring.
        if let running = runningVMs[containerID] {
            let all = running.logBuffer
            if tail <= 0 { return all }
            return Array(all.suffix(tail))
        }
        // Cold path : container already exited (very common for short-
        // lived `cocker run --rm` workloads — the watcher may have
        // dropped runningVMs[id] between `engine.run` returning and the
        // CLI's follow-attach. Without this fallback the user sees no
        // output even though writeJSONLog has it on disk.
        return Self.readJSONLog(containerID: containerID, tail: tail)
    }

    /// Event-driven live log stream for a running container. Returns nil
    /// when the VM is already gone, in which case callers can serve the
    /// persisted backlog and finish immediately.
    func liveLogs(containerID: String) -> AsyncStream<StreamEvent>? {
        guard let running = runningVMs[containerID] else { return nil }
        let subscriptionID = UUID()
        return AsyncStream { continuation in
            running.logContinuations[subscriptionID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.runningVMs[containerID]?.logContinuations
                        .removeValue(forKey: subscriptionID)
                }
            }
        }
    }

    /// Replay the persisted json-file log at
    /// `~/.cocker/containers/<id>/<id>-json.log`. Each line is a Docker-
    /// shape JSON object ({log, stream, time}) ; we decode back to a
    /// StreamEvent so the streaming layer doesn't need to know which
    /// source served the bytes. Used as the cold-path fallback in
    /// `logs(containerID:tail:)`.
    /// Shared formatter for both json-file log writes and replay reads. Used
    /// to be created per call : `cocker logs --tail 10000` triggered ~10 000
    /// `ISO8601DateFormatter()` allocations in a tight loop. One per type is
    /// plenty and the formatter is documented thread-safe.
    private static let jsonLogFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func readJSONLog(containerID: String, tail: Int) -> [StreamEvent] {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cocker/containers/\(containerID)/\(containerID)-json.log")
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        let scope = (tail <= 0) ? Array(lines) : Array(lines.suffix(tail))
        let iso = Self.jsonLogFormatter
        var out: [StreamEvent] = []
        out.reserveCapacity(scope.count)
        for line in scope {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let logStr = obj["log"] as? String
            else { continue }
            let streamRaw = (obj["stream"] as? String) ?? "stdout"
            let stream: StreamEvent.Stream = (streamRaw == "stderr") ? .stderr : .stdout
            let ts = (obj["time"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            out.append(StreamEvent(stream: stream, data: logStr, timestamp: ts))
        }
        return out
    }

    func appendLog(containerID: String, event: StreamEvent) {
        guard let running = runningVMs[containerID] else { return }
        running.logBuffer.append(event)
        for continuation in running.logContinuations.values {
            continuation.yield(event)
        }
        // Cap buffer at 10k lines
        if running.logBuffer.count > 10000 {
            running.logBuffer.removeFirst(running.logBuffer.count - 10000)
        }
        // json-file driver : mirror the event to disk in Docker's exact
        // shape so `docker logs <id>` against the json-file path works
        // for anyone who shells in. Rotation at 10 MB keeps the file from
        // unbounded growth ; rotated copies are .1.gz, .2.gz, …
        Self.writeJSONLog(containerID: containerID, event: event)
    }

    /// Append one line to `~/.cocker/containers/<id>/<id>-json.log` in
    /// Docker's canonical shape `{"log": "...", "stream": "stdout|stderr",
    /// "time": "<RFC3339>"}`. Best-effort : a disk-full or perms failure
    /// silently drops the entry rather than crashing the VM console reader.
    private static func writeJSONLog(containerID: String, event: StreamEvent) {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cocker/containers/\(containerID)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("\(containerID)-json.log")
        let streamName: String = {
            switch event.stream {
            case .stdout: return "stdout"
            case .stderr: return "stderr"
            default: return "stdout"
            }
        }()
        let entry: [String: Any] = [
            "log": event.data,
            "stream": streamName,
            "time": Self.jsonLogFormatter.string(from: event.timestamp),
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: entry),
              let withNL = (String(data: line, encoding: .utf8).map { $0 + "\n" })?.data(using: .utf8)
        else { return }

        // Rotate at 10 MB. We keep up to 5 generations (Docker's default).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int, size > 10 * 1024 * 1024 {
            for i in stride(from: 4, through: 1, by: -1) {
                let from = root.appendingPathComponent("\(containerID)-json.log.\(i)")
                let to = root.appendingPathComponent("\(containerID)-json.log.\(i+1)")
                _ = try? FileManager.default.removeItem(at: to)
                _ = try? FileManager.default.moveItem(at: from, to: to)
            }
            let target = root.appendingPathComponent("\(containerID)-json.log.1")
            _ = try? FileManager.default.removeItem(at: target)
            _ = try? FileManager.default.moveItem(at: path, to: target)
        }

        if let fh = FileHandle(forWritingAtPath: path.path) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: withNL)
        } else {
            try? withNL.write(to: path)
        }
    }

    /// Send a POSIX signal (`SIGQUIT`, `SIGTERM`, …) to the container's
    /// main process by talking to the in-VM `exec_listener` over vsock
    /// port 9000. The listener reads the PID init wrote at
    /// `/cocker-child.pid` and calls `kill(pid, signum)`.
    ///
    /// Best-effort : a missing listener or closed connection is logged
    /// and ignored ; the outer stop() loop falls back to VZ's ACPI
    /// shutdown if the signal didn't trigger an exit within the timeout.
    private func sendStopSignal(vm: VZVirtualMachine, containerID: String, signal: String) async {
        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
            CockerLog.shared.debug("stopsig", "no vsock device for \(containerID)")
            return
        }
        let connection: VZVirtioSocketConnection? = await withCheckedContinuation { cont in
            socketDevice.connect(toPort: 9000) { result in
                switch result {
                case .success(let conn): cont.resume(returning: conn)
                case .failure(let err):
                    CockerLog.shared.error("stopsig", "vsock connect failed for \(containerID): \(err)")
                    cont.resume(returning: nil)
                }
            }
        }
        guard let connection else { return }
        defer { _ = connection } // keep alive past the send

        struct SignalReq: Codable { let signal: String }
        let req = SignalReq(signal: signal)
        guard let data = try? JSONEncoder().encode(req) else { return }
        let fd = connection.fileDescriptor
        _ = data.withUnsafeBytes { buf in
            Darwin.write(fd, buf.baseAddress!, buf.count)
        }
        var nl: UInt8 = 0x0A
        _ = Darwin.write(fd, &nl, 1)

        // Best-effort read of the listener's one-line ack so the daemon
        // log shows whether the kill actually landed. We give it 500 ms
        // — anything slower means the listener is wedged and the ACPI
        // fallback will handle it.
        var ackBuf = [UInt8](repeating: 0, count: 64)
        let deadline = Date().addingTimeInterval(0.5)
        var got = 0
        while Date() < deadline && got == 0 {
            got = ackBuf.withUnsafeMutableBytes { buf in
                Darwin.read(fd, buf.baseAddress!, buf.count)
            }
            if got <= 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                got = 0
            }
        }
        if got > 0 {
            let ack = String(bytes: ackBuf[0..<got], encoding: .utf8) ?? ""
            CockerLog.shared.debug("stopsig", "\(containerID) signal=\(signal) ack=\(ack.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: - Exec via vsock

    func exec(containerID: String, command: [String], env: [String: String], tty: Bool = false,
              stdin: Data? = nil, workdir: String? = nil, user: String? = nil) async throws -> AsyncStream<StreamEvent> {
        guard let running = runningVMs[containerID] else {
            throw CockerError.containerNotRunning(containerID)
        }

        // Connect to vsock port 9000 (cocker-init exec listener)
        guard let socketDevice = running.vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw CockerError.vmCommunicationFailed("No vsock device")
        }

        CockerLog.shared.debug("exec", "connecting vsock 9000 for container=\(containerID)")
        return AsyncStream { continuation in
            let lifetime = ExecStreamLifetime()
            continuation.onTermination = { @Sendable _ in lifetime.cancel() }
            socketDevice.connect(toPort: 9000) { result in
                switch result {
                case .failure(let error):
                    CockerLog.shared.error("exec", "vsock connect failed: \(error)")
                    continuation.yield(StreamEvent(stream: .error,
                        data: "exec failed: \(error) — the in-VM listener may be unavailable (try `cocker restart \(containerID)`)"))
                    continuation.finish()
                case .success(let connection):
                    CockerLog.shared.debug("exec", "vsock connected fd=\(connection.fileDescriptor)")
                    struct ExecReq: Codable {
                        let cmd: [String]
                        let env: [String: String]
                        let tty: Bool
                        let workdir: String?
                        let user: String?
                    }
                    let req = ExecReq(cmd: command, env: env, tty: tty,
                                      workdir: workdir, user: user)
                    // `.sortedKeys` gives a deterministic wire order. The in-VM
                    // parser is now key-order independent either way, but a
                    // stable byte stream keeps logs and the exec-parser tests
                    // reproducible (default JSONEncoder key order is randomized
                    // per process by the hash seed).
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    guard let data = try? encoder.encode(req) else {
                        continuation.yield(StreamEvent(stream: .error, data: "Failed to encode exec request"))
                        continuation.finish(); return
                    }
                    let fd = connection.fileDescriptor
                    guard lifetime.register(fd: fd) else {
                        continuation.finish()
                        return
                    }
                    // Request : single JSON line, NL-terminated. write() may
                    // accept only part of the buffer when the socket send
                    // buffer is nearly full, so loop until every byte is out
                    // (retrying EINTR) BEFORE sending the newline delimiter.
                    // Otherwise a large command / env could ship truncated
                    // JSON followed by the terminator, and the guest would try
                    // to parse a broken request.
                    let ok = data.withUnsafeBytes { buf -> Bool in
                        guard let base = buf.baseAddress else { return false }
                        return writeAllFD(fd, base, buf.count)
                    }
                    guard ok else {
                        continuation.yield(StreamEvent(stream: .error, data: "Failed to send exec request"))
                        continuation.finish(); return
                    }
                    var nl: UInt8 = 0x0A
                    _ = writeAllFD(fd, &nl, 1)
                    CockerLog.shared.debug("exec", "wrote req: bytes=\(data.count) nl=1")

                    // After the JSON+NL terminator, anything we write on
                    // the same vsock fd becomes the child's stdin (the
                    // guest dup2's the client fd onto STDIN_FILENO in
                    // the non-TTY branch of exec_listener.c). Stream
                    // the blob in 64 KB chunks so a multi-MiB heredoc
                    // doesn't stall the single write() on a small
                    // socket buffer.
                    if let stdin, !stdin.isEmpty {
                        stdin.withUnsafeBytes { buf in
                            guard let base = buf.baseAddress else { return }
                            var off = 0
                            let chunkSize = 64 * 1024
                            while off < buf.count {
                                let n = min(chunkSize, buf.count - off)
                                let w = Darwin.write(fd, base.advanced(by: off), n)
                                if w <= 0 { break }
                                off += w
                            }
                        }
                        // Half-close the write side : the in-VM child
                        // sees EOF on stdin once we shutdown(SHUT_WR).
                        // Without this, programs like `cat` block
                        // forever waiting for more input on the still-
                        // open socket. SHUT_WR keeps the read side up
                        // so we still receive the child's stdout +
                        // exit marker on the same fd.
                        _ = Darwin.shutdown(fd, SHUT_WR)
                    }

                    // Capture `connection` strongly so ARC doesn't release it
                    // (and tear down the vsock fd) the moment the callback
                    // returns. Without this, the host side closes its end
                    // before the guest can accept().
                    let retained = ConnectionHolder(connection)
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = retained.connection  // keep alive for the lifetime of the stream
                        defer { lifetime.complete() }
                        var buffer = Data()
                        var chunk = [UInt8](repeating: 0, count: 4096)
                        let exitMarker = Data("__COCKER_EXIT__".utf8)

                        /// Flush whatever leading bytes precede the exit
                        /// marker — without this, the last chunk of stdout
                        /// (which may not end in '\n') gets eaten when the
                        /// marker arrives on the same read.
                        func flush(_ prefix: Data) {
                            guard !prefix.isEmpty,
                                  let text = String(data: prefix, encoding: .utf8)
                            else { return }
                            continuation.yield(StreamEvent(stream: .stdout, data: text))
                        }

                        while true {
                            let n = Darwin.read(fd, &chunk, chunk.count)
                            if n < 0, errno == EINTR { continue }
                            if n <= 0 { continuation.finish(); break }
                            buffer.append(contentsOf: chunk.prefix(n))

                            // The exit marker can land mid-buffer next to
                            // unfinished output ; scan for it explicitly.
                            if let r = buffer.range(of: exitMarker) {
                                flush(buffer[..<r.lowerBound])
                                let tail = buffer[r.upperBound...]
                                // Parse exit code up to a newline (or EOF).
                                let codeBytes: Data
                                if let nl = tail.firstIndex(of: 0x0A) {
                                    codeBytes = Data(tail[..<nl])
                                } else {
                                    codeBytes = Data(tail)
                                }
                                if let codeStr = String(data: codeBytes, encoding: .utf8) {
                                    continuation.yield(StreamEvent(stream: .status,
                                                                   data: "exit:\(codeStr)"))
                                }
                                continuation.finish()
                                return
                            }
                            // Otherwise, drain complete lines.
                            while let nlIdx = buffer.firstIndex(of: 0x0A) {
                                let line = Data(buffer[..<nlIdx])
                                buffer = Data(buffer[buffer.index(after: nlIdx)...])
                                if let text = String(data: line, encoding: .utf8) {
                                    continuation.yield(StreamEvent(stream: .stdout,
                                                                   data: text + "\n"))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// @unchecked Sendable box for VZVirtioSocketConnection — only used to
/// extend its retain across a @Sendable async closure ; we never read
/// or write the wrapped value from multiple threads.
final class ConnectionHolder: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
    init(_ connection: VZVirtioSocketConnection) { self.connection = connection }
}

/// Cancellation bridge for an AsyncStream backed by a blocking vsock read.
/// shutdown(2) wakes the GCD reader immediately when the consumer disappears.
final class ExecStreamLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    func register(fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            return false
        }
        self.fd = fd
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = fd
        lock.unlock()
        if current >= 0 { _ = Darwin.shutdown(current, SHUT_RDWR) }
    }

    func complete() {
        lock.lock(); fd = -1; lock.unlock()
    }
}

/// Single-shot resume guard. NSLock-backed so the timeout / connect
/// callbacks can race from different queues without double-resuming the
/// continuation.
final class ResumeOnceBox: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()
    func tryClaim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

extension VMRuntime {
    /// Synchronous one-shot exec for healthchecks. Connects to vsock 9000,
    /// sends the request, reads until the exit marker or `timeout` seconds
    /// elapse, and tears down the connection unconditionally. Returns the
    /// child's exit code, or 1 on any transport/timeout failure.
    ///
    /// **Known limitation** (Apple Virtualization.framework bug) :
    /// VZVirtioSocketDevice.connect() callback fails to fire when called
    /// repeatedly from a background async context. The probe will reliably
    /// hit its `timeout` and the container's healthStatus flips to
    /// `.unhealthy`. Healthchecks therefore go through the virtiofs file
    /// protocol in ContainerEngine.runHealthcheckOnce (slower but reliable).
    ///
    /// Full bug report + repro + tracking : `docs/APPLE-FEEDBACK-VSOCK-CALLBACK.md`.
    /// Once Apple ships a fix, drop the virtiofs `health_poll` worker and
    /// wire ContainerEngine to call this function instead.
    func execProbe(containerID: String,
                   argv: [String],
                   timeout: TimeInterval) async -> Int32 {
        guard let socketDevice = runningVMs[containerID]?.vm.socketDevices.first as? VZVirtioSocketDevice else {
            CockerLog.shared.debug("probe", "no VM/socket for \(containerID)")
            return 1
        }
        CockerLog.shared.debug("probe", "connecting vsock 9000 for \(containerID)")

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let resumeBox = ResumeOnceBox()
            func resumeOnce(_ code: Int32) {
                if resumeBox.tryClaim() { continuation.resume(returning: code) }
            }

            // Hard deadline : if no callback fires within `timeout` we
            // count it as failed and drop the probe on the floor.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeOnce(1)
            }

            socketDevice.connect(toPort: 9000) { result in
                switch result {
                case .failure(let err):
                    CockerLog.shared.error("probe", "connect failed: \(err)")
                    resumeOnce(1)
                case .success(let connection):
                    let fd = connection.fileDescriptor
                    CockerLog.shared.debug("probe", "connected fd=\(fd)")
                    struct Req: Codable { let cmd: [String]; let env: [String: String] }
                    guard let data = try? JSONEncoder().encode(Req(cmd: argv, env: [:])) else {
                        resumeOnce(1); return
                    }
                    // Box the connection in an @unchecked Sendable holder
                    // so DispatchQueue.global().async (a @Sendable closure)
                    // can keep it alive without tripping Swift 6's
                    // strict-concurrency check. VZVirtioSocketConnection
                    // isn't Sendable but we never touch it across threads —
                    // the box just extends its retain count past the
                    // socketDevice.connect callback's lifetime.
                    let retained = ConnectionHolder(connection)

                    DispatchQueue.global().async {
                        _ = retained
                        defer {
                            // Best-effort fd cleanup. The connection retains
                            // its end ; closing the dup'd fd via shutdown is
                            // safe because we own the read side.
                            shutdown(fd, SHUT_RDWR)
                        }
                        // Write request + NL.
                        let wrote = data.withUnsafeBytes {
                            Darwin.write(fd, $0.baseAddress!, $0.count)
                        }
                        var nl: UInt8 = 0x0A
                        _ = Darwin.write(fd, &nl, 1)
                        if wrote <= 0 { resumeOnce(1); return }

                        var buffer = Data()
                        var chunk = [UInt8](repeating: 0, count: 4096)
                        let marker = Data("__COCKER_EXIT__".utf8)
                        let readDeadline = Date().addingTimeInterval(timeout)
                        while Date() < readDeadline {
                            let n = Darwin.read(fd, &chunk, chunk.count)
                            if n <= 0 { break }
                            buffer.append(contentsOf: chunk.prefix(n))
                            if let r = buffer.range(of: marker) {
                                let tail = buffer[r.upperBound...]
                                let codeBytes: Data
                                if let nlIdx = tail.firstIndex(of: 0x0A) {
                                    codeBytes = Data(tail[..<nlIdx])
                                } else {
                                    codeBytes = Data(tail)
                                }
                                let codeStr = String(data: codeBytes, encoding: .utf8) ?? ""
                                resumeOnce(Int32(codeStr) ?? 1)
                                return
                            }
                        }
                        resumeOnce(1)
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
