# Cocker / Docker compatibility matrix

What works today, what's partial, what's missing. Anything not on this list is "not implemented".

## CLI commands

| Command | Status | Notes |
|---|---|---|
| `cocker run` | ✅ works | Inherits CMD/ENTRYPOINT/ENV/WORKDIR/USER from image config (since v0.1.2) |
| `cocker ps [-a] [-q]` | ✅ works | |
| `cocker stop / kill / start / restart` | ✅ works | |
| `cocker rm [-f]` | ✅ works | |
| `cocker pause / unpause` | ✅ works | |
| `cocker logs [-f] [--tail N]` | ✅ works | |
| `cocker exec [-it]` | ✅ works | Uses vsock to the container's PID 1 |
| `cocker inspect` | ✅ works | |
| `cocker top` | ✅ works | |
| `cocker cp` | ✅ works | both directions |
| `cocker rename` | ✅ works | |
| `cocker diff` | ✅ works | |
| `cocker stats` | ✅ works | |
| `cocker port` | ✅ works | |
| `cocker events` | ✅ works | |
| `cocker pull` | ✅ works | Docker Hub, GHCR, ECR via OCI v1.1 |
| `cocker push` | ✅ works | |
| `cocker build` | ✅ works | `FROM`, `COPY`, `RUN` (ephemeral VM), `CMD`, `ENV`, `WORKDIR`, `EXPOSE`, `LABEL` ; multi-stage works ; `ARG` works |
| `cocker buildx` | ⚠️ partial | Multi-arch via zig cross-compile ; full QEMU emulation : `cocker-init` registers `binfmt_misc` handlers since v0.2.1 (x86_64, aarch64, riscv64), but the Swift-side wiring (virtiofs share of qemu-user-static binary + `Container.platform` field + `cocker qemu install` command) is not yet implemented. PRs welcome. |
| `cocker images` | ✅ works | |
| `cocker rmi` | ✅ works | |
| `cocker tag` | ✅ works | |
| `cocker image history / prune` | ✅ works | |
| `cocker save / load` | ⚠️ partial | save works ; load extracts but image metadata can drift |
| `cocker commit` | ✅ works | |
| `cocker export / import` | ✅ works | |
| `cocker update` | ✅ works | |
| `cocker login / logout` | ✅ works | Credentials persisted in `~/.cocker/credentials.json` (0o600) |
| `cocker compose up / down / logs / ps / exec / build / pull / restart / pause / unpause` | ✅ works | Compose v3 spec via Yams |
| `cocker network create / rm / ls / inspect / connect / disconnect` | ✅ works | |
| `cocker volume create / rm / ls / inspect` | ✅ works | |
| `cocker system info / df / prune / events` | ✅ works | |
| `cocker context` | ✅ works | |

## Docker HTTP API

| Endpoint | Status |
|---|---|
| `GET /_ping`, `HEAD /_ping` | ✅ |
| `GET /version` | ✅ |
| `GET /info` | ✅ |
| `GET /events` | ✅ |
| `GET /metrics` (Prometheus) | ✅ (cocker-only extension) |
| Containers CRUD (`/containers/*`) | ✅ |
| Images (`/images/*`) | ✅ |
| Networks (`/networks/*`) | ✅ |
| Volumes (`/volumes/*`) | ✅ |
| Build (`/build`) | ✅ |
| Exec (`/exec/*`) | ✅ |
| Swarm (`/swarm/*`) | ❌ not implemented |
| Plugins (`/plugins/*`) | ❌ not implemented |
| Configs / Secrets (`/configs/*`, `/secrets/*`) | ❌ Swarm-only, not implemented |

## Networking

| Feature | Status | Notes |
|---|---|---|
| Per-container IP via Apple vmnet NAT | ✅ | each container gets a `192.168.64.X` address on `eth0` |
| Inter-container by IP (`10.42.0.X`) | ✅ since v0.1.1 | userspace L2 switch |
| Inter-container by name (DNS) | ✅ since v0.1.1 | vsock-tunneled DNS |
| Compose service name resolution | ✅ | via `com.cocker.service` label |
| Host → container port forwarding (`-p`) | ✅ | dedicated `cocker-portfwd` binary |
| `--network host` | ❌ not implemented | containers are full VMs, no host-stack share is possible |
| IPv6 inter-container | ⚠️ partial | resolution works, full traffic untested |
| MAC anti-spoofing on the switch | ✅ since v0.2.0 | |

## Storage

| Feature | Status |
|---|---|
| Bind mounts (`-v /host:/container`) | ✅ |
| Named volumes (`-v vol:/path`) | ✅ |
| `--volumes-from` | ✅ |
| `tmpfs` | ✅ |
| OverlayFS layers | ⚠️ flattened to APFS copy-on-write at extraction time |

## Image format

| Feature | Status |
|---|---|
| OCI image-spec v1.1 | ✅ |
| Multi-arch manifests | ⚠️ only ARM64 actually runs |
| Image config persistence (CMD/ENV/WORKDIR/LABEL/EXPOSE) | ✅ since v0.1.2 |
| Image signing (cosign / notary) | ❌ not implemented |
| SBOM (SPDX / CycloneDX) | ✅ since v0.2.0 (CI artifact via `syft`) |
| Vulnerability scan | ✅ since v0.2.0 (CI via `trivy`) |

## Security

| Feature | Status |
|---|---|
| Per-container VM isolation (hardware-level) | ✅ |
| `--user`, `--cap-drop`, `--read-only` | ✅ |
| `seccomp` profiles | N/A — containers run their own kernels, kernel-level seccomp not exposed |
| AppArmor / SELinux | N/A — same as above |
| Image scan in CI | ✅ |
| L2 fabric MAC anti-spoofing | ✅ |

## Things that don't exist (and why)

- **docker-in-docker** — Apple Silicon doesn't expose nested virtualization
- **swarm mode** — would need cluster orchestration ; out of scope for "single-host dev tool"
- **`COCKER_HOST=tcp://…`** — daemon only binds Unix sockets ; remote management not implemented
- **`--gpus`** — cocker can't pass through the Mac GPU to the guest

## Tested workloads

The CI runs unit tests only ; the following have been manually validated on M3 Max with macOS 15.0.1 :

| Workload | Status |
|---|---|
| `alpine:latest -- /bin/sh` | ✅ |
| `nginx:alpine` with `-p 8080:80` | ✅ |
| Two containers + `nslookup peer` + `wget http://peer/` | ✅ |
| `cocker compose` with web + db (2 services) | ✅ |
| Long-running container (24h+) | ⚠️ not validated |
| Postgres with persistent volume | ⚠️ not validated |
| Redis cluster | ⚠️ not validated |
| Compose stack with 3+ services and inter-deps | ⚠️ not validated |
| Mac sleep/wake while containers running | ⚠️ not validated (VMs may hang) |
