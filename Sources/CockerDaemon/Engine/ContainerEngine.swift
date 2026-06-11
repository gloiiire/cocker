import Foundation
import CockerCore

// Main container engine — orchestrates images, VMs, networks, volumes

@MainActor
final class ContainerEngine {
    /// Merge a CLI-supplied healthcheck override onto the image's HEALTHCHECK.
    /// Mirrors Docker semantics : `--no-healthcheck` produces `["NONE"]` (and
    /// `runHealthcheckLoop` early-exits on it). When `--health-cmd` is set,
    /// it replaces the image command and all per-field flags overlay on top
    /// (timeout/interval/etc fall back to image values or Docker defaults).
    /// When only the per-field flags are set without `--health-cmd`, the
    /// image command is preserved and only the supplied fields are overridden.
    static func mergeHealthcheck(image: Healthcheck?, cli: RunConfig) -> Healthcheck? {
        if cli.healthDisable { return Healthcheck(test: ["NONE"]) }
        // Docker treats `--health-cmd ""` (and whitespace-only) the same
        // as `--no-healthcheck` : an explicit empty/blank string is the
        // user's signal to disable any inherited image probe, not a
        // "use the image's command" fallback.
        if let cmd = cli.healthCmd,
           cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Healthcheck(test: ["NONE"])
        }
        let test: [String]
        if let cmd = cli.healthCmd,
           !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            test = ["CMD-SHELL", cmd]
        } else if let img = image {
            test = img.test
        } else if cli.healthInterval == nil && cli.healthTimeout == nil
                  && cli.healthStartPeriod == nil && cli.healthRetries == nil {
            return nil
        } else {
            return nil
        }
        return Healthcheck(
            test: test,
            interval: cli.healthInterval ?? image?.interval ?? 30,
            timeout: cli.healthTimeout ?? image?.timeout ?? 30,
            startPeriod: cli.healthStartPeriod ?? image?.startPeriod ?? 0,
            retries: cli.healthRetries ?? image?.retries ?? 3
        )
    }

    let images: ImageManager
    let networks: NetworkManager
    let volumes: VolumeManager
    let state: StateStore
    let vmRuntime: VMRuntime
    let portForwarder: PortForwarder
    let l2Switch: any L2Switching
    let tracer: CockerTracer
    private let rootDir: URL
    var dnsServer: DNSServer?  // injecté par main après init

    // Event stream
    private var eventContinuations: [UUID: AsyncStream<StreamEvent>.Continuation] = [:]

    /// Per-container watcher + healthcheck Tasks. Tracked so engine.start()
    /// can re-spawn them after a daemon restart without double-spawning when
    /// the originals are still alive (normal stop+start, or pause+unpause).
    /// The UUID disambiguates "did this Task finish cleanly into a clear
    /// of its own slot" from "did a fresh spawn replace it" — the latter
    /// must not erase the dictionary entry of the new owner.
    ///
    /// `alive` flips to false synchronously inside the Task right before
    /// the slot-clearing await ; concurrent spawn callers read it to tell
    /// "still polling" apart from "finished cleanly but slot not yet
    /// reaped". Trusting `Task.isCancelled` alone is broken : a Task that
    /// returned normally reports `isCancelled == false`, so a freshly-
    /// finished watcher would look alive and engine.start() would skip
    /// the respawn it actually needs.
    private struct TaskRecord {
        let task: Task<Void, Never>
        let id: UUID
        var alive: Bool
    }
    private var watcherTasks: [String: TaskRecord] = [:]
    private var healthTasks: [String: TaskRecord] = [:]
    /// Per-container monotonic probe sequence. Replaces the previous
    /// process-global `struct Seq { static var next }` that collided
    /// across daemon restarts and across containers sharing the same
    /// rootfs naming.
    private var probeSeq: [String: UInt64] = [:]

    init(
        rootDir: URL,
        portForwarder: PortForwarder,
        l2Switch: any L2Switching = L2Switch(),
        tracer: CockerTracer = CockerTracer.fromEnvironment()
    ) async throws {
        self.rootDir = rootDir
        self.state = try StateStore(rootDir: rootDir)
        try await self.state.reconcileAfterRestart()
        self.images = try ImageManager(rootDir: rootDir)
        self.networks = try await NetworkManager(store: state)
        self.volumes = VolumeManager(store: state, rootDir: rootDir)
        self.l2Switch = l2Switch
        self.vmRuntime = try VMRuntime(rootDir: rootDir, l2Switch: self.l2Switch)
        self.portForwarder = portForwarder
        self.tracer = tracer
    }

    /// Re-launch containers that were running before the previous daemon
    /// shutdown and have a Docker-style restart policy of `always` or
    /// `unless-stopped`. Mirrors `docker start --restart=always` recovery
    /// on dockerd boot. Called from main.swift after the IPC + Docker API
    /// listeners are wired up, so background restarts can't race with
    /// incoming CLI calls.
    func autoRestartOnBoot() async {
        let all = await state.allContainers(includeAll: true)
        let candidates = all.filter {
            $0.status == .stopped
            && ($0.restartPolicy == .always || $0.restartPolicy == .unlessStopped)
            && $0.finishedAt != nil
        }
        // Parallel restart : with 50+ persistent containers, the previous
        // sequential `for` loop made the daemon's "Ready" banner take
        // minutes. TaskGroup fans them out ; failures of one container
        // don't block the rest. .unlessStopped : we conservatively restart
        // even after explicit stops, matching Docker's behaviour when the
        // policy predates the stop.
        await withTaskGroup(of: Void.self) { group in
            for c in candidates {
                group.addTask { @MainActor [self] in
                    do {
                        try await self.start(id: c.id)
                        fputs("[eng] auto-restarted \(c.id) (policy=\(c.restartPolicy))\n", stderr); fflush(stderr)
                    } catch {
                        fputs("[eng] auto-restart failed for \(c.id): \(error)\n", stderr); fflush(stderr)
                    }
                }
            }
        }
    }

    // MARK: - Container lifecycle

    func run(config: RunConfig) async throws -> String {
        let runSpan = tracer.startSpan("container.run", attributes: [
            "image": config.image,
            "detach": String(config.detach),
        ])
        var spanStatus: SpanStatus = .ok
        defer { runSpan.end(status: spanStatus) }

        fputs("[eng] run() image=\(config.image)\n", stderr); fflush(stderr)
        // Pre-flight lease pool check : if vmnet's bootpd is saturated,
        // the new VM will silently fail DHCP. Touch the helper trigger
        // proactively so we don't ship a half-broken container.
        Self.maybeTriggerLeasePoolClear()
        // Hard gate : at >=252/256 with no helper, refuse the run with
        // a user-facing actionable error rather than booting a VM that
        // can't get an IP. See `preflightLeasePoolOrThrow` for the
        // threshold rationale.
        try Self.preflightLeasePoolOrThrow()
        // Pull image if not present OR if the index entry is there but the
        // rootfs got cleaned up (rmi race, manual `rm -rf`, …). The second
        // case used to surface as "rootfs not extracted — pull first" even
        // though `cocker images` showed the image as available.
        var needsPull = !(await images.exists(config.image))
        if !needsPull, let img = try? await images.find(config.image) {
            let dir = await images.rootfsDirectory(for: img)
            if !FileManager.default.fileExists(atPath: dir.path) { needsPull = true }
        }
        if needsPull {
            let pullSpan = tracer.startSpan("image.pull",
                                            parentSpanID: runSpan.id,
                                            attributes: ["image": config.image])
            do {
                _ = try await images.pull(reference: config.image) { _ in }
                pullSpan.end(status: .ok)
            } catch {
                pullSpan.setAttribute("error", "\(error)")
                pullSpan.end(status: .error)
                spanStatus = .error
                throw error
            }
            fputs("[eng] image not present, pulling\n", stderr); fflush(stderr)
        }
        fputs("[eng] image exists\n", stderr); fflush(stderr)

        // Generate container ID and name (12 chars lowercase, matches state lookup)
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        fputs("[eng] id=\(id)\n", stderr); fflush(stderr)
        let generatedName = await state.generateName()
        let name = config.name ?? generatedName
        fputs("[eng] name=\(name)\n", stderr); fflush(stderr)

        guard !(await state.nameExists(name)) else {
            throw CockerError.containerAlreadyExists(name)
        }
        fputs("[eng] name unique check OK\n", stderr); fflush(stderr)

        // Resolve ports
        let ports = config.ports

        // Resolve volumes from other containers
        var resolvedVolumes = config.volumes
        for sourceID in config.volumesFrom {
            if let sourceContainer = await state.container(id: sourceID) {
                resolvedVolumes.append(contentsOf: sourceContainer.volumes)
            }
        }

        // Docker semantics for `cocker run IMAGE [args...]`:
        //   - args replace the image's CMD (not the ENTRYPOINT)
        //   - if the image has an ENTRYPOINT, the final argv is
        //       ENTRYPOINT + args
        //   - if there's no ENTRYPOINT, the final argv is just args (which
        //     defaults to the image's CMD if the user passed none)
        let imageInfo = try? await images.find(config.image)
        var resolvedCommand = config.command
        if let entrypoint = imageInfo?.entrypoint, !entrypoint.isEmpty {
            // User args replace CMD ; entrypoint is always prepended.
            let cmdPart = resolvedCommand.isEmpty ? (imageInfo?.cmd ?? []) : resolvedCommand
            resolvedCommand = entrypoint + cmdPart
        } else if resolvedCommand.isEmpty {
            // No entrypoint — fall back to image CMD.
            if let cmd = imageInfo?.cmd, !cmd.isEmpty {
                resolvedCommand = cmd
            }
        }

        var resolvedEnv = config.env
        for entry in imageInfo?.env ?? [] {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, resolvedEnv[parts[0]] == nil {
                resolvedEnv[parts[0]] = parts[1]
            }
        }

        // Resolve USER, mirroring Docker : CLI/compose override > image's
        // OCI config.User. Stashed in env[USER] so VMRuntime.writeContainerSpec
        // can hand it to cocker-init via the v3 /cocker-spec.
        if let u = config.user ?? imageInfo?.user, !u.isEmpty {
            resolvedEnv["USER"] = u
        }

        let resolvedWorkdir = config.workdir ?? imageInfo?.workdir

        // Merge labels image + user
        var resolvedLabels = imageInfo?.labels ?? [:]
        for (k, v) in config.labels { resolvedLabels[k] = v }

        // Create container record
        var container = Container(
            id: id,
            name: name,
            image: config.image,
            command: resolvedCommand,
            ports: ports,
            volumes: resolvedVolumes,
            env: resolvedEnv,
            labels: resolvedLabels,
            networkMode: config.networkMode,
            networkName: config.network,
            cpuCount: config.cpuCount,
            memoryMB: config.memoryMB,
            hostname: config.hostname ?? String(id.prefix(12)),
            restartPolicy: config.restartPolicy,
            healthcheck: Self.mergeHealthcheck(image: imageInfo?.healthcheck, cli: config),
            privileged: config.privileged,
            capAdd: config.capAdd,
            capDrop: config.capDrop,
            // Precedence : explicit `cocker run --stop-signal` wins over
            // the image's STOPSIGNAL declaration. Empty string == default
            // (don't carry it forward) so users can deliberately reset
            // a baked-in image signal with `--stop-signal SIGTERM`.
            stopSignal: config.stopSignal ?? imageInfo?.stopSignal
        )
        container.shmSizeMB = config.shmSizeMB
        if let workdir = resolvedWorkdir { container.env["WORKDIR"] = workdir }

        fputs("[eng] container struct created\n", stderr); fflush(stderr)
        // Allocate IP
        container.ip = await networks.allocateIP(for: id)
        fputs("[eng] ipv4=\(container.ip ?? "?")\n", stderr); fflush(stderr)
        container.ipv6 = await networks.allocateIPv6(for: id)
        fputs("[eng] ipv6=\(container.ipv6 ?? "?")\n", stderr); fflush(stderr)
        // Allocate IP+MAC on the cocker L2 switch (inter-container fabric)
        let (cIP, cMAC) = await networks.allocateCockerIPAndMAC(for: id)
        container.cockerIP = cIP
        container.cockerMAC = cMAC
        fputs("[eng] cocker switch ip=\(cIP) mac=\(cMAC)\n", stderr); fflush(stderr)
        // eth0 MAC is filled in after VM start (VZ picks it during config).
        // We use it later to look up the matching lease in
        // /var/db/dhcpd_leases when /cocker-ip polling times out.
        container.natMAC = nil
        try await state.store(container: container)
        fputs("[eng] state stored\n", stderr); fflush(stderr)
        emitEvent("container", action: "create", id: id)
        fputs("[eng] event emitted\n", stderr); fflush(stderr)

        // Start VM
        // Overlay rootfs : clone le rootfs de l'image vers un dossier propre
        // au container via APFS clonefile. Garantit l'isolation fs entre
        // containers de la même image (sinon ils écrivent dans le même rootfs
        // partagé — bug du PoC initial visible sur compose db+web).
        fputs("[eng] cloning rootfs (APFS copy-on-write)\n", stderr); fflush(stderr)
        // S'assure que l'image a un rootfs extrait (pull-on-demand)
        _ = try await images.rootfsPath(for: config.image)
        let rootfsPath = try await images.cloneRootfs(for: config.image, containerID: id)
        fputs("[eng] container rootfs=\(rootfsPath.path)\n", stderr); fflush(stderr)
        fputs("[eng] calling vmRuntime.start\n", stderr); fflush(stderr)
        try await vmRuntime.start(container: container, rootfsPath: rootfsPath)
        fputs("[eng] vmRuntime.start returned\n", stderr); fflush(stderr)
        // Drain the eth0 MAC VZ generated during createVM and persist it so
        // the IP-discovery task below can use it for /var/db/dhcpd_leases
        // fallback when the in-VM /cocker-ip write loses the race.
        if let mac = vmRuntime.takeNATMAC(forContainer: id) {
            container.natMAC = mac
            try? await state.updateContainer(id: id) { c in c.natMAC = mac }
            fputs("[eng] nat MAC=\(mac)\n", stderr); fflush(stderr)
        }

        // Update status
        try await state.updateContainer(id: id) { c in
            c.status = .running
            c.startedAt = Date()
        }

        // Connect to network
        if let networkName = config.network {
            try? await networks.connect(containerID: id, networkID: networkName)
        }

        // Démarre le port forwarding TCP (host port → container IP:port)
        // via le PortForwarder Swift. NAT vmnet est outbound-only sans ça.
        //
        // cocker-init écrit l'IP DHCP réelle du container dans /cocker-ip
        // du rootfs (visible via virtiofs côté host). On poll ce fichier
        // pour récupérer l'IP — placeholder "127.0.0.1" si non dispo.
        if !ports.isEmpty {
            fputs("[eng] scheduling IP discovery task for ports: \(ports.map { $0.description }.joined(separator: ","))\n", stderr); fflush(stderr)
            let natMAC = container.natMAC
            Task { [rootfsPath, ports, id, natMAC] in
                fputs("[eng] IP discovery task started for \(id)\n", stderr); fflush(stderr)
                let ipFile = rootfsPath.appendingPathComponent("cocker-ip")
                fputs("[eng] polling \(ipFile.path)\n", stderr); fflush(stderr)
                var realIP: String? = nil
                for attempt in 0..<150 {  // 15s timeout (100ms × 150)
                    if FileManager.default.fileExists(atPath: ipFile.path),
                       let data = try? Data(contentsOf: ipFile),
                       let ip = String(data: data, encoding: .utf8)?
                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                       !ip.isEmpty {
                        realIP = ip
                        fputs("[eng] IP read on attempt \(attempt): \(ip)\n", stderr); fflush(stderr)
                        break
                    }
                    // After 2 s, start polling the host's vmnet lease file
                    // in parallel — that way an in-VM DHCP loss doesn't
                    // doom port-forwarding, the host knows the lease too.
                    if attempt >= 20, attempt % 5 == 0, let mac = natMAC,
                       let leased = ContainerEngine.lookupLeasedIP(forMAC: mac) {
                        realIP = leased
                        fputs("[eng] IP recovered from /var/db/dhcpd_leases on attempt \(attempt): \(leased) (mac=\(mac))\n", stderr); fflush(stderr)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let finalIP = realIP ?? "127.0.0.1"
                if realIP == nil {
                    let pool = ContainerEngine.leasePoolCount()
                    let helper = ContainerEngine.leasePoolHelperInstalled() ? "yes" : "no"
                    fputs(
                        "[eng] WARN container \(id) got no DHCP IP after 15s — port-forwarding will route to 127.0.0.1 (broken). " +
                        "Lease pool=\(pool)/256, helper installed=\(helper). " +
                        "Run `cocker daemon clear-leases` (one-shot) or `cocker daemon helper-install` (permanent).\n",
                        stderr)
                    fflush(stderr)
                } else {
                    fputs("[eng] container IP discovered: \(finalIP) (ports: \(ports.map { $0.description }.joined(separator: ", ")))\n", stderr); fflush(stderr)
                }
                // Update state with real IP
                try? await self.state.updateContainer(id: id) { c in c.ip = finalIP }
                fputs("[eng] state updated, calling portForwarder.start\n", stderr); fflush(stderr)
                await self.portForwarder.start(containerID: id, containerIP: finalIP, mappings: ports)
                fputs("[eng] portForwarder.start returned\n", stderr); fflush(stderr)
            }
        }

        await cleanHealthcheckDir(containerID: id)
        spawnWatcherIfNeeded(id: id, rm: config.rm)
        spawnHealthcheckIfNeeded(id: id, spec: container.healthcheck)

        // Invalide le cache DNS → le nouveau container est immédiatement résolvable
        await dnsServer?.invalidateCache()

        emitEvent("container", action: "start", id: id)
        return id
    }

    /// Idempotent spawn of the VM watcher Task. Skips when one is already
    /// running — `engine.start()` after a normal `cocker stop` would otherwise
    /// race with the original watcher still finishing its "container truly
    /// stopped" branch. After a daemon restart no Task exists so this
    /// kicks one off.
    ///
    /// "Alive" is the source of truth, not `Task.isCancelled` : a Task
    /// that returns normally has `isCancelled == false`, so the
    /// post-break window between the watcher's loop exit and its slot
    /// reaping would mis-report it as alive.
    private func spawnWatcherIfNeeded(id: String, rm: Bool) {
        if let existing = watcherTasks[id], existing.alive, !existing.task.isCancelled { return }
        let taskID = UUID()
        let task = Task { [weak self] in
            await self?.watchContainer(id: id, rm: rm)
            self?.markWatcherFinished(id: id, taskID: taskID)
        }
        watcherTasks[id] = TaskRecord(task: task, id: taskID, alive: true)
    }

    /// Flip alive→false and (if we still own the slot) drop the record.
    /// Two steps so a concurrent spawn that already replaced us doesn't
    /// see a stale "alive" flag — the slot's record carries the new
    /// task's UUID and our taskID branch won't match.
    private func markWatcherFinished(id: String, taskID: UUID) {
        guard var rec = watcherTasks[id], rec.id == taskID else { return }
        rec.alive = false
        watcherTasks[id] = rec
        if watcherTasks[id]?.id == taskID { watcherTasks[id] = nil }
    }
    private func markHealthFinished(id: String, taskID: UUID) {
        guard var rec = healthTasks[id], rec.id == taskID else { return }
        rec.alive = false
        healthTasks[id] = rec
        if healthTasks[id]?.id == taskID { healthTasks[id] = nil }
    }

    /// Idempotent spawn of the healthcheck Task. Skips when one is already
    /// running. The loop self-terminates when the container is removed from
    /// state (see runHealthcheckLoop) ; daemon restart wipes Task state so
    /// this respawns one if needed.
    private func spawnHealthcheckIfNeeded(id: String, spec: Healthcheck?) {
        guard let spec, !spec.isDisabled else { return }
        if let existing = healthTasks[id], existing.alive, !existing.task.isCancelled { return }
        let taskID = UUID()
        let task = Task { [weak self] in
            await self?.runHealthcheckLoop(containerID: id, spec: spec)
            self?.markHealthFinished(id: id, taskID: taskID)
        }
        healthTasks[id] = TaskRecord(task: task, id: taskID, alive: true)
    }

    /// Cancel + drop all background Tasks for a container. Called from
    /// `remove()` so the loops exit promptly instead of waiting up to
    /// `spec.interval` to notice the container is gone from state.
    private func cancelBackgroundTasks(id: String) {
        watcherTasks[id]?.task.cancel(); watcherTasks[id] = nil
        healthTasks[id]?.task.cancel(); healthTasks[id] = nil
        probeSeq[id] = nil
    }

    /// Wipe leftover cmd-*/result-* files from a previous VM boot. The
    /// virtiofs-backed `/healthcheck` directory survives stop+start ;
    /// without this, the new VM's `health_poll` re-processes stale cmd
    /// files we long since gave up on and writes result-N for seq numbers
    /// the daemon has rolled past. Cheap : the directory holds at most a
    /// handful of files at any moment.
    ///
    /// Synchronous (awaitable) on purpose : the previous
    /// `Task.detached` form raced VM boot — `health_poll` could begin
    /// scanning before the cleanup completed and process stale entries.
    /// Filesystem ops here are unlinks on a small directory, well under
    /// the boot path's noise floor.
    private func cleanHealthcheckDir(containerID: String) async {
        let rootfs = await images.store.containerRootfsDirectory(containerID: containerID)
        let dir = rootfs.appendingPathComponent("healthcheck")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for e in entries where e.hasPrefix("cmd-") || e.hasPrefix("result-") || e.hasPrefix(".result-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(e))
        }
    }

    /// Background loop that re-exec's the healthcheck command at `spec.interval`,
    /// updates `Container.healthStatus`, and emits `health_status` events.
    ///
    /// Lifecycle matches Docker's : the loop survives container restart
    /// (status briefly transits through `.restarting`), pause (status
    /// `.paused`), and manual stop+start cycles. It exits only when the
    /// container is fully removed from the state store. While the container
    /// isn't `.running` the loop sleeps and resets its failure counter so
    /// the post-resume probes start from a clean slate.
    private func runHealthcheckLoop(containerID: String, spec: Healthcheck) async {
        try? await state.updateContainer(id: containerID) { c in c.healthStatus = .starting }
        var consecutiveFailures = 0
        var nowHealthy = false
        var wasRunning = true
        // Restart grace : flat 5 s after a stop+start cycle so the VM
        // can spawn health_poll and the service can come back up before
        // we start probing. Deliberately NOT `max(startPeriod, 5)` — Docker's
        // start_period is initial-only and stacking it on every restart
        // would mark a quickly-restarting container as "starting" for
        // far longer than docker does, breaking timing-sensitive
        // orchestration that polls for "healthy".
        let restartGrace: TimeInterval = 5
        // Initial start period : Docker runs probes during this window but
        // treats failures as non-counting (a probe that succeeds early
        // flips to healthy immediately). Applies once, on initial boot.
        let initialStartPeriodEndsAt = Date().addingTimeInterval(spec.startPeriod)
        var nextProbeAllowedAt = Date()
        // Translate the OCI Test array into argv for exec_listener. The
        // first element is canonicalised to uppercase so a hand-written
        // image config with `["cmd-shell", "foo"]` or `["none"]` doesn't
        // fall through to "run as bare argv".
        let argv: [String] = {
            guard let raw = spec.test.first else { return [] }
            let kind = raw.uppercased()
            if kind == "NONE" { return [] }
            if kind == "CMD-SHELL" {
                let body = spec.test.dropFirst().joined(separator: " ")
                return ["/bin/sh", "-c", body]
            }
            // "CMD" or bare argv
            return Array(spec.test.dropFirst(kind == "CMD" ? 1 : 0))
        }()
        guard !argv.isEmpty else {
            try? await state.updateContainer(id: containerID) { c in c.healthStatus = .none }
            return
        }
        while true {
            // Cooperative cancellation : `remove()` calls cancelBackgroundTasks
            // which invokes Task.cancel ; without this check we'd keep
            // polling state for up to `interval` seconds.
            if Task.isCancelled { return }
            // Container removed from state ↔ truly gone. Exit cleanly.
            guard let c = await state.container(id: containerID) else { return }
            if c.status != .running {
                // .paused / .restarting / .stopped / .dead — wait until
                // the container resumes (or is removed) before probing.
                // Reset counters so a resume starts from "starting".
                consecutiveFailures = 0
                wasRunning = false
                // Persist the streak reset to state — otherwise
                // `docker inspect` shows a phantom FailingStreak from the
                // last run until the first probe of the next session
                // (potentially hours if the container stays stopped).
                if c.healthFailingStreak != 0 || (nowHealthy && c.healthStatus != .starting) {
                    try? await state.updateContainer(id: containerID) { c in
                        c.healthFailingStreak = 0
                        if c.healthStatus == .healthy { c.healthStatus = .starting }
                    }
                    nowHealthy = false
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            // Transition non-running → running : honour Docker's
            // start_period semantics by giving the VM time to fully boot
            // (kernel + cocker-init + service + health_poll) before
            // probe failures count.
            if !wasRunning {
                wasRunning = true
                nextProbeAllowedAt = Date().addingTimeInterval(restartGrace)
                try? await state.updateContainer(id: containerID) { c in c.healthStatus = .starting }
            }
            try? await Task.sleep(nanoseconds: UInt64(spec.interval * 1_000_000_000))
            // Re-check status post-sleep : the sleep window is enough
            // for `cocker stop`/`pause` to land. Don't probe a dead VM.
            guard await state.container(id: containerID)?.status == .running else { continue }
            // Skip until the post-restart warm-up has elapsed. Cheap : the
            // outer interval sleep already paces the loop.
            if Date() < nextProbeAllowedAt { continue }
            let probeStart = Date()
            let result = await runHealthcheckOnce(containerID: containerID,
                                                  argv: argv,
                                                  timeout: spec.timeout)
            let probeEnd = Date()
            // The container can transition out of `.running` mid-probe
            // (pause / stop / kill). The probe would then time out for
            // reasons unrelated to the service's actual health — discard
            // and don't taint the Health.Log.
            guard await state.container(id: containerID)?.status == .running else { continue }
            // Always append to the ring buffer ; FailingStreak is updated
            // below based on Docker's start-period rules.
            try? await state.updateContainer(id: containerID) { c in
                c.healthLog.append(HealthLogEntry(start: probeStart,
                                                  end: probeEnd,
                                                  exitCode: result.exitCode,
                                                  output: result.output))
                if c.healthLog.count > 5 {
                    c.healthLog.removeFirst(c.healthLog.count - 5)
                }
            }
            if result.exitCode == 0 {
                consecutiveFailures = 0
                try? await state.updateContainer(id: containerID) { c in c.healthFailingStreak = 0 }
                if !nowHealthy {
                    nowHealthy = true
                    try? await state.updateContainer(id: containerID) { c in c.healthStatus = .healthy }
                    emitEvent("container", action: "health_status: healthy", id: containerID)
                }
            } else {
                // Docker semantics : during start_period, failures do NOT
                // count toward retries. They still run (and could flip
                // healthy on next success) but we don't drift toward
                // unhealthy yet.
                if Date() < initialStartPeriodEndsAt { continue }
                consecutiveFailures += 1
                try? await state.updateContainer(id: containerID) { c in
                    c.healthFailingStreak = consecutiveFailures
                }
                if consecutiveFailures >= spec.retries, nowHealthy || consecutiveFailures == spec.retries {
                    nowHealthy = false
                    try? await state.updateContainer(id: containerID) { c in c.healthStatus = .unhealthy }
                    emitEvent("container", action: "health_status: unhealthy", id: containerID)
                }
            }
        }
    }

    /// Single healthcheck probe via the virtiofs file protocol.
    ///
    /// cockerd writes `<container-rootfs>/healthcheck/cmd-<seq>` (argv
    /// NUL-separated) ; cocker-init's health_poll worker reads it, runs
    /// the command, and writes `result-<seq>` with the exit code. We
    /// poll for the result file and return its content. Honours the
    /// Dockerfile HEALTHCHECK CMD verbatim — no port-probe substitution,
    /// no VZ vsock callback dependency.
    /// Result of a single probe : exit code + the child's combined
    /// stdout+stderr (capped server-side at 4 KB by health_poll). The
    /// output feeds Container.healthLog so `docker inspect` can surface
    /// recent probe history exactly like Docker does.
    struct ProbeResult {
        var exitCode: Int32
        var output: String
    }

    private func runHealthcheckOnce(containerID: String,
                                    argv: [String],
                                    timeout: TimeInterval) async -> ProbeResult {
        // Per-container monotonic probe sequence. A process-global counter
        // would collide when the daemon restarted (counter resets to 0
        // while old result-* files still exist on the shared rootfs).
        let seq = probeSeq[containerID] ?? 0
        probeSeq[containerID] = seq &+ 1

        let rootfs = await images.store.containerRootfsDirectory(containerID: containerID)
        let dir = rootfs.appendingPathComponent("healthcheck")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cmdFile = dir.appendingPathComponent("cmd-\(seq)")
        let resultFile = dir.appendingPathComponent("result-\(seq)")

        // Wire format : optional "TIMEOUT=<seconds>\n" header so the
        // guest worker enforces its own SIGKILL deadline ; then argv
        // joined with NUL. Without the header a hung probe would
        // outlive our daemon-side deadline and block subsequent probes
        // serially inside health_poll. Carries the full Double-precision
        // timeout so `--health-timeout 1.5s` doesn't round to 1.
        var encoded = String(format: "TIMEOUT=%.3f\n", timeout)
        encoded += argv.joined(separator: "\u{0}")
        do {
            try Data(encoded.utf8).write(to: cmdFile, options: .atomic)
        } catch {
            fputs("[health] couldn't write \(cmdFile.path): \(error)\n", stderr); fflush(stderr)
            return ProbeResult(exitCode: 1, output: "internal: failed to write probe request")
        }

        // Daemon-side budget = timeout + 2s slack for the guest's
        // own SIGKILL + result rename to land. Anything past that and
        // we abandon the probe (the worker will still clean up its
        // own cmd file once it notices it's gone).
        let deadline = Date().addingTimeInterval(timeout + 2)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let data = try? Data(contentsOf: resultFile) else { continue }
            // Tolerate non-UTF8 by replacing invalid sequences. A probe
            // that prints a binary blob would otherwise nil the String
            // init and we'd loop until daemon-side timeout, returning 124
            // for what was really a successful probe printing garbage.
            let raw: String = String(data: data, encoding: .utf8)
                           ?? String(decoding: data, as: UTF8.self)
            // First line = decimal exit code, rest = captured output.
            guard let nl = raw.firstIndex(of: "\n") else { continue }
            let codeStr = String(raw[..<nl]).trimmingCharacters(in: .whitespaces)
            guard let code = Int32(codeStr) else { continue }
            // Strip NUL bytes : JSONEncoder writes them as  which some
            // Docker template parsers reject. Replace with a single space.
            let output = String(raw[raw.index(after: nl)...])
                .replacingOccurrences(of: "\u{0}", with: " ")
            try? FileManager.default.removeItem(at: resultFile)
            fputs("[health] cmd \(containerID) seq=\(seq) → exit \(code)\n", stderr); fflush(stderr)
            return ProbeResult(exitCode: code, output: output)
        }
        try? FileManager.default.removeItem(at: cmdFile)
        fputs("[health] cmd \(containerID) seq=\(seq) → daemon-side timeout after \(Int(timeout))s\n", stderr); fflush(stderr)
        // 124 matches Docker's reserved "timeout" exit code so the surfaced
        // FailingStreak / Log entry tells the user what went wrong.
        return ProbeResult(exitCode: 124, output: "probe timed out")
    }

    /// One-shot TCP connect probe : returns true if a SYN-ACK comes back
    /// within `timeout` seconds. Uses Darwin sockets directly (Network
    /// framework would drag in NWConnection ceremony for a 4-line check).
    private func tcpReachable(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = ResumeOnceBox()
            DispatchQueue.global().async {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    if box.tryClaim() { continuation.resume(returning: false) }
                    return
                }
                // Non-blocking + connect + select for timeout. Reading
                // ECONNREFUSED gives a fast negative ; otherwise we wait
                // for writability via select.
                var flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(port).bigEndian
                inet_pton(AF_INET, host, &addr.sin_addr)

                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                let reachable: Bool
                if rc == 0 {
                    reachable = true
                } else if errno == EINPROGRESS {
                    var wfds = fd_set()
                    let bytesPerMask = MemoryLayout<Int32>.size * 8
                    let maskIndex = Int(fd) / bytesPerMask
                    let bitInMask = Int32(1) << Int32(Int(fd) % bytesPerMask)
                    withUnsafeMutablePointer(to: &wfds.fds_bits) {
                        $0.withMemoryRebound(to: Int32.self, capacity: 32) { p in
                            p[maskIndex] |= bitInMask
                        }
                    }
                    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                    let sr = select(fd + 1, nil, &wfds, nil, &tv)
                    if sr > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                        reachable = (err == 0)
                    } else {
                        reachable = false
                    }
                    flags = fcntl(fd, F_GETFL, 0)
                    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                } else {
                    reachable = false
                }
                close(fd)
                if box.tryClaim() { continuation.resume(returning: reachable) }
            }
        }
    }

    func start(id: String) async throws {
        let span = tracer.startSpan("container.start", attributes: ["container.id": id])
        var status: SpanStatus = .ok
        defer { span.end(status: status) }

        guard let container = await state.container(id: id) else {
            status = .error; span.setAttribute("error", "container_not_found")
            throw CockerError.containerNotFound(id)
        }
        guard container.status == .stopped || container.status == .created else {
            status = .error; span.setAttribute("error", "already_running")
            throw CockerError.containerAlreadyRunning(id)
        }

        // Réutilise le rootfs cloné du container (créé au run initial).
        // S'il n'existe plus (cleanup, premier start après crash daemon),
        // on le re-clone depuis l'image source.
        // Important : utiliser `container.id` (canonique) et non `id` (qui
        // peut être un name passé via la CLI) — sinon le path rootfs
        // devient `containers/<name>/rootfs` au lieu de `containers/<id>/rootfs`
        // et le daemon écrit /healthcheck/cmd-* dans un rootfs différent
        // de celui que la nouvelle VM monte.
        let canonicalID = container.id
        let containerRootfs = await images.store.containerRootfsDirectory(containerID: canonicalID)
        let rootfsPath: URL
        if FileManager.default.fileExists(atPath: containerRootfs.path) {
            rootfsPath = containerRootfs
        } else {
            _ = try await images.rootfsPath(for: container.image)
            rootfsPath = try await images.cloneRootfs(for: container.image, containerID: canonicalID)
        }
        do {
            try await vmRuntime.start(container: container, rootfsPath: rootfsPath)
        } catch {
            status = .error; span.setAttribute("error", "\(error)")
            throw error
        }
        try await state.updateContainer(id: canonicalID) { c in
            c.status = .running
            c.startedAt = Date()
            c.finishedAt = nil
        }
        // Respawn watcher + healthcheck loop if they're not already alive.
        // After a normal `cocker stop` the watcher exits via its truly-stopped
        // branch and we need a fresh one. After a daemon restart no Task
        // exists at all. Skips when an existing Task is still polling.
        await cleanHealthcheckDir(containerID: canonicalID)
        spawnWatcherIfNeeded(id: canonicalID, rm: false)
        spawnHealthcheckIfNeeded(id: canonicalID, spec: container.healthcheck)
        emitEvent("container", action: "start", id: container.id)
    }

    func stop(id: String, timeout: TimeInterval = 10) async throws {
        let span = tracer.startSpan("container.stop", attributes: ["container.id": id])
        var status: SpanStatus = .ok
        defer { span.end(status: status) }

        guard let container = await state.container(id: id) else {
            status = .error; throw CockerError.containerNotFound(id)
        }
        guard container.status == .running else {
            status = .error; throw CockerError.containerNotRunning(id)
        }

        // vmRuntime.stop now returns the parsed exit code (Int32?) from
        // the captured console log, sampled before the log buffer is
        // released. ContainerEngine just hands it through ; the prior
        // hardcoded 0 hid graceful stops with non-zero traps (nginx
        // STOPSIGNAL → exit 5) and force-kills (137).
        var detectedExit: Int32 = 0
        do {
            if let code = try await vmRuntime.stop(containerID: container.id,
                                                    timeout: timeout,
                                                    stopSignal: container.stopSignal) {
                detectedExit = code
            }
        } catch {
            status = .error; span.setAttribute("error", "\(error)")
            throw error
        }
        await portForwarder.stop(containerID: container.id)
        try await state.updateContainer(id: id) { c in
            c.status = .stopped
            c.finishedAt = Date()
            c.exitCode = detectedExit
        }
        await dnsServer?.invalidateCache()
        emitEvent("container", action: "stop", id: container.id)
    }

    func kill(id: String, signal: String = "SIGKILL") async throws {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }
        try await vmRuntime.stop(containerID: container.id, timeout: 0)
        await portForwarder.stop(containerID: container.id)
        try await state.updateContainer(id: id) { c in
            c.status = .dead
            c.finishedAt = Date()
            c.exitCode = -1
        }
        emitEvent("container", action: "kill", id: container.id)
    }

    func restart(id: String, timeout: TimeInterval = 10) async throws {
        // Resolve once so the emitted event carries the canonical id, not
        // whatever CLI alias (name / 4-char prefix) the caller used.
        let canonical = await state.container(id: id)?.id ?? id
        try await stop(id: canonical, timeout: timeout)
        try await start(id: canonical)
        emitEvent("container", action: "restart", id: canonical)
    }

    func pause(id: String) async throws {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }
        try await vmRuntime.pause(containerID: container.id)
        try await state.updateContainer(id: id) { c in c.status = .paused }
        emitEvent("container", action: "pause", id: container.id)
    }

    func unpause(id: String) async throws {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }
        try await vmRuntime.resume(containerID: container.id)
        try await state.updateContainer(id: id) { c in c.status = .running }
        emitEvent("container", action: "unpause", id: container.id)
    }

    func remove(id: String, force: Bool = false) async throws {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }

        if container.status == .running {
            if force {
                try await kill(id: container.id, signal: "SIGKILL")
            } else {
                throw CockerError.containerAlreadyRunning(container.id)
            }
        }

        // Stop background loops BEFORE removing the rootfs/state. Otherwise
        // an in-flight healthcheck probe could try to write to a directory
        // we're about to delete (file write fails silently, but the
        // healthLog state.updateContainer call resurrects a stale entry
        // for an id that no longer exists).
        cancelBackgroundTasks(id: container.id)
        await networks.releaseIP(for: container.id)
        await portForwarder.stop(containerID: container.id)
        // Supprime aussi le rootfs cloné du container (libère l'espace
        // disque pris par les modifications post-clonefile).
        try? await images.removeContainerRootfs(containerID: container.id)
        try await state.removeContainer(id: container.id)
        emitEvent("container", action: "destroy", id: container.id)
    }

    // MARK: - Query

    func list(all: Bool = false, filter: [String: String] = [:]) async -> [Container] {
        var containers = await state.allContainers(includeAll: all)

        for (key, value) in filter {
            switch key {
            case "status": containers = containers.filter { $0.status.rawValue == value }
            case "name": containers = containers.filter { $0.name.contains(value) }
            case "image": containers = containers.filter { $0.image.contains(value) }
            case "label":
                let kv = value.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    containers = containers.filter { $0.labels[String(kv[0])] == String(kv[1]) }
                }
            default: break
            }
        }

        return containers
    }

    func inspect(id: String) async throws -> Container {
        guard let c = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }
        return c
    }

    // MARK: - Logs

    func logs(id: String, request: LogsRequest) async throws -> AsyncStream<StreamEvent> {
        guard let container = await state.container(id: id) else {
            throw CockerError.containerNotFound(id)
        }

        let historical = vmRuntime.logs(containerID: container.id, tail: request.tail)
        let follow = request.follow
        let containerID = container.id

        return AsyncStream { continuation in
            Task { @MainActor in
                for event in historical {
                    continuation.yield(event)
                }

                if !follow {
                    continuation.finish()
                    return
                }

                // Tail follow: check every 100ms for new logs (real impl: pipe from VM console)
                var lastCount = historical.count
                while true {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let current = self.vmRuntime.logs(containerID: containerID, tail: 0)
                    if current.count > lastCount {
                        for event in current.dropFirst(lastCount) {
                            continuation.yield(event)
                        }
                        lastCount = current.count
                    }
                    if !self.vmRuntime.isRunning(containerID: containerID) {
                        break
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Exec

    func exec(config: ExecConfig) async throws -> AsyncStream<StreamEvent> {
        guard let container = await state.container(id: config.containerID) else {
            throw CockerError.containerNotFound(config.containerID)
        }
        guard container.status == .running else {
            throw CockerError.containerNotRunning(config.containerID)
        }
        return try await vmRuntime.exec(containerID: container.id, command: config.command, env: config.env, tty: config.tty, stdin: config.stdin)
    }

    // MARK: - System info

    func info() async -> InfoResponse {
        let allContainers = await state.allContainers(includeAll: true)
        let runningCount = allContainers.filter { $0.status == .running }.count
        let allImages = await images.list()
        let allNetworks = await networks.list()
        let allVolumes = await volumes.list()

        let memTotal = ProcessInfo.processInfo.physicalMemory
        let cpuCount = ProcessInfo.processInfo.processorCount

        var kernel = "unknown"
        var sysinfo = utsname()
        if uname(&sysinfo) == 0 {
            kernel = withUnsafeBytes(of: sysinfo.release) { ptr in
                String(cString: ptr.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
        }

        return InfoResponse(
            containers: allContainers.count,
            containersRunning: runningCount,
            images: allImages.count,
            volumes: allVolumes.count,
            networks: allNetworks.count,
            kernelVersion: kernel,
            architecture: "arm64",
            cpus: cpuCount,
            totalMemory: memTotal,
            cockerRootDir: rootDir.path,
            socketPath: IPCClient.defaultSocketPath
        )
    }

    // MARK: - Prune

    func prune(volumes: Bool = false) async throws -> PruneResponse {
        // 1. Stopped / dead containers.
        let deletedContainers = try await state.pruneStopped()

        var deletedImages: [String] = []
        var deletedVolumes: [String] = []
        var spaceReclaimed: UInt64 = 0

        // 2. Dangling images : referenced by zero containers AND not the
        // base image for another stored image. We approximate "dangling"
        // as "no live container references it by repository:tag".
        let liveContainers = await state.allContainers(includeAll: true)
        let usedImages = Set(liveContainers.map { $0.image })
        let allImages = await images.list()
        for img in allImages where !usedImages.contains(img.reference) {
            // Skip images that are still the base for tagged children — we
            // don't track image lineage, so we only drop images with no
            // tag (truly dangling). Tag string is "<repo>:<tag>" ; a tag
            // of <none> would mark dangling but cocker doesn't produce
            // those today, so this whole branch is a future-proofing stub.
            if img.tag == "<none>" {
                try? await images.remove(img.reference)
                deletedImages.append(img.reference)
                spaceReclaimed += img.size
            }
        }

        // 3. Unused networks (non-default, not referenced by any container).
        let usedNetworks = Set(liveContainers.compactMap { $0.networkName })
        let allNetworks = await networks.list()
        for net in allNetworks where !usedNetworks.contains(net.name) && net.name != "bridge" && net.name != "host" && net.name != "none" {
            try? await networks.remove(net.name, force: false)
        }

        // 4. Optional : unused named volumes.
        if volumes {
            let (names, bytes) = try await self.volumes.pruneUnused()
            deletedVolumes = names
            spaceReclaimed += bytes
        }

        return PruneResponse(
            containersDeleted: deletedContainers,
            imagesDeleted: deletedImages,
            volumesDeleted: deletedVolumes,
            spaceReclaimed: spaceReclaimed
        )
    }

    // MARK: - Event system

    func eventStream() -> AsyncStream<StreamEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { @MainActor in
                self.eventContinuations[id] = continuation
                continuation.onTermination = { @Sendable _ in
                    Task { @MainActor in
                        self.eventContinuations.removeValue(forKey: id)
                    }
                }
            }
        }
    }

    /// Event wire format : `"<type>\t<action>\t<id>"`. Tab-separated so
    /// actions like `health_status: healthy` (which contain ': ' and spaces)
    /// round-trip cleanly through `handleEvents` in the Docker API layer.
    /// Pipe wasn't used because Docker `docker events` filter syntax uses
    /// pipes as alternation in regexes, which makes reading a tcpdump grep
    /// awkward.
    private func emitEvent(_ type: String, action: String, id: String) {
        let event = StreamEvent(stream: .status, data: "\(type)\t\(action)\t\(id)")
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
        // Audit trail. Append every lifecycle event to a structured log
        // file with timestamp + user + type + action + id. Used for
        // forensics / compliance / dev debugging when something goes
        // sideways. Rotated by the same LogRotator used for cockerd.log.
        Self.writeAuditLog(type: type, action: action, id: id)
    }

    /// Append-only audit trail at `~/.cocker/audit.log`. One line per event,
    /// JSON-encoded so downstream tooling (jq, vector, fluent-bit) can
    /// ingest it without parsing. Bounded at 10 MB ; rotated to .1.gz …
    /// .5.gz like cockerd.log.
    private static func writeAuditLog(type: String, action: String, id: String) {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cocker")
        let path = root.appendingPathComponent("audit.log")
        let user = ProcessInfo.processInfo.environment["USER"] ?? "?"
        let entry: [String: String] = [
            "ts":     ISO8601DateFormatter().string(from: Date()),
            "user":   user,
            "type":   type,
            "action": action,
            "id":     id,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = (String(data: data, encoding: .utf8).map { $0 + "\n" })?
                            .data(using: .utf8)
        else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            // First write — create with 0o600 perms (audit logs can carry
            // container labels / env hints that shouldn't leak to other
            // local users).
            FileManager.default.createFile(atPath: path.path, contents: line,
                attributes: [.posixPermissions: 0o600])
        }
        // Cheap-ish rotation : check size occasionally and roll.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int, size > 10 * 1024 * 1024 {
            try? LogRotator.rotate(file: path, keep: 5)
        }
    }

    // MARK: - Container watcher

    private func watchContainer(id: String, rm: Bool) async {
        // Restart bookkeeping. Cocker mirrors Docker's defaults : a hard cap
        // at 10 retries for on-failure, infinite for always / unless-stopped
        // (the user opted in). Exponential backoff starts at 100 ms and
        // doubles to a 30 s ceiling, also matching Docker.
        var restartAttempts = 0
        let maxFailureRetries = 10
        let baseBackoff: TimeInterval = 0.1
        let maxBackoff: TimeInterval = 30

        // Poll VM state
        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { break }
            // Paused VMs aren't "running" in VZ's sense but they aren't
            // dead either — the user expects them to resume. Skip the
            // truly-stopped branch when state already says .paused so the
            // watcher doesn't race the pause command and mark the
            // container .stopped underneath us.
            if await state.container(id: id)?.status == .paused {
                continue
            }
            if !vmRuntime.isRunning(containerID: id) {
                guard let container = await state.container(id: id) else { break }

                // Give cocker-init's "exited with code N" line a moment to
                // reach the console buffer. The reader runs on a Pipe queue
                // + relays through a Task — the buffer isn't necessarily
                // up-to-date the instant VM state flips to stopped.
                var parsedCode: Int32? = nil
                for _ in 0..<10 {
                    parsedCode = vmRuntime.exitCode(forContainer: id)
                    if parsedCode != nil { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await state.updateContainer(id: id) { c in
                    c.finishedAt = Date()
                    if c.exitCode == nil { c.exitCode = parsedCode ?? 0 }
                }

                // Check restart policy
                let exitCode = parsedCode ?? container.exitCode ?? 0
                var shouldRestart = false
                switch container.restartPolicy {
                case .always:
                    shouldRestart = true
                case .unlessStopped:
                    // Don't restart if the user explicitly issued `cocker stop`
                    // (status is mutated to .stopped before the VM dies).
                    shouldRestart = container.status != .stopped
                case .onFailure:
                    // Only restart on non-zero exit, and respect the retry cap.
                    shouldRestart = exitCode != 0 && restartAttempts < maxFailureRetries
                case .no:
                    shouldRestart = false
                }

                if shouldRestart {
                    restartAttempts += 1
                    // Exponential backoff capped at maxBackoff.
                    let backoff = min(baseBackoff * pow(2.0, Double(restartAttempts - 1)),
                                       maxBackoff)
                    try? await state.updateContainer(id: id) { c in
                        c.status = .restarting
                        c.restartCount += 1
                    }
                    emitEvent("container", action: "restart_attempt:\(restartAttempts)", id: id)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    if let c = await state.container(id: id) {
                        // Reuse the container's clonefile rootfs from the
                        // initial run. Falling through to images.rootfsPath
                        // (the image's shared rootfs) would have every
                        // restart write into the image itself — eventually
                        // corrupting it for any other container that boots
                        // off the same digest.
                        let cloned = await images.store.containerRootfsDirectory(containerID: id)
                        let rootfsPath: URL?
                        if FileManager.default.fileExists(atPath: cloned.path) {
                            rootfsPath = cloned
                        } else {
                            // Container clone was cleaned up (rare) — re-clone
                            // from the image instead of writing to the shared
                            // image rootfs directly.
                            rootfsPath = try? await images.cloneRootfs(for: c.image,
                                                                       containerID: id)
                        }
                        if let rootfsPath {
                            // Wipe stale healthcheck IO from the previous
                            // VM session before the new boot. Mirrors the
                            // cleanup `engine.start` already does on the
                            // user-driven path — without it, restart-policy
                            // relaunches see `health_poll` re-processing
                            // sequence numbers the daemon has long since
                            // rolled past.
                            await cleanHealthcheckDir(containerID: id)
                            do {
                                try await vmRuntime.start(container: c, rootfsPath: rootfsPath)
                                try? await state.updateContainer(id: id) { c in
                                    c.status = .running
                                    c.startedAt = Date()
                                    c.exitCode = nil
                                }
                                // Successful restart resets the failure counter
                                // for `always` / `unless-stopped` so transient
                                // crashes don't drift toward the maxBackoff.
                                if container.restartPolicy != .onFailure {
                                    restartAttempts = 0
                                }
                            } catch {
                                fputs("[eng] restart failed: \(error)\n", stderr); fflush(stderr)
                            }
                        }
                    }
                    continue  // Keep watching
                }

                // Container truly stopped
                try? await state.updateContainer(id: id) { c in
                    c.status = .stopped
                }
                // Release the VM's host-side handles (console pipes, vsock
                // channels, devnull dup). Without this every `cocker run
                // --rm` cycle leaked ~8 FDs into cockerd → daemon hits
                // its FD ceiling after a few hundred runs.
                await vmRuntime.cleanup(containerID: id)
                if rm {
                    try? await state.removeContainer(id: id)
                }
                break
            }
        }
    }

    // MARK: - Image GC

    /// Drop image-store entries that are older than `olderThanDays` AND
    /// not referenced by any container (running or stopped). Returns the
    /// list of references that were actually removed.
    ///
    /// Invoked from the daemon's background sweep. Skipping containers'
    /// stopped images keeps `docker run --rm` semantics intact : an
    /// image stays as long as a container that could be restarted still
    /// references it.
    public func gcImages(olderThanDays days: Int) async throws -> [String] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let live = await state.allContainers(includeAll: true)
        let used = Set(live.map { $0.image })
        let candidates = await images.list().filter {
            $0.createdAt < cutoff && !used.contains($0.reference)
        }
        var pruned: [String] = []
        for img in candidates {
            do {
                try await images.remove(img.reference)
                pruned.append(img.reference)
            } catch {
                // Best-effort : one stuck image shouldn't block the rest.
                fputs("[gc] skip \(img.reference): \(error)\n", stderr)
            }
        }
        return pruned
    }

    // MARK: - DHCP recovery helpers

    /// Derive a stable, locally-administered MAC from a container ID. The
    /// `02:cc:` prefix marks the address as locally-administered (the second
    /// hex nibble bit 1 set, bit 0 clear) so vmnet treats it as unicast and
    /// the host stack doesn't dedupe against any global allocation. The
    /// remaining 4 bytes come from the first 8 hex chars of the container
    /// id, which is already random enough (UUID prefix).
    /// Runtime lease-pool guard. Called before each `container.run` :
    /// if `/var/db/dhcpd_leases` is close to vmnet's ~256 ceiling AND
    /// the LaunchDaemon helper is installed, touch the trigger file so
    /// the helper truncates the pool in time for the new VM's DHCP
    /// request. If the helper isn't installed, falls through to the
    /// existing logged warning at daemon startup. Cheap : one stat +
    /// one regex sweep on a typically <10 KB file.
    static func maybeTriggerLeasePoolClear() {
        guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return }
        let count = leases.components(separatedBy: "ip_address=").count - 1
        guard count > 200 else { return }
        let helperInstalled = FileManager.default.fileExists(
            atPath: "/Library/LaunchDaemons/com.cocker.leases-helper.plist")
        guard helperInstalled else { return }
        let trigger = URL(fileURLWithPath: "/var/run/cocker-clear-leases")
        // Skip if a previous trigger is still pending — the helper polls
        // every 1 s so the worst-case latency is <2 s.
        guard !FileManager.default.fileExists(atPath: trigger.path) else { return }
        _ = try? Data().write(to: trigger)
        fputs("[lease-gc] pool at \(count) — touched helper trigger\n", stderr); fflush(stderr)
    }

    /// Helpers exposed so other parts of the engine + the CLI's
    /// `cocker daemon status` can report state without re-implementing
    /// the file parsing.

    static func leasePoolCount() -> Int {
        guard let s = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return 0 }
        return s.components(separatedBy: "ip_address=").count - 1
    }

    static func leasePoolHelperInstalled() -> Bool {
        FileManager.default.fileExists(
            atPath: "/Library/LaunchDaemons/com.cocker.leases-helper.plist")
    }

    /// Hard pre-flight gate. Called from `run()` before any VM resource
    /// is allocated. We refuse to start when the pool is at the edge
    /// AND the user has no auto-clear path — booting the VM there would
    /// burn the rootfs cloneon-disk and end with a port-forward stuck
    /// on `127.0.0.1`, which is the single most confusing failure mode
    /// in cocker today. Erroring early with the exact fix command in
    /// the message turns a 30 min debugging session into a 10 s
    /// helper-install. The threshold (252) leaves a 4-lease cushion
    /// for whatever else macOS hands out while we're checking.
    static func preflightLeasePoolOrThrow() throws {
        let count = leasePoolCount()
        guard count >= 252 else { return }
        if leasePoolHelperInstalled() {
            // Helper present : the watchdog / runPreflight path will
            // touch the trigger and clear it in <2 s. Don't block.
            return
        }
        throw CockerError.internalError(
            "macOS DHCP pool saturated (\(count)/256). New containers can't get an IP. " +
            "Fix once and forever : `cocker daemon helper-install` (one sudo prompt, then forget). " +
            "Or one-shot : `cocker daemon clear-leases`."
        )
    }

    static func deriveNATMAC(from containerID: String) -> String {
        var hex = containerID.filter { $0.isHexDigit }
        while hex.count < 8 { hex += "0" }
        let bytes = Array(hex.prefix(8))
        return "02:cc:" + stride(from: 0, to: 8, by: 2).map { i in
            String(bytes[i...i+1])
        }.joined(separator: ":")
    }

    /// Look up `mac` in macOS's vmnet bootp lease file. Returns the most
    /// recent IPv4 address handed out to that MAC, or nil if no entry
    /// matches. Used as a fallback when `/cocker-ip` polling times out
    /// because udhcpc inside the container raced and lost.
    static func lookupLeasedIP(forMAC mac: String) -> String? {
        // /var/db/dhcpd_leases is the canonical lease file vmnet/bootpd
        // writes for shared/NAT networks. macOS keys entries by
        // `hw_address=1,xx:xx:xx:xx:xx:xx` (the "1" is the ethernet type).
        guard let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else {
            return nil
        }
        // Normalize MACs : drop leading zeros per octet so "02:cc:01:02:03:04"
        // matches "2:cc:1:2:3:4" (vmnet writes the short form).
        func normalize(_ s: String) -> String {
            s.split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }
             .joined(separator: ":")
        }
        let target = normalize(mac).lowercased()
        var currentIP: String? = nil
        var matchedIP: String? = nil
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ip_address=") {
                currentIP = String(trimmed.dropFirst("ip_address=".count))
            } else if trimmed.hasPrefix("hw_address=") {
                let val = trimmed.dropFirst("hw_address=".count)
                // Strip the "1," ethernet-type prefix.
                let macPart = val.split(separator: ",").last.map(String.init) ?? String(val)
                if normalize(macPart).lowercased() == target {
                    matchedIP = currentIP
                    // Don't break — last entry wins (newest lease).
                }
            }
        }
        return matchedIP
    }
}

