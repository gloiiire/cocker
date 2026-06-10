# Cocker — Quickstart

For developers on Apple Silicon who want Docker workflows without Docker Desktop.

## Pre-flight

You need :

1. **An Apple Silicon Mac**, macOS 14 (Sonoma) or later.
2. **Xcode** installed (free from the App Store) — supplies the Swift toolchain and the codesigning machinery `cockerd` requires.
3. **An Apple Development signing certificate** — free with any Apple ID, but you must create it once :
   - Open Xcode → Settings → Accounts → sign in with an Apple ID.
   - Click **Manage Certificates** → **+** → **Apple Development**.
   - This is mandatory : macOS only grants the `com.apple.security.virtualization` entitlement to binaries signed with a real Apple cert (ad-hoc signatures are rejected).
4. **Homebrew** ([brew.sh](https://brew.sh)) — used to install dependencies and the Apple Container Linux kernel.

## Install (from source — current path)

The Homebrew tap is staged but the `Formula/cocker.rb` `sha256` is still a placeholder until a tagged GitHub release goes up. Until then :

```bash
brew install zig
brew install apple/container/container          # provides the Linux kernel
git clone https://github.com/gloiiire/cocker
cd cocker
./install.sh
```

The installer :
- builds `cocker` + `cockerd` (release, Swift)
- cross-compiles `cocker-init` (statically linked Linux ARM64 binary that runs as PID 1 inside every container VM) via Zig + strips it via `-Wl,-s`
- packs the initrd
- signs `cockerd` with your Apple Development cert
- links the kernel + initrd into `~/.cocker/kernel/`
- registers a LaunchAgent so `cockerd` auto-starts (and respawns)
- installs man pages into `~/.local/share/man/man1/`

End-state : `cocker` and `cockerd` are on your `PATH`, the daemon is running, and `cocker version` prints the version banner.

## Hello world

```bash
# Pull an image and run a one-shot container
cocker run --rm alpine -- echo "hello from $(uname -m) inside a VM"

# Run a long-lived service with port forwarding
cocker run -d --name web -p 8080:80 nginx:alpine
curl http://localhost:8080/        # → standard nginx welcome page

# Check status (health column included on running containers with HEALTHCHECK)
cocker ps

# Tear it down
cocker rm -f web
```

## Healthcheck — full Docker semantics

```bash
# CLI override on a container that has no image HEALTHCHECK
cocker run -d --name redis-hc \
  --health-cmd "redis-cli ping" \
  --health-interval 5s --health-timeout 2s --health-retries 3 \
  redis:alpine

# Inspect the full Docker-shaped State.Health
cocker inspect redis-hc | jq '.[0].State.Health'
# {
#   "Status": "healthy",
#   "FailingStreak": 0,
#   "Log": [{ "Start": "2026-06-07T23:03:30.911242961Z", ... }]
# }

# Same via the Docker API socket (works with `docker` CLI / Go clients)
DOCKER_HOST=unix://$HOME/.cocker/docker.sock docker inspect redis-hc
```

Supported `--health-*` flags : `--health-cmd`, `--health-interval`, `--health-timeout`, `--health-start-period`, `--health-retries`, `--no-healthcheck`. Compose `healthcheck:` blocks are honoured. Probe stdout/stderr is captured (4 KB cap). Hanging probes get SIGKILL'd at `timeout` and report exit code 124.

## Use the standard `docker` CLI

```bash
export DOCKER_HOST=unix://$HOME/.cocker/docker.sock
docker ps
docker run --rm alpine echo hi
docker inspect redis-hc --format '{{.State.Health.Status}}'
```

Cocker speaks Docker Engine API v1.41 over the `docker.sock` listener. Healthcheck JSON shape, event filters, port bindings, mount semantics all match.

## Compose

`cocker-compose.yml` (or `docker-compose.yml` — both names accepted) :

```yaml
services:
  web:
    image: nginx:alpine
    ports: ["8080:80"]
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O- http://localhost/ > /dev/null"]
      interval: 5s
      timeout: 3s
      retries: 3
      start_period: 2s        # snake_case OR camelCase accepted
```

```bash
cocker compose up -d
cocker compose ps              # status column suffixed with (healthy)
cocker compose logs -f web
cocker compose down
```

## Common operations

```bash
# Containers
cocker ps                              # running only
cocker ps -a                           # everything
cocker logs -f <name>                  # follow
cocker exec <name> <cmd ...>           # Docker-style, no `--` needed
cocker stats <name>                    # CPU / memory live
cocker stop <name>
cocker rm -f <name>

# Images
cocker pull alpine:latest
cocker images
cocker build -t myapp .
cocker rmi myapp
cocker save -o myapp.tar myapp
cocker load -i myapp.tar
cocker login ghcr.io                   # private registries

# Volumes
cocker volume create myvol
cocker run -v myvol:/data alpine -- sh -c 'echo hi > /data/x'
cocker volume rm myvol

# Networks
cocker network create mynet
cocker run -d --network mynet --name a nginx:alpine
cocker run -d --network mynet --name b nginx:alpine
cocker run --rm --network mynet alpine -- wget -q -O- http://a/   # DNS works
```

## iCloud Drive projects

Projects living under iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/`,
or any "Desktop & Documents Folders" sync path) work transparently.
`cocker build` and `cocker compose up` auto-detect iCloud paths, pre-fetch
any dataless files, and rsync the tree to `~/Library/Caches/cocker/staging/`
before handing it to the daemon — this sidesteps a `bird` (Apple's iCloud
coordinator) deadlock that breaks every other copy path. Subsequent runs
are incremental.

Inspect / control state with :

```bash
cocker icloud status                  # how much is dataless ?
cocker icloud prefetch                # warm the cache before a big build
cocker icloud cache-clear             # nuke ~/Library/Caches/cocker/staging/
```

`.dockerignore` and `.cockerignore` are both honoured during staging
(and during `COPY` inside builds).

## Troubleshooting

**`cocker version` says "Cannot connect to cockerd"**

```bash
cocker daemon status       # is it alive ?
cocker daemon start        # if not
cocker daemon logs -f      # follow log
```

**vmnet DHCP pool saturates after ~256 launches**

macOS's `bootpd` caps `dhcpd_leases` near 256 entries. The installer's `com.cocker.leases-helper` LaunchDaemon clears them on demand. If you skipped that step :

```bash
cocker daemon clear-leases     # one-shot sudo prompt
```

**`brew install cocker` fails with sha256 mismatch**

The Homebrew formula's sha256 is a placeholder until the project's first tagged GitHub release. Build from source for now :

```bash
git clone https://github.com/gloiiire/cocker && cd cocker && ./install.sh
```

## What works well, what's still rough

**Solid** — full Docker-compatible lifecycle, healthcheck end-to-end, restart policies (including `always` survival across `cockerd` reboots), Docker API socket compat, Compose v3.x, custom networks, named volumes, bind mounts, IPv6 allocation, internal DNS, port forwarding, pull/push to anonymous + authenticated registries, build (multi-stage Dockerfile with all common instructions), 681 unit tests + 90.91 % line coverage.

**Has rough edges** — `cocker exec -i` doesn't pipe host stdin through to the container yet (output streams back fine ; tracked as a known limitation in `LifecycleCommands.swift`). `buildx` multi-arch cross-build hasn't been end-to-end verified.

**Not implemented** — overlay/macvlan network drivers, Swarm mode (single-node wrappers around Compose exist), Docker plugins, intra-VM cgroup-based resource enforcement, alternative logging drivers (only the ring buffer is exposed).

**macOS-specific gotcha** — VM-per-container means startup cost is ~1 s per container (not microseconds like Linux namespace containers). Fine for dev workflows ; less fine if your test suite spawns hundreds of containers serially.

## Where state lives

```
~/.cocker/
├── cocker.sock           # native CLI IPC
├── docker.sock           # Docker Engine API socket
├── cockerd.pid
├── cockerd.log           # rotated at 10 MB, last 5 kept
├── state.json            # container/network/volume registry
├── kernel/
│   ├── vmlinuz           # → Apple's Linux kernel
│   └── initrd.img        # cocker-init packed cpio
├── images/
│   ├── blobs/sha256/     # OCI blob store
│   ├── rootfs/           # extracted image rootfs
│   └── containers/       # per-container clonefile rootfs
└── volumes/<name>/_data
```

Wipe everything with `rm -rf ~/.cocker`.

## Going further

- `cocker --help` and `cocker <subcommand> --help` are exhaustive.
- `man cocker.run` etc. (the installer puts pages in `~/.local/share/man/man1/`).
- `CLAUDE.md` describes the engine architecture for contributors.
- `CHANGELOG.md` for the per-release picture.
