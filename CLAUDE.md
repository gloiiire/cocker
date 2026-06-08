# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Cocker is a Docker-compatible container engine for Apple Silicon. Containers are not Linux namespaces on the host — each container is a real lightweight Linux VM booted via Apple's `Virtualization.framework`. This shapes most of the architecture below.

The repo ships two Swift executables (`cocker` CLI, `cockerd` daemon) plus a small C init binary (`cocker-init`) that runs as PID 1 inside the guest VM.

## Build / test / run

```bash
# Build everything (debug)
swift build

# Build release (what install.sh and Homebrew use)
swift build -c release --disable-sandbox

# Run all tests (parallel, matches CI)
swift test --parallel

# Run a single suite or test (swift-testing, not XCTest)
swift test --filter ImageReferenceTests
swift test --filter ImageReferenceTests/parseDigest

# Cross-compile cocker-init for Linux ARM64 from macOS (use -Wl,-s to strip
# — macOS `strip` cannot process Linux ELF, so pass the flag through to the
# zig linker. Stripped binary is ~70 KB ; unstripped is ~1.6 MB).
cd cocker-init && zig cc -target aarch64-linux-musl -static -O2 -Wall -Wl,-s \
    -o cocker-init init.c cmdline.c net.c dns_proxy.c spec.c qemu.c \
    exec_listener.c caps.c health_poll.c etc_overlay.c

# Repack the initrd that cockerd boots VMs with (after editing init.c)
cd cocker-init && cp cocker-init initrd-staging/init && \
  (cd initrd-staging && find . | cpio -o -H newc 2>/dev/null) | gzip -9 > ../initrd.img

# Full local install (build + sign + cocker-init + launchd + kernel symlink)
./install.sh

# Lint (non-blocking in CI today)
swift-format lint --recursive Sources/ Tests/

# Generate man pages (used by install.sh / Homebrew)
swift package --allow-writing-to-package-directory generate-manual --multi-page
```

`cockerd` requires the `com.apple.security.virtualization` and `com.apple.vm.networking` entitlements — it will not start any VM without being signed against `entitlements/cockerd.entitlements`. Local dev: `codesign --force --sign - --entitlements entitlements/cockerd.entitlements .build/release/cockerd`. `swift build` alone does not sign.

`cockerd setup` symlinks the Linux kernel + initrd into `~/.cocker/kernel/`. It expects `apple/container/container` from Homebrew (`brew install apple/container/container`); without that kernel, VMs cannot boot.

Tests use **swift-testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest — match that style for new tests.

## Architecture

### Process model
- `cocker` (CLI, `Sources/CockerCLI`): ArgumentParser subcommands. Each command serializes an `IPCRequest` and sends it over a Unix socket. The CLI itself contains essentially no engine logic.
- `cockerd` (daemon, `Sources/CockerDaemon`): owns all state, all VMs, and three listeners simultaneously — the internal IPC socket (`~/.cocker/cocker.sock`), the Docker-compatible HTTP socket (`~/.cocker/docker.sock`), and an internal DNS server. `main.swift` wires these together; `ContainerEngine` is the central actor everything routes through.
- `cocker-init` (C, `cocker-init/init.c`): the PID 1 that runs inside every container VM. It mounts virtiofs as rootfs, parses `cocker.*` kernel cmdline params from cockerd, and execs the container's command. It is statically linked against musl and shipped inside `initrd.img`. **Editing `init.c` requires rebuilding `initrd.img` and re-running `cockerd setup` (or reinstall) for changes to take effect.**

### IPC protocol
`Sources/CockerCore/IPC/Protocol.swift` defines `IPCRequest` / `IPCResponse` with a length-prefixed JSON framing. Responses can stream (`isStreaming`, `isLast` flags) — `logs -f`, `events`, `stats`, `exec`, `attach` all rely on this. When adding a new command end-to-end, you typically touch: a new case in `IPCRequestType`, a CLI command in `Sources/CockerCLI/Commands/`, and a handler in `DaemonServer` that dispatches into `ContainerEngine`.

### Engine layers (in `Sources/CockerDaemon/Engine/`)
- `ContainerEngine` — the public surface the IPC + Docker API servers both call. Holds references to the other managers and the shared `StateStore`.
- `VMRuntime` — `@MainActor` wrapper around `VZVirtualMachine`. One VM per container. Sets up `VZLinuxBootLoader` (kernel + initrd), virtiofs for rootfs and volumes, virtio-net, and a vsock device on port 9000 for in-guest comms. `runningVMs` keyed by container ID.
- `ImageManager` + `Sources/CockerCore/OCI/` — OCI registry client, manifest handling, blob store under `~/.cocker/images/blobs/sha256/`, rootfs extraction into `~/.cocker/images/rootfs/`. Credentials live in `Sources/CockerCore/Credentials.swift`.
- `NetworkManager` / `PortForwarder` / `VolumeManager` — host-side plumbing. Port forwarding bridges host TCP to the guest's IP.
- `StateStore` (`Sources/CockerDaemon/State/StateStore.swift`) — persists containers, networks, volumes as JSON in the data dir. Single source of truth for "what exists"; runtime state (running VMs) lives in `VMRuntime`.

### Docker compatibility
`Sources/CockerDaemon/API/DockerAPIServer.swift` implements Docker Engine API v1.41 over a separate Unix socket. It does its own minimal HTTP parsing (`HTTPParser.swift`) and translates Docker JSON shapes (`DockerAPITypes.swift`) into `ContainerEngine` calls — meaning the same engine logic backs both the native `cocker` CLI and `DOCKER_HOST=unix://~/.cocker/docker.sock docker …`. When changing engine semantics, check whether the Docker API translation layer also needs updating.

### Compose
`Sources/CockerDaemon/Compose/ComposeEngine.swift` parses `docker-compose.yml` via Yams and orchestrates against `ContainerEngine`. Compose runs in the daemon, not the CLI.

### Concurrency
Strict concurrency is on (`swift-tools-version: 5.10`, Swift 6 mode). Release builds use `-warnings-as-errors` for `CockerCore`. `VMRuntime` is `@MainActor`-isolated because `VZVirtualMachine` requires it; most engine code is `actor`-isolated or `Sendable`. Don't introduce non-`Sendable` shared state.

## Branch / CI policy (enforced)

`.github/workflows/branch-policy.yml` rejects PRs that violate the promotion chain:
- PRs into `staging` **must** come from `dev`.
- PRs into `main` **must** come from `staging`.

CI (`.github/workflows/ci.yml`) runs on macos-15 / Xcode 16.4 (Swift 6.1) and requires:
- `swift build` + `swift test --parallel` green.
- `swift build -c release` produces both `cocker` and `cockerd`.
- `cocker-init` cross-compiles to a valid Linux aarch64 ELF.
- `Package.resolved` is committed and matches `Package.swift` (the `audit` job fails on drift — `swift package resolve` then commit if you bump deps).

`swift-log` is pinned `<2.0.0` on purpose: 1.13+ requires Swift 6.2 / Xcode 26, which the macos-15 runner doesn't have. Don't bump past that without also moving the runner.

Lint is currently warn-only (`swift-format lint … || true`).

## Healthcheck

Cocker mirrors Docker's HEALTHCHECK semantics end-to-end. The host-side loop
in `ContainerEngine.runHealthcheckLoop` writes a NUL-separated argv to
`<rootfs>/healthcheck/cmd-<seq>` ; the guest's `cocker-init/health_poll.c`
worker reads it, forks the command (with caps, USER, WORKDIR, ENV inherited
from the container), and writes `result-<seq>` with the exit code + captured
stdout/stderr (4 KB cap). Bypasses the VZ vsock callback entirely — both
sides talk through virtiofs.

- **CLI overrides** : `--health-cmd`, `--health-interval`, `--health-timeout`,
  `--health-start-period`, `--health-retries`, `--no-healthcheck`. Match
  Docker's `docker run` flags. Empty / whitespace-only `--health-cmd` is
  treated as `--no-healthcheck` (overrides any image HEALTHCHECK).
- **Compose** : `healthcheck:` block with `test/interval/timeout/retries/
  start_period/disable` routes through `ComposeEngine.buildRunConfig` into
  the same RunConfig fields the CLI flags target.
- **Docker API** : `GET /containers/<id>/json` returns `State.Health.{Status,
  FailingStreak, Log}`. `Log[]` is a 5-entry ring buffer (matches Docker's
  default). Timestamps are RFC 3339 with nanoseconds so Go template parsers
  reading `time.Time` round-trip cleanly.
- **Native inspect** : `cocker inspect` returns both the flat fields
  (`healthStatus`, `healthFailingStreak`, `healthLog`) and a Docker-shaped
  `State.Health` sub-object so existing `docker inspect`-style template
  parsers work.
- **Exit code 124** : Docker's reserved "probe timed out" code. The guest
  worker SIGKILLs hanging probes at `timeout` so a stuck check can't pile
  up across intervals.
- **Restart-on-boot** : containers with `--restart=always` /
  `unless-stopped` are auto-relaunched in `ContainerEngine.autoRestartOnBoot`
  after `cockerd` restarts ; the healthcheck loop respawns via
  `spawnHealthcheckIfNeeded`. Tasks are tracked in `watcherTasks` /
  `healthTasks` dictionaries with UUID-keyed slot ownership so a
  finished-Task cleanup can't wipe the entry of a fresh spawn.

## Data layout

Everything cockerd persists lives under `~/.cocker/` (overridable via `--root` / `COCKER_ROOT`):
- `cocker.sock` — native CLI IPC socket
- `docker.sock` — Docker API socket (for `DOCKER_HOST`)
- `kernel/vmlinuz`, `kernel/initrd.img` — symlinks created by `cockerd setup`
- `images/blobs/sha256/` — OCI blob store
- `images/rootfs/` — extracted container rootfs (mounted into VMs via virtiofs)
- `volumes/` — named volumes
- `tmp/` — scratch space
