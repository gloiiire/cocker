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
    private var portForwardTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
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
                        CockerLog.shared.debug("eng", "auto-restarted \(c.id) (policy=\(c.restartPolicy))")
                    } catch {
                        CockerLog.shared.error("eng", "auto-restart failed for \(c.id): \(error)")
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

        CockerLog.shared.debug("eng", "run() image=\(config.image)")
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
            CockerLog.shared.debug("eng", "image not present, pulling")
        }
        CockerLog.shared.debug("eng", "image exists")

        // Generate container ID and name (12 chars lowercase, matches state lookup)
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        CockerLog.shared.debug("eng", "id=\(id)")
        let generatedName = await state.generateName()
        let name = config.name ?? generatedName
        CockerLog.shared.debug("eng", "name=\(name)")

        guard !(await state.nameExists(name)) else {
            throw CockerError.containerAlreadyExists(name)
        }
        CockerLog.shared.debug("eng", "name unique check OK")

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
        //   - an explicit `entrypoint:` / `Entrypoint` replaces the image's
        //     (and, per Docker, an empty one clears it entirely)
        let imageInfo = try? await images.find(config.image)
        var resolvedCommand = config.command
        if let override = config.entrypoint {
            resolvedCommand = override + resolvedCommand
        } else if let entrypoint = imageInfo?.entrypoint, !entrypoint.isEmpty {
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
        // The four flags PRO-123 had to label as ignored. Persisted on the
        // container so a restart keeps them, like tty and shmSize.
        container.readOnlyRootfs = config.readOnly ? true : nil
        container.tmpfsMounts = config.tmpfsMounts.isEmpty ? nil : config.tmpfsMounts
        container.addHosts = config.addHosts.isEmpty ? nil : config.addHosts
        container.dnsServers = config.dnsServers.isEmpty ? nil : config.dnsServers
        container.dnsSearch = config.dnsSearch.isEmpty ? nil : config.dnsSearch
        // `run -it` : remembered on the container so the spec written at
        // start time asks init for a controlling terminal, and so a restart
        // keeps it.
        container.tty = config.tty
        container.ttyRows = config.rows
        container.ttyCols = config.cols
        if let workdir = resolvedWorkdir { container.env["WORKDIR"] = workdir }

        CockerLog.shared.debug("eng", "container struct created")
        // Allocate IP
        container.ip = await networks.allocateIP(for: id)
        CockerLog.shared.debug("eng", "ipv4=\(container.ip ?? "?")")
        // Allocate IP+MAC on the cocker L2 switch (inter-container fabric)
        let (cIP, cMAC) = try await networks.allocateCockerIPAndMAC(for: id)
        container.cockerIP = cIP
        container.cockerMAC = cMAC
        CockerLog.shared.debug("eng", "cocker switch ip=\(cIP) mac=\(cMAC)")

        // eth0 address, when we assign it ourselves rather than asking
        // vmnet's DHCP server. Allocated here — before the VM exists — so it
        // lands in persisted state, which is what the allocator reads to
        // know what is taken. See docs/DESIGN-network-without-vmnet.md.
        if Self.staticNATEnabled, container.networkMode != .none {
            let gateway = DNSServer.hostIP()
            container.natIP = try await networks.allocateNATIP(for: id, gateway: gateway)
            CockerLog.shared.debug("eng", "eth0 static ip=\(container.natIP ?? "?")")
        }
        // eth0 MAC is filled in after VM start (VZ picks it during config).
        // We use it later to look up the matching lease in
        // /var/db/dhcpd_leases when /cocker-ip polling times out.
        container.natMAC = nil
        try await state.store(container: container)
        CockerLog.shared.debug("eng", "state stored")
        emitEvent("container", action: "create", id: id)
        CockerLog.shared.debug("eng", "event emitted")

        // Start VM
        // Overlay rootfs : clone le rootfs de l'image vers un dossier propre
        // au container via APFS clonefile. Garantit l'isolation fs entre
        // containers de la même image (sinon ils écrivent dans le même rootfs
        // partagé — bug du PoC initial visible sur compose db+web).
        CockerLog.shared.debug("eng", "cloning rootfs (APFS copy-on-write)")
        // S'assure que l'image a un rootfs extrait (pull-on-demand)
        _ = try await images.rootfsPath(for: config.image)
        let rootfsPath = try await images.cloneRootfs(for: config.image, containerID: id)
        CockerLog.shared.debug("eng", "container rootfs=\(rootfsPath.path)")
        CockerLog.shared.debug("eng", "calling vmRuntime.start")
        try await vmRuntime.start(container: container, rootfsPath: rootfsPath)
        CockerLog.shared.debug("eng", "vmRuntime.start returned")
        // Drain the eth0 MAC VZ generated during createVM and persist it so
        // the IP-discovery task below can use it for /var/db/dhcpd_leases
        // fallback when the in-VM /cocker-ip write loses the race.
        if let mac = vmRuntime.takeNATMAC(forContainer: id) {
            container.natMAC = mac
            try? await state.updateContainer(id: id) { c in c.natMAC = mac }
            CockerLog.shared.debug("eng", "nat MAC=\(mac)")
        }

        // Update status
        try await state.updateContainer(id: id) { c in
            c.status = .running
            c.startedAt = Date()
        }

        // Record network membership. NOT via `connect`: the container is
        // already live here, and `connect` refuses a live container because
        // its switch port cannot be re-keyed. The port is being wired with
        // this network right now, so the membership is simply a fact to
        // record. The old `try? connect` swallowed the refusal, which is why
        // `network inspect <net>` never listed containers started with
        // `--network <net>`.
        if let networkName = config.network {
            do {
                try await networks.recordMembershipAtCreate(
                    containerID: id, networkID: networkName)
            } catch {
                CockerLog.shared.warn("eng",
                    "could not record \(id) as a member of \(networkName): \(error)")
            }
        }

        // Démarre le port forwarding TCP (host port → container IP:port)
        // via le PortForwarder Swift. NAT vmnet est outbound-only sans ça.
        //
        // cocker-init écrit l'IP DHCP réelle du container dans /cocker-ip
        // du rootfs (visible via virtiofs côté host). On poll ce fichier
        // pour récupérer l'IP — placeholder "127.0.0.1" si non dispo.
        schedulePortForwarding(container: container, rootfsPath: rootfsPath)

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
    /// Shared ISO-8601 formatter for the audit log + healthcheck logs. Used
    /// to be created per event (audit log) or per replayed log line (the JSON
    /// log reader) — each `ISO8601DateFormatter()` allocation costs hundreds
    /// of microseconds, and a `cocker logs --tail 10000` call did 10 000 of
    /// them. Cache once at the type level.
    static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

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
            // **B11 fix** : earlier code unconditionally slept for `interval`
            // then *also* skipped the probe when nextProbeAllowedAt hadn't
            // elapsed — so a 30 s interval + 5 s restart-grace produced a
            // first post-restart probe at 30 s instead of 5 s, breaking
            // any tooling that expects healthy within the start period.
            // We now sleep at most until whichever deadline is closer.
            let now = Date()
            let intervalDeadline = now.addingTimeInterval(spec.interval)
            let nextDeadline = max(intervalDeadline, nextProbeAllowedAt)
            let sleepFor = max(0, nextDeadline.timeIntervalSince(now))
            try? await Task.sleep(nanoseconds: UInt64(sleepFor * 1_000_000_000))
            // Re-check status post-sleep : the sleep window is enough
            // for `cocker stop`/`pause` to land. Don't probe a dead VM.
            guard await state.container(id: containerID)?.status == .running else { continue }
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
            // `.coalesced` : probe history is the hottest write path in the
            // daemon (one append per probe per container) and losing <1 s
            // of it on a crash is harmless — reconcileAfterRestart resets
            // health bookkeeping anyway. Don't pay a full state.json
            // rewrite for it.
            try? await state.updateContainer(id: containerID, durability: .coalesced) { c in
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
                try? await state.updateContainer(id: containerID, durability: .coalesced) { c in c.healthFailingStreak = 0 }
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
                try? await state.updateContainer(id: containerID, durability: .coalesced) { c in
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
            CockerLog.shared.error("health", "couldn't write \(cmdFile.path): \(error)")
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
            // **I3** : `String(decoding:as:)` already replaces invalid
            // sequences with U+FFFD ; the `?? String(data:encoding:.utf8)`
            // fallback was redundant.
            let raw = String(decoding: data, as: UTF8.self)
            // First line = decimal exit code, rest = captured output.
            guard let nl = raw.firstIndex(of: "\n") else { continue }
            let codeStr = String(raw[..<nl]).trimmingCharacters(in: .whitespaces)
            guard let code = Int32(codeStr) else { continue }
            // Strip NUL bytes : JSONEncoder writes them as  which some
            // Docker template parsers reject. Replace with a single space.
            let output = String(raw[raw.index(after: nl)...])
                .replacingOccurrences(of: "\u{0}", with: " ")
            try? FileManager.default.removeItem(at: resultFile)
            CockerLog.shared.debug("health", "cmd \(containerID) seq=\(seq) → exit \(code)")
            return ProbeResult(exitCode: code, output: output)
        }
        try? FileManager.default.removeItem(at: cmdFile)
        CockerLog.shared.debug("health", "cmd \(containerID) seq=\(seq) → daemon-side timeout after \(Int(timeout))s")
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
        // The previous VM's DHCP result lives on the persistent rootfs. Remove
        // it before boot so the new forwarder cannot bind to a stale address.
        try? FileManager.default.removeItem(at: rootfsPath.appendingPathComponent("cocker-ip"))
        try? await state.updateContainer(id: canonicalID) { $0.ip = nil }
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
        schedulePortForwarding(container: container, rootfsPath: rootfsPath)
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
        portForwardTasks.removeValue(forKey: container.id)?.task.cancel()
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
        // **S6 fix** : the signal name comes from a CLI client over the IPC
        // socket, which then traverses the vsock boundary into the
        // attacker-controllable container. Reject anything we can't map to
        // a known POSIX signal here so a malformed payload never reaches
        // exec_listener.c's parser.
        guard ContainerEngine.numericSignal(signal) != nil else {
            throw CockerError.internalError(
                "unknown signal: \(signal). Accepted: SIGHUP, SIGINT, SIGQUIT, " +
                "SIGKILL, SIGTERM, SIGUSR1, SIGUSR2, … (or 1–31)")
        }
        // Honour the requested signal : prior code dropped it on the floor and
        // always hit the SIGKILL fallback path. With timeout=0 the stop loop
        // still delivers phase-1 (in-VM signal relay over vsock) before the
        // forced VZ stop kicks in, so `cocker kill -s SIGUSR1` actually fires
        // SIGUSR1 at PID 1's main child.
        let detected = try? await vmRuntime.stop(
            containerID: container.id, timeout: 0, stopSignal: signal
        )
        portForwardTasks.removeValue(forKey: container.id)?.task.cancel()
        await portForwarder.stop(containerID: container.id)
        // Docker maps a signal-terminated container to exit code 128 + signum.
        // If we observed an explicit exit code on the wire prefer it, otherwise
        // synthesize the conventional value from the signal name.
        let synthesizedExit = ContainerEngine.exitCode(forSignal: signal)
        let finalExit: Int32 = detected.flatMap { $0 } ?? synthesizedExit
        try await state.updateContainer(id: id) { c in
            c.status = .dead
            c.finishedAt = Date()
            c.exitCode = finalExit
        }
        emitEvent("container", action: "kill", id: container.id)
    }

    /// Docker convention : a process killed by signal N exits with code 128+N.
    /// We accept either the symbolic name (`"SIGKILL"`, `"KILL"`, `"15"`) or a
    /// bare decimal. Falls back to 137 (SIGKILL) on anything we can't parse —
    /// caller already validated the signal upstream via `sanitizedSignal`.
    static func exitCode(forSignal signal: String) -> Int32 {
        let n = numericSignal(signal) ?? 9   // default: SIGKILL
        return 128 + Int32(n)
    }

    /// Map `SIGKILL` / `KILL` / `9` to the POSIX signal number, validating
    /// against a fixed whitelist. nil means "unknown" — callers should refuse
    /// the request rather than guess. Used both by `kill()` for the exit-code
    /// translation and by `VMRuntime.sendStopSignal` to validate before the
    /// JSON crosses the vsock boundary.
    static func numericSignal(_ s: String) -> Int? {
        let upper = s.uppercased()
        switch upper {
        case "SIGHUP", "HUP":       return 1
        case "SIGINT", "INT":       return 2
        case "SIGQUIT", "QUIT":     return 3
        case "SIGILL", "ILL":       return 4
        case "SIGABRT", "ABRT":     return 6
        case "SIGBUS", "BUS":       return 7
        case "SIGFPE", "FPE":       return 8
        case "SIGKILL", "KILL":     return 9
        case "SIGUSR1", "USR1":     return 10
        case "SIGSEGV", "SEGV":     return 11
        case "SIGUSR2", "USR2":     return 12
        case "SIGPIPE", "PIPE":     return 13
        case "SIGALRM", "ALRM":     return 14
        case "SIGTERM", "TERM":     return 15
        case "SIGSTOP", "STOP":     return 17
        case "SIGTSTP", "TSTP":     return 18
        case "SIGCONT", "CONT":     return 19
        case "SIGCHLD", "CHLD":     return 20
        case "SIGWINCH", "WINCH":   return 28
        default:
            if let raw = Int(s), raw > 0, raw < 32 { return raw }
            return nil
        }
    }

    func restart(id: String, timeout: TimeInterval = 10) async throws {
        // Resolve once so the emitted event carries the canonical id, not
        // whatever CLI alias (name / 4-char prefix) the caller used.
        let canonical = await state.container(id: id)?.id ?? id
        try await stop(id: canonical, timeout: timeout)
        try await start(id: canonical)
        emitEvent("container", action: "restart", id: canonical)
    }

    private func schedulePortForwarding(container: Container, rootfsPath: URL) {
        let id = container.id
        let ports = container.ports
        portForwardTasks.removeValue(forKey: id)?.task.cancel()
        guard !ports.isEmpty else { return }
        let natMAC = container.natMAC
        let taskID = UUID()
        let task = Task { [weak self, rootfsPath, ports, id, natMAC, taskID] in
            guard let self else { return }
            let ipFile = rootfsPath.appendingPathComponent("cocker-ip")
            var realIP: String?
            for _ in 0..<150 {
                if Task.isCancelled { return }
                if FileManager.default.fileExists(atPath: ipFile.path),
                   let data = try? Data(contentsOf: ipFile),
                   let ip = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                   !ip.isEmpty {
                    realIP = ip
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if Task.isCancelled { return }
            if realIP == nil, let mac = natMAC {
                realIP = ContainerEngine.lookupLeasedIP(forMAC: mac)
            }
            guard let finalIP = realIP else {
                CockerLog.shared.error("portfwd",
                    "container \(id) has no DHCP IP; refusing unsafe 127.0.0.1 fallback")
                return
            }
            try? await self.state.updateContainer(id: id) { $0.ip = finalIP }
            if Task.isCancelled { return }
            await self.activatePortForwarding(
                taskID: taskID, containerID: id,
                containerIP: finalIP, mappings: ports)
        }
        portForwardTasks[id] = (taskID, task)
    }

    private func activatePortForwarding(
        taskID: UUID, containerID: String, containerIP: String,
        mappings: [PortMapping]
    ) async {
        guard portForwardTasks[containerID]?.id == taskID else { return }
        await portForwarder.start(
            containerID: containerID, containerIP: containerIP, mappings: mappings)
        if portForwardTasks[containerID]?.id == taskID {
            portForwardTasks.removeValue(forKey: containerID)
        }
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

    func remove(id: String, force: Bool = false, removeVolumes: Bool = false) async throws {
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
        portForwardTasks.removeValue(forKey: container.id)?.task.cancel()
        await portForwarder.stop(containerID: container.id)
        // Supprime aussi le rootfs cloné du container (libère l'espace
        // disque pris par les modifications post-clonefile).
        try? await images.removeContainerRootfs(containerID: container.id)
        try await state.removeContainer(id: container.id)
        // Free the addresses. The persisted container is the durable record,
        // so removing it is what actually returns them to the pool — this
        // clears the in-flight cache, which would otherwise keep shrinking
        // the usable range for the lifetime of the daemon.
        await networks.releaseAddresses(for: container.id)
        // `rm -v` : drop the volumes cocker invented for this container. The
        // flag was parsed and never acted on, so anonymous volumes accumulated
        // on disk forever with no way to reclaim them by name.
        //
        // Only anonymous ones, and only when nothing else references them —
        // a named volume outliving its container is the entire point of
        // naming it. Removal happens after the container is out of the store
        // so the in-use check below doesn't see the container we just removed.
        if removeVolumes {
            await removeAnonymousVolumes(of: container)
        }
        emitEvent("container", action: "destroy", id: container.id)
    }

    /// Best-effort cleanup of a removed container's anonymous volumes.
    /// A volume still referenced by another container is left alone, and a
    /// single failure never fails the `rm` — the container is already gone.
    private func removeAnonymousVolumes(of container: Container) async {
        let survivors = await state.allContainers(includeAll: true)
        for mount in container.volumes {
            // Bind mounts are host paths, not managed volumes.
            if mount.source.hasPrefix("/") { continue }
            guard let volume = await volumes.info(mount.source), volume.isAnonymous else { continue }
            let stillUsed = survivors.contains { other in
                other.volumes.contains { $0.source == mount.source }
            }
            if stillUsed { continue }
            do {
                try await volumes.remove(mount.source)
                emitEvent("volume", action: "destroy", id: mount.source)
            } catch {
                CockerLog.shared.warn("eng",
                    "rm -v: could not remove anonymous volume \(mount.source): \(error)")
            }
        }
    }

    // MARK: - Query

    func list(all: Bool = false, filter: [String: String] = [:]) async -> [Container] {
        var containers = await state.allContainers(includeAll: all)

        for (key, value) in filter {
            switch key {
            case "status":
                // Accept both vocabularies : cocker's state machine says
                // `stopped` where Docker says `exited`, and users type the
                // Docker one.
                containers = containers.filter {
                    $0.status.rawValue == value || DockerFilters.dockerStatusName($0.status) == value
                }
            case "name": containers = containers.filter { $0.name.contains(value) }
            case "image": containers = containers.filter { $0.image.contains(value) }
            case "label":
                // `label=key=value` (exact) or `label=key` (presence). The
                // presence form used to be dropped, so `--filter label=foo`
                // silently returned every container.
                let kv = value.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    containers = containers.filter { $0.labels[String(kv[0])] == String(kv[1]) }
                } else {
                    containers = containers.filter { $0.labels[value] != nil }
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
        // Subscribe BEFORE returning the stream. VMRuntime and this engine
        // share MainActor isolation, so no log can land between the final
        // backlog snapshot and continuation registration without one of
        // the two actor-isolated operations seeing it.
        let live = follow ? vmRuntime.liveLogs(containerID: containerID) : nil

        return AsyncStream { continuation in
            Task { @MainActor in
                for event in historical {
                    continuation.yield(event)
                }

                if !follow {
                    continuation.finish()
                    return
                }

                guard let live else {
                    continuation.finish()
                    return
                }
                // Event-driven follow : appendLog yields each console event
                // directly. No permanent 100 ms timer per client, no O(M)
                // MainActor churn for M attached log followers.
                for await event in live {
                    continuation.yield(event)
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
        // Docker's `exec` runs inside the container's environment. Ours passed
        // only what the caller supplied with `-e`, so
        // `cocker exec c sh -c 'echo $DATABASE_URL'` printed nothing even
        // though the variable was right there in the running container — and
        // anything the image's ENV or compose's `environment:` set was
        // invisible to every exec'd command.
        //
        // Caller-supplied values still win, which is what `-e` is for.
        var env = container.env
        for (key, value) in config.env { env[key] = value }

        return try await vmRuntime.exec(
            containerID: container.id, command: config.command, env: env,
            tty: config.tty, stdin: config.stdin,
            workdir: config.workdir, user: config.user,
            sessionID: config.sessionID, rows: config.rows, cols: config.cols)
    }

    /// Route a chunk of live stdin (or its EOF) into an in-flight exec.
    func execInput(_ req: ExecInputRequest) async {
        if req.isContainerStdin == true {
            // `run -it` / `attach` : straight to the container's console,
            // which init has made the main process's controlling terminal.
            //
            // Resolve first. `run -it` sends the id it just got back, but
            // `attach` sends whatever the user typed — a name or a short id —
            // and the console pipes are keyed by canonical id. Skipping this
            // made `cocker attach <name>` hang with every keystroke going
            // nowhere.
            let canonical = await state.container(id: req.sessionID)?.id ?? req.sessionID
            if let data = req.data, !data.isEmpty {
                vmRuntime.writeContainerInput(containerID: canonical, data: data)
            }
            if req.eof { vmRuntime.closeContainerInput(containerID: canonical) }
            return
        }
        if let data = req.data, !data.isEmpty {
            vmRuntime.writeExecInput(session: req.sessionID, data: data)
        }
        if req.eof { vmRuntime.closeExecInput(session: req.sessionID) }
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
        // **B18 fix** : `eventStream()` is @MainActor-isolated (the whole
        // class is), so the AsyncStream build closure runs on MainActor too —
        // no Task hop needed for the insertion, which used to leave a small
        // window where yields landed on a not-yet-registered continuation.
        return AsyncStream { continuation in
            self.eventContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                // The termination callback runs from arbitrary context (the
                // consumer's iterator going out of scope, a Task cancel) so
                // we still need to hop to MainActor for the dict removal.
                Task { @MainActor in
                    self?.eventContinuations.removeValue(forKey: id)
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

    /// Thin shim around `AuditLog.write` for legacy call sites. New code
    /// should use `AuditLog` directly. The actual write+rotation+perms
    /// logic now lives in `Engine/AuditLog.swift`.
    private static func writeAuditLog(type: String, action: String, id: String) {
        AuditLog.write(type: type, action: action, id: id)
    }

    // MARK: - Exit-code publication

    /// How many finished containers keep a readable exit code after their
    /// state entry is gone. Only `--rm` containers ever need this, and a
    /// caller that hasn't asked within 128 exits has lost interest.
    private static let recentExitCapacity = 128

    /// Callers parked in `wait(id:)`, keyed by canonical container id.
    /// Resolved by the watcher at the instant the container reaches a
    /// terminal state — before `--rm` removes it from the state store.
    private var exitWaiters: [String: [CheckedContinuation<Int32, Never>]] = [:]

    /// Bounded FIFO of recently-observed exit codes. This is what lets
    /// `cocker run --rm alpine false` still report 1 : by the time the CLI
    /// asks, the container no longer exists anywhere else.
    private var recentExits: [(id: String, code: Int32)] = []

    /// Record a terminal exit and wake everyone waiting on it.
    private func publishExit(id: String, code: Int32) {
        recentExits.append((id: id, code: code))
        if recentExits.count > Self.recentExitCapacity {
            recentExits.removeFirst(recentExits.count - Self.recentExitCapacity)
        }
        for waiter in exitWaiters.removeValue(forKey: id) ?? [] {
            waiter.resume(returning: code)
        }
    }

    private func recentExit(for id: String) -> Int32? {
        recentExits.last(where: { $0.id == id })?.code
    }

    /// Block until `id` reaches a terminal state, then return its exit code.
    /// Backs both `cocker run` in the foreground and `GET /containers/{id}/wait`.
    ///
    /// Returns immediately for a container that has already finished,
    /// including one `--rm` has since removed (see `recentExits`).
    func wait(id: String) async throws -> Int32 {
        guard let container = await state.container(id: id) else {
            // Already reaped by `--rm`. The watcher stashed the code on its
            // way out ; anything older than that is genuinely unknown.
            if let code = recentExit(for: id) { return code }
            throw CockerError.containerNotFound(id)
        }
        // Terminal already — no need to park.
        if container.status == .stopped || container.status == .dead {
            return container.exitCode ?? 0
        }
        let cid = container.id
        // Everything below runs without an await until the continuation is
        // registered, and `publishExit` is @MainActor too — so the watcher
        // cannot slip an exit past us between this check and the parking.
        if let code = recentExit(for: cid) { return code }
        return await withCheckedContinuation { cont in
            exitWaiters[cid, default: []].append(cont)
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
                                CockerLog.shared.error("eng", "restart failed: \(error)")
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
                // Publish the code *before* `--rm` drops the container, so
                // `cocker run` / `docker wait` can still read it. Racing an
                // inspect against removal is what made `cocker run --rm img
                // false` report success.
                publishExit(id: id, code: exitCode)
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
                CockerLog.shared.error("gc", "skip \(img.reference): \(error)")
            }
        }
        return pruned
    }

    // MARK: - DHCP recovery helpers (shims around LeasePoolMonitor)

    /// **A1 refactor** : the underlying logic lives in
    /// `LeasePoolMonitor` now. These static methods are kept as thin
    /// shims so existing call sites (and tests) don't need to change.
    /// New code should call `LeasePoolMonitor` directly.

    /// True when containers configure `eth0` themselves instead of asking
    /// vmnet's bootpd for a lease — in which case the host lease pool is
    /// irrelevant and must not gate anything.
    ///
    /// **On by default.** macOS's lease pool is host-wide, capped at ~256
    /// entries, never reclaimed and `root:wheel`, so a machine that has
    /// started 256 containers stops working until somebody with root
    /// truncates a file. Leaving DHCP as the default meant shipping that
    /// ceiling, and shipping a daemon that needs root to recover from it.
    ///
    /// Set `COCKER_STATIC_ETH0=0` to go back to DHCP. That path is intact
    /// and still the fallback inside the guest when no address is supplied —
    /// worth keeping for a host where something else owns the subnet and
    /// self-assignment would collide.
    ///
    /// See `docs/DESIGN-network-without-vmnet.md` for the measurements.
    ///
    /// The switch itself lives in `CockerEnv` so the CLI reads the same answer
    /// — when it was a string literal here, `cocker daemon status` couldn't
    /// consult it and kept printing a lease gauge for a pool nothing uses.
    static var staticNATEnabled: Bool {
        CockerEnv.staticETH0Enabled
    }

    static func maybeTriggerLeasePoolClear() {
        guard !staticNATEnabled else { return }
        LeasePoolMonitor.maybeTriggerClear()
    }

    static func leasePoolCount() -> Int {
        LeasePoolMonitor.count()
    }

    static func leasePoolHelperInstalled() -> Bool {
        LeasePoolMonitor.helperInstalled()
    }

    static func preflightLeasePoolOrThrow() throws {
        // Refusing a run because a lease pool is full makes no sense when
        // the container is not going to ask for a lease.
        guard !staticNATEnabled else { return }
        try LeasePoolMonitor.preflightOrThrow()
    }

    static func deriveNATMAC(from containerID: String) -> String {
        LeasePoolMonitor.deriveNATMAC(from: containerID)
    }

    static func lookupLeasedIP(forMAC mac: String) -> String? {
        LeasePoolMonitor.lookupLeasedIP(forMAC: mac)
    }
}
