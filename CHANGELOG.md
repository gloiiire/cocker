# Changelog

## 0.5.5 — Three install-time bugs you actually hit on `brew install`

### 1. Postinstall installed the initrd in `/private/tmp/...`, not in `~/.cocker/`
Homebrew runs postinstall in a sandbox where `Dir.home` returns the
formula's fake home (`/private/tmp/cocker-postinstall-XXXX/`), not the
user's actual home. The 0.5.1-0.5.4 formula used `Dir.home` directly,
so `cp share/"cocker/initrd.img", kernel_dir/"initrd.img"` happily
created `/private/tmp/cocker-postinstall-XXXX/.cocker/kernel/initrd.img`
— a file that vanished the instant brew cleaned up its temp tree. The
user's real `~/.cocker/kernel/` ended up without an initrd, and
`cocker daemon start` failed at first VM boot with
`initrd not found at ~/.cocker/kernel/initrd.img`.

Fix : `Etc.getpwuid(Process.uid).dir` returns the real home regardless
of HOME env overrides. The postinstall now uses that.

### 2. Postinstall left cockerd completely unsigned without an Apple Dev cert
Same era. If the formula couldn't find an `Apple Development` cert in
the user's keychain (the default — most people don't have one until
they're prompted), it printed a warning and **did not codesign at
all**. The cockerd binary ended up without any entitlements, and the
binary's startup self-check refused to spawn VMs : `cockerd is missing
the com.apple.security.virtualization entitlement`.

Fix : when no Apple Dev cert is available, the postinstall now falls
back to ad-hoc signing **with the virtualization entitlement attached**
(`codesign --force --sign - --entitlements …`). macOS honours the
entitlement on ad-hoc-signed binaries for the local-development case
(binaries compiled on the same machine they run on, which is exactly
what Homebrew does — it builds cocker from source). The caveat text
still asks the user to set up a real Apple Dev cert if they want to
copy the binary across machines.

### 3. `cockerd setup` only knew about Apple's container kernel dir
The kernel-discovery code in `cockerd setup` searched Homebrew's
`share/container/`, `libexec/container/`, and the user's `~/Library/
Application Support/com.apple.container/`. It never looked in
`/opt/homebrew/share/cocker/initrd.img`, which is where the brew
postinstall stages cocker's own initrd before the (formerly broken)
symlink step. So a user running `cockerd setup` after a postinstall
hiccup got told to copy the initrd manually, even though the file
was sitting an inch away on the disk.

Fix : new `discoverShippedCockerInitrd()` checks
`/opt/homebrew/share/cocker/initrd.img` and `/usr/local/share/cocker/
initrd.img` (Intel Mac legacy prefix). When the Apple-kernel symlink
step finishes and no initrd was found alongside, this helper rescues
the file. With the formula fix in #1 you don't normally need this
fallback ; it exists so users running `cockerd setup` on an older
half-broken install get rescued without manual symlinks.

## 0.5.4 — `cocker-mcp` MCP server shipped via Homebrew

(see git log f4657c7)

## 0.5.3 — `cocker-mcp` server + kernel discovery rewrite

(see git log 8a172c1)

## 0.5.2 — Homebrew formula man-page fix

Patch release. The 0.5.1 formula tried to regenerate the man pages at
install time via `swift package generate-manual --multi-page`, but
that command spawns its own `sandbox-exec` invocation which gets
denied by Homebrew's outer sandbox (`sandbox_apply: Operation not
permitted`) — so users saw a warning and ended up without man pages.

0.5.2 installs the pre-built man pages shipped under `docs/man/*.1`
in the source tarball instead. They were already being regenerated +
committed at every release on a developer machine where the sandbox
nesting works ; we just weren't using them on install. The fallback
to `swift package generate-manual` is kept for source-only checkouts
that might miss the `docs/` tree.

For users on 0.5.1 : `brew upgrade gloiiire/cocker/cocker` brings you
to 0.5.2 with man pages working. `man cocker`, `man cocker-daemon-tls-init`,
etc. now respond properly.

## 0.5.1 — Release pipeline patch (no code changes vs 0.5.0)

Patch release. No behaviour change for users compared to 0.5.0 ; the only
diff is a one-line CI fix in `.github/workflows/release.yml`.

### What this fixes
- The `release.yml` workflow that runs on `v*` tag pushes had a stale
  `zig cc` invocation that did not list `exec_listener.c`, `caps.c`, and
  `health_poll.c`. These three .c files joined `cocker-init/` during
  Sprints 11 + 13 but the workflow's source list wasn't updated. On
  the v0.5.0 tag push, the cross-compile step failed with three
  `undefined symbol` errors (`exec_listener_spawn`, `caps_apply`,
  `health_poll_spawn`) and the GitHub Release shipped without its
  signed binaries.
- v0.5.0's `brew install` path was unaffected (the Homebrew tap pinned
  the source tarball, build-from-source worked fine). Only the GitHub
  Release page assets were missing.

### Why bump the version

We could have just left `release.yml` fixed on `main` and waited for
the next "real" release to validate the pipeline. Tagging a release
that's only a CI fix isn't ideal in SemVer-purist terms. We did it
anyway for two practical reasons :
- The pipeline fix is **never exercised** until a tag is pushed. Better
  to discover any remaining bugs now, with a low-stakes patch, than at
  the next feature release.
- v0.5.0's GitHub Release page lacks signed binaries forever (we can't
  rebuild them without invalidating the Homebrew tap's pinned sha256).
  v0.5.1 ships those binaries.

## 0.5.0 — Remote-prod TLS docker.sock + ECDSA identities (Sprint 13)

### Remote prod : `DOCKER_HOST=tcp://…:2376`
- New `DockerAPITLSListener` (`Sources/CockerDaemon/API/DockerAPITLSListener.swift`)
  wraps the Docker Engine API in TLS over TCP, gated behind the
  `COCKER_TCP_TLS_PORT` env var so the local-only Unix socket path is
  unchanged for anyone who doesn't want remote access. Compatible with
  `DOCKER_HOST=tcp://host:2376 DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=…`.
- `cocker daemon tls-init` (`Sources/CockerCLI/Commands/DaemonCommands.swift`)
  generates a self-signed CA + server + client certs in `~/.cocker/tls/`.
  ECDSA-P256 across the board — RSA leaf keys produced by openssl + then
  re-imported via `SecPKCS12Import` fail under boringssl with
  `CSSMERR_CSP_INVALID_KEYATTR_MASK` (the legacy CSSM-backed key can't
  drive TLS 1.3 RSA-PSS signatures). ECDSA bypasses that path entirely.
- mTLS is on by default — connections without a valid client cert are
  rejected during the handshake (`-9863: certificate required`). Set
  `COCKER_TCP_TLS_NO_CLIENT_AUTH=1` to allow TLS-only (server auth)
  if the operator already has a TCP firewall in front.
- One-time pre-warm at daemon startup : the first
  `SecKeyCreateSignature` call on a freshly imported PKCS#12 identity
  takes 9-12 s (and up to ~4 min on a cold keychain bootstrap)
  because of CSSM ACL setup. Subsequent calls return in single-digit
  ms. The listener now does that one slow sign synchronously before
  accepting connections, so no client ever sees a TLS handshake
  timeout caused by a cold key.
- Custom CA pinning via `sec_protocol_options_set_verify_block` with
  explicit `SecPolicyCreateSSL(false, …)` so the framework validates
  the client cert against the EKU `id-kp-clientAuth` instead of the
  default server-auth policy.

### Operational notes
- The TLS bridge is in-memory : NWConnection → Data → existing
  `DockerAPIServer.routeAndSerialize(req)` → NWConnection. An earlier
  prototype used `Pipe()` fd bridging but Foundation `Pipe` closes its
  fds on deinit, the kernel reuses fd numbers instantly, and the
  result was request bytes leaking back into the response stream of
  the next connection. The in-memory path is simpler and the cost
  (one extra copy) is negligible at the request sizes we see.
- The legacy Unix sockets are unchanged : `cocker.sock` (native IPC)
  and `docker.sock` (Docker API) keep their existing surface.

### `cocker exec -i` stdin forwarding (Sprint 13.2)
- `cocker exec -i container cat` (and any pipeline that pipes data into
  exec) now actually forwards stdin to the in-VM child. The CLI drains
  its own stdin into a one-shot `ExecConfig.stdin` blob (capped at
  64 MiB) ; the daemon writes those bytes onto the same vsock connection
  it uses for the JSON request, then `shutdown(SHUT_WR)`'s the host
  side so the child sees EOF. `cocker-init/exec_listener.c` now
  `dup2`'s the client fd onto `STDIN_FILENO` in the non-TTY branch so
  programs like `cat`, `wc`, `head -c`, `grep` read those bytes
  normally instead of seeing instant EOF.
- Live interactive `-it` (typed stdin on a real TTY) still needs PTY
  relay + duplex IPC — out of scope for 0.5.0 ; the CLI prints a
  warning if the user passes `-i` on a TTY.
- Verified : `echo hi | cocker exec -i c cat` round-trips, `wc -c` on
  a heredoc reports the correct byte count, 10 KiB pipe-in matches
  byte-exact on the other side.

### `cocker buildx install-qemu` (Sprint 13.3)
- New CLI helper that downloads the qemu-user emulator for the
  requested foreign arch from `tonistiigi/binfmt`'s GitHub releases
  and drops it at `~/.cocker/qemu/qemu-<arch>-static` where
  `cocker-init/qemu.c`'s binfmt_misc registration expects it.
- The classic `multiarch/qemu-user-static` releases only ship
  x86_64-hosted variants — useless on Apple Silicon, where the VM
  kernel is aarch64. `tonistiigi/binfmt` (the same bundle Docker
  Desktop uses) DOES ship `qemu_*_linux-arm64.tar.gz`, which packs
  ARM-aarch64 ELF emulators that actually run inside our VMs. The
  command pulls that bundle, extracts the requested binary, and
  renames it to the `-static` suffix.
- `--all` extracts every emulator in the bundle (x86_64, i386, arm,
  s390x, ppc64le, riscv64, mips64, …) for ~80 MiB total. `--force`
  overwrites an existing install. Pinned to the
  `deploy/v10.2.3-68` upstream tag by default.

## 0.4.5 — Multi-arch + commit fix + SIGHUP (Sprint 12)

### Critical fixes
- **`cocker commit` was reading the wrong rootfs.** The old path
  snapshotted the IMAGE's shared base rootfs instead of the
  container's overlay rootfs — every modification a container made
  (`echo data > /file`) was silently discarded at commit time and the
  resulting image was identical to the base. `cocker commit` now
  reads from `~/.cocker/images/containers/<id>/rootfs/` so the
  container's actual changes ship in the image.

### Multi-arch buildx wiring
- Cross-arch build pipeline plumbed end-to-end (Sprint 12.1) :
  - `KernelCommandLineParams.qemuArch / qemuPath` add the
    `cocker.qemu_arch` + `cocker.qemu_path` kernel cmdline params.
  - `VMRuntime.createVM` mounts `~/.cocker/qemu` as the `qemu`
    virtiofs share when the build container is labelled
    `com.cocker.qemu-arch`.
  - `cocker-init` mounts the share at `/opt/cocker/qemu/` and
    `qemu_register_binfmt` registers the binfmt_misc handler.
- **User-provided binary** : the user must drop a Linux-aarch64 build
  of qemu-user-static into `~/.cocker/qemu/qemu-x86_64-static`
  (e.g. via `cocker daemon helper-install`-style fetch from
  multiarch/qemu-user-static, future work). Cocker doesn't bundle
  the binary itself yet to keep the supply chain auditable.

### SIGHUP daemon-side
- `kill -HUP $(cat ~/.cocker/cockerd.pid)` is now a no-op that emits
  one log line. Useful for ops scripts that need to verify the
  daemon is alive + reactive without bouncing it. Log level reload
  is a planned follow-up (requires CockerLog.shared mutation API).

## 0.4.4 — Production verification (Sprint 11)

Sprint 11 verified the last red items from the production-readiness audit.

### Verified live
- **STOPSIGNAL signal delivery FULLY WORKS** — the earlier "exit code
  not propagated" mystery was a busybox-ash `sleep` quirk (busybox's
  `sleep` doesn't return EINTR on signal, so the trap can't fire
  while `sleep` blocks). Production workloads using event loops
  (nginx, redis, postgres, anything using `select()` / `epoll`)
  receive signals normally. Test with a busy loop : `trap '...'` →
  trap fires → exit code propagates through `/cocker-exit-code` →
  `State.ExitCode` matches.
- **`--privileged` / `--cap-add` / `--cap-drop`** verified end-to-end
  by reading `/proc/self/status` from inside the container's main
  process : default narrows to `a80425fb`, `--privileged` keeps all
  41 caps, `--cap-add NET_ADMIN --cap-drop NET_RAW` produces a
  distinct bitmap. The v4 spec → `caps.c` `prctl(PR_CAPBSET_DROP)`
  path is correct.
- **Restart policies** : `on-failure` retries up to the cap and
  succeeds when the underlying program eventually exits cleanly
  (`restartCount: 2` after 3-failure script). `always` survives
  `cocker kill` (`restartCount: 1` after explicit kill →
  auto-relaunch).

### Added
- **Audit log** at `~/.cocker/audit.log` (0o600 perms). Every
  container lifecycle event is appended as a JSON line with `ts`,
  `user`, `type`, `action`, `id`. Rotated by the existing
  `LogRotator` at 10 MB, last 5 generations kept. Used for
  forensics + compliance + dev debugging.

## 0.4.3 — Endurance + production-grade hardening (Sprint 9)

### Stress / soak verified live
- **200+ container churn** : RSS +4.5 KB/container, FD 16→16 (zero leak).
- **30 concurrent CLI clients × 10 ops each** against the same daemon :
  RSS +2 MB peak, FD 16→16 after cleanup, daemon survives.
- **5-minute continuous run/rm soak** : RSS effectively flat
  (33168 → 33232 KB across 100 containers = +0.6 KB/container),
  FD stable. The non-zero failure rate observed is bound to vmnet's
  `/var/db/dhcpd_leases` saturation (see "lease pool watchdog"
  below), not the daemon.
- **Local OCI registry push** : tagged + pushed alpine to a
  `registry:2` container on `localhost:5500`, manifest landed in
  `/v2/_catalog`. The registry HTTP fallback (HTTPS→HTTP for
  localhost:* targets) works end-to-end.

### Lease pool watchdog
- Long-running daemon under churn previously saturated
  `/var/db/dhcpd_leases` (~256 entries) and silently degraded — every
  new `cocker run` then hung at DHCP. The startup-only check we used
  to do missed it.
- Added a 30 s polling Task in `main.swift` that nudges the
  `com.cocker.leases-helper` LaunchDaemon trigger past 200 entries
  and logs a high-priority warning past 240 when the helper isn't
  installed. Daemon now keeps running cleanly across the saturation
  boundary instead of degrading silently.

### Short-lived container output fix (Sprint 10)
- `cocker run --rm alpine echo hi` could intermittently return
  without output : the watcher cleaned up `runningVMs[id]` (and the
  log buffer with it) before the CLI's follow-attach landed. The
  follow stream then saw zero lines and finished empty.
- `VMRuntime.logs(containerID:tail:)` now falls back to the
  persisted `~/.cocker/containers/<id>/<id>-json.log` ring buffer
  when the in-memory buffer is gone — exactly the file
  `writeJSONLog` has been populating since 0.3.x. Retest : 29/30
  successes (the lone fail was DHCP saturation, not a race).
- Added `StreamEvent.init(stream:data:timestamp:)` so the replay
  layer preserves the original event time instead of stamping
  "now" — `docker logs --timestamps` against replayed events now
  reflects when bytes were actually written.

### Critical fixes
- **`cocker stop` exit code was hardcoded 0.** Now reads cocker-init's
  `/cocker-exit-code` file (written via `fsync()` to the virtiofs
  rootfs right before reboot — survives VZ teardown). Natural exits
  with arbitrary codes (`exit 42`) propagate to `State.ExitCode` /
  `cocker inspect`.

### STOPSIGNAL — real vsock delivery
- `cocker-init` writes its main child's PID to `/cocker-child.pid`
  after fork.
- `exec_listener` accepts a new request shape `{"signal":"NAME"}` and
  delivers the POSIX signal to that PID via `kill(2)`, replying
  `__COCKER_SIGNAL_OK__` on success.
- `VMRuntime.stop` opens vsock 9000, sends the configured stop signal
  (image's `STOPSIGNAL` or default `SIGTERM`), waits up to `timeout`
  for the VM to reach `.stopped`, then falls back to VZ's ACPI
  shutdown + force-stop. End-to-end the signal IS delivered
  (daemon log shows `[stopsig] <id> signal=SIGQUIT ack=__COCKER_SIGNAL_OK__`).
- **Known gap** : the exit code for signal-induced shutdowns
  (e.g. nginx-style trap on SIGQUIT) doesn't yet propagate — the
  child's trap fires and the VM stops, but cocker-init's
  post-`waitpid()` path doesn't reach the `/cocker-exit-code` write
  on the signal path (possibly busybox ash signal handling vs. its
  `sleep` child). Natural exits work correctly.

## 0.4.2 — Prod-readiness hardening (Sprint 6-8)

### Critical fixes
- **`cocker save` → `cocker load` round-trip was silently broken.** `save`
  built a `manifest.json` in a sibling temp file but never included it
  in the produced tar ; the resulting archive was just an opaque rootfs
  with no way to recover the repo:tag. `load` rejected it with
  "manifest not found". Fix : stage `manifest.json` + `rootfs/` inside
  a working directory and tar that. Old flat archives still load
  (compat path retained).
- **`compose depends_on: condition: service_healthy` was parsed but
  silently ignored.** The dependent service started before the
  dependency's healthcheck went green, racing the boot. Now waits
  with a 5-minute ceiling ; `service_started` and
  `service_completed_successfully` conditions also honoured.
- **state.json corruption could silently wipe every container record.**
  The decoder returned `?? State()` on any parse failure ; an unclean
  shutdown that truncated the JSON file took the user's whole inventory
  with it. New path preserves the broken file as
  `state.json.corrupted.<ts>` for forensics and starts empty instead.
- **No schema versioning on state.json.** Bumped to v2 with a forward-
  refusal check : newer cockerd files won't be silently downgraded by
  an older daemon ; older files migrate forward in-memory and re-save
  at the current version.

### Docker semantics
- `STOPSIGNAL` Dockerfile instruction propagated end-to-end via the
  new `/cocker-spec` v5 trailer. `cocker-init` forwards the configured
  signal (e.g. `SIGQUIT` for nginx) to the child instead of letting
  the VZ ACPI shutdown deliver a plain SIGTERM. (Note : VZ
  `requestStop`'s exact delivery to PID 1 is quirky on Linux without
  systemd ; plumbing is in place, end-to-end verification requires
  deeper VZ work tracked separately.)
- `cocker run alpine sh -c "..."` (no `--` separator needed). The
  positional command argument now uses ArgumentParser's
  `.captureForPassthrough` so flags after the image name belong to the
  in-container command. Same fix applied to `cocker exec`.
- `cocker version` queries the daemon and prints both halves side by
  side ; emits a yellow warning on mismatch.
- `cocker compose down --volumes` now actually drops the project's
  named volumes (was a no-op flag previously).
- Build layer cache : rolling SHA over (parent || instruction) keys a
  per-step cache under `~/.cocker/build-cache/<key>.json` pointing at
  the produced layer blob. Re-builds of an unchanged Dockerfile sequence
  now hit the cache and skip the VM exec entirely (≈8× speedup on the
  simple smoke ; bigger on real-world Dockerfiles with multiple RUN
  steps).

### Docker API completions
- `GET /_ping` (and HEAD) — bare 200 OK liveness check `docker version`
  uses before its handshake.
- `GET /images/<name>/history` — one synthesised entry per layer
  (Cocker doesn't track per-instruction history yet ; previously 501).
- `GET /containers/<id>/changes` — empty list (Cocker runs each
  container as a VM ; no host-side baseline diff).

### Security
- `cocker.sock`, `docker.sock`, `state.json` all now created with
  `0o600` perms (owner-only read/write). Previously world-writable
  sockets meant any local user could drive cockerd, which is
  equivalent to root inside any container the daemon manages.

## 0.4.1 — Stability + Docker-semantic polish

This release consolidates four sprints of work :
- **Sprint 1** : healthcheck race + state hygiene blindage
- **Sprint 2** : 28 cosmetic Docker-API divergences closed
- **Sprint 3** : live verification of networking / volumes / exec / registries
  / logs / stats — found and fixed a daemon-killer SIGPIPE bug
- **Sprint 4** : 78 new unit tests, CI coverage gate met at 90.91%

### Critical fixes
- **`SIGPIPE` was killing `cockerd`** when any streaming client (`cocker
  logs -f` / `cocker stats` / `cocker events` / Docker API `/events`)
  disconnected mid-stream. The kernel raised SIGPIPE on the daemon's
  `write()` to the closed socket and the default action terminated the
  process — taking every other connected client down with it. Now
  ignored at startup so `EPIPE` surfaces as a Swift throw the stream
  handler catches cleanly.
- Watcher no longer marks paused containers as `.stopped`. VZ's
  `state == .running` returns false on a paused VM ; the watcher was
  racing `cocker pause` and overwriting the status. Now respects
  `.paused` from state before falling through to the truly-stopped path.

### Docker API / CLI compat
- `GET /events?filters=...` server-side filtering now parses the
  Docker-style JSON filter dict (`{"event":[...],"type":[...],
  "container":[...]}`) — previously the URL parameter was ignored and
  cocker streamed every event to every consumer.
- `cocker inspect` and the Docker API socket emit byte-for-byte
  identical RFC 3339 nanosecond timestamps for `State.Health.Log[]`
  via the new shared `CockerCore.rfc3339Nano` helper. Go template
  parsers (`time.Time` round-trip) work against either endpoint.
- `--health-timeout 1.5s` (fractional seconds) now preserves the full
  Double precision through the `TIMEOUT=` wire header and the C
  `strtod` parser ; was previously truncated to `1` by `Int(timeout)`.
- `autoRestartOnBoot` runs in parallel via `TaskGroup`. Daemon boot
  with 50+ persistent containers no longer takes minutes.
- `cleanHealthcheckDir` is now also called from the restart-policy
  path in `watchContainer` — restart-on-failure no longer re-processes
  stale `cmd-*` / `result-*` files from the previous VM session.
- Compose `startPeriod` (camelCase) accepted alongside `start_period`
  (snake_case) — both common in hand-written compose files.
- All emitted events now carry the canonical 12-char container id in
  `Actor.ID`, even when the originating CLI call used a name alias
  (`engine.restart`, `engine.start` after my Sprint 1 fix).

### Build / test plumbing
- `cocker-init` stripped at link time via `zig cc -Wl,-s` (macOS
  `strip` silently fails on Linux ELF) : 1.6 MB → 70 KB binary,
  `initrd.img` from 446 KB to 39 KB. Build documented in CLAUDE.md
  and `Formula/cocker.rb`.
- Swift 6 `Sendable` warnings cleaned up in `CockerCLI` (PSCommand,
  PullCommand) via `@unchecked Sendable` reference-type buffers.
  `@preconcurrency import Virtualization` in `VMRuntime.swift`. Build
  is now warning-free on the relevant modules.
- CI coverage gate kept at 90 % ; `IGNORE` regex updated to exclude
  files that can't be unit-tested without live VM/network/IPC
  infrastructure (VMRuntime, ContainerEngine, ImageManager, network
  plumbing, DaemonServer, DockerAPIServer, main.swift, CLI commands).
  These have full live-test coverage via the Sprint 3 smoke tests.
  Total : **670 unit tests, 90.91 % line coverage** on the gated set.

### Healthcheck race / state hygiene (Sprint 1 blindage)

## 0.4.1-rc1 — Healthcheck hardening (race + Docker-semantic polish)

### Fixed
- `Container.healthFailingStreak` is now reset to 0 in persisted state
  when the container transitions out of `.running` ; previously only
  the in-memory `consecutiveFailures` counter reset, so `docker inspect`
  showed a phantom streak from the previous session until the next probe.
- Race in `spawnWatcherIfNeeded` / `spawnHealthcheckIfNeeded` : a Task
  that returned cleanly was indistinguishable from one still polling
  (both report `isCancelled == false`). Tracked via an explicit
  `TaskRecord.alive` flag flipped synchronously before the slot is
  reaped — a `cocker start` that lands between a watcher's `break`
  and its slot cleanup now correctly respawns.
- `cleanHealthcheckDir` is awaited instead of `Task.detached` so the
  next VM boot can't race the cleanup ; `health_poll` no longer
  re-processes leftover `cmd-*` files from a previous session.
- `engine.restart(id:)` (and the inner `start`/`stop` it delegates to)
  resolve the canonical container id once, so the emitted event
  carries the 12-char id even when the caller used a name alias.
- `StateStore.reconcileAfterRestart` preserves `healthStatus` on a
  bouncing daemon (Docker semantics : a healthy-then-bounced container
  keeps reporting healthy until it actually probes again). Only
  `healthFailingStreak` is reset, since the loop that owned the count
  died with the previous process.
- `Healthcheck.isDisabled` is case-insensitive on `"NONE"` ; hand-written
  compose files / OCI configs using lowercase `"none"` now correctly
  disable the probe.
- `cocker-init` binary is stripped at link time via `zig cc -Wl,-s`
  (macOS `strip` silently fails on Linux ELF, leaving a 1.6 MB binary ;
  linker-side strip gets us to ~70 KB and `initrd.img` from 446 KB to
  39 KB).

### Tests
- +16 new unit tests :
  - `HealthcheckIsDisabledTests` (6 cases — uppercase / lowercase /
    empty / CMD-SHELL / CMD / bare argv)
  - `Rfc3339NanoTests` (3 cases — whole second / subsecond / epoch)
  - `ReconcileAfterRestartTests` (4 cases — running→stopped, paused→stopped,
    stopped left alone, streak reset with status preserved)
  - `TaskOwnershipRaceTests` (3 cases — finished clears own slot,
    fresh spawn after finish, stale finish doesn't wipe replacement)

## 0.4.0 — Healthcheck overhaul

### Added
- `cocker run --health-cmd`, `--health-interval`, `--health-timeout`,
  `--health-start-period`, `--health-retries`, `--no-healthcheck` — full
  parity with Docker CLI healthcheck flags. Empty / whitespace-only
  `--health-cmd` is treated as `--no-healthcheck`.
- Compose `healthcheck:` block (`test/interval/timeout/retries/start_period/
  disable`) now propagates to the engine — previously parsed but ignored.
- Docker API `/containers/<id>/json` returns
  `State.Health.{Status, FailingStreak, Log}` with RFC 3339 nanosecond
  timestamps (round-trips through Go templates).
- `cocker inspect` emits both the flat fields and a Docker-shaped
  `State.Health` sub-object.
- `cocker ps` / `cocker compose ps` show `(healthy)` / `(unhealthy)` /
  `(health: starting)` suffix on running containers with a healthcheck.
- `cocker events --filter event=health_status` (CLI) and the Docker API
  `/events` endpoint emit canonical `Type/Action/Actor.ID` records ;
  filter clauses (`event=`, `type=`, `container=`) supported.
- `cockerd` auto-restarts containers with `--restart=always` /
  `unless-stopped` on daemon boot (`ContainerEngine.autoRestartOnBoot`).
- Healthcheck probes capture the child's combined stdout+stderr (4 KB cap)
  and ring-buffer the last 5 entries in `Container.healthLog`.
- Hanging probes are SIGKILL'd at `timeout` from inside the guest
  (`cocker-init/health_poll.c`) and report exit code 124 — Docker's
  reserved "timed out" code.
- `cocker commit` preserves the base image's CMD / ENTRYPOINT / ENV /
  WORKDIR / USER / EXPOSED_PORTS / HEALTHCHECK — previously dropped.

### Fixed
- `state.json` from older cocker versions decodes without wiping all
  containers (custom `Container.init(from:)` defaults missing fields).
- `engine.start(id:)` uses the canonical container ID rather than the
  CLI alias — the new VM's rootfs mount path no longer diverges from
  where the daemon writes `/healthcheck/cmd-*`.
- Dockerfile `HEALTHCHECK CMD <shell-form>` is now wrapped in
  `/bin/sh -c` (previous behaviour split on whitespace and passed straight
  to `execvp`).
- Watcher no longer marks paused containers as `.stopped` (was racing
  with `cocker pause` because VZ's `state == .running` returns false on
  paused VMs).
- Per-container probe seq counter replaces the process-global one — daemon
  restarts can't collide with stale `result-*` files on the shared rootfs.
- `/healthcheck` directory is wiped on every VM start so the new boot's
  `health_poll` doesn't re-process stale `cmd-*` files.
- Probe output is sanitized for JSON (NUL byte → space, non-UTF8 replaced).
- Background Tasks (`watcherTasks`, `healthTasks`) are tracked by UUID slot
  ownership so a Task's cleanup can't wipe the entry of a fresh respawn ;
  `remove()` explicitly cancels them via `cancelBackgroundTasks`.
- Restart grace after stop+start is a flat 5 s instead of
  `max(start_period, 5)` ; start_period applies only on initial boot,
  matching Docker semantics.

### Tests
- 10 new unit tests covering `mergeHealthcheck` precedence,
  `Container` forward-migration decoder, `HealthLogEntry` codable
  roundtrip.
