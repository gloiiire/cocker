# Cocker

A Docker-compatible container engine for Apple Silicon, powered by Apple Virtualization.framework.

Cocker runs Linux containers natively on macOS using lightweight Apple VMs — no x86 emulation, no Rosetta, no Docker Desktop required.

## Features

- Docker-compatible CLI (`run`, `ps`, `exec`, `logs -f`, `stats`, `top`, `cp`, …)
- OCI v2 registry support — pull AND push, auth via `cocker login`
- Docker Compose v3 — `up`, `down`, `build:`, `profiles:`, `labels:` (array + dict), networks (custom + IPAM), volumes (named + bind), `depends_on:` (with conditions)
- Multi-stage Dockerfile : `ARG` before `FROM`, `COPY --from=<stage>`, `HEALTHCHECK`, `USER` (real `setuid` inside the container), `EXPOSE` multi-port/UDP, `ENV` with `${VAR}` substitution
- Native Apple Virtualization.framework — fast VM startup (~1 s per container)
- Inter-container DNS (resolve by service name) over a userspace L2 switch
- Docker-compatible API socket (47 endpoints incl. `_ping`, `images/history`, `containers/changes`) — works with `docker` CLI via `DOCKER_HOST=unix://~/.cocker/docker.sock`
- Port forwarding host → container, named volumes, custom bridge networks
- Restart policies (`no` / `on-failure` / `always` / `unless-stopped`) with exponential backoff + clonefile persistence between restarts ; containers with `--restart=always` / `unless-stopped` auto-relaunch on daemon reboot
- **Full Docker-compatible healthcheck pipeline** — `HEALTHCHECK` in Dockerfile + 6 CLI flags (`--health-cmd`, `--health-interval`, `--health-timeout`, `--health-start-period`, `--health-retries`, `--no-healthcheck`) + Compose `healthcheck:` block. Probes capture stdout/stderr, SIGKILL on timeout, ring-buffer 5 entries. `State.Health.{Status,FailingStreak,Log}` over the Docker API socket with RFC 3339 nanosecond timestamps.
- Stress-tested with 10+ concurrent containers
- **681 unit tests, 90.91 % line coverage** (CI-enforced gate)
- Swift 6 with strict concurrency

## Cocker vs Docker

| Feature | Cocker | Docker Desktop | Notes |
|---|---|---|---|
| **Core lifecycle** (`run`/`ps`/`stop`/`rm`) | ✅ | ✅ | parity |
| **Build / multi-stage** | ✅ | ✅ | including `COPY --from`, `ARG` before `FROM`, all major instructions |
| **Push / Pull** | ✅ | ✅ | OCI v2, public + private registries with auth |
| **Compose** | ✅ | ✅ | most common fields ; profiles, networks, volumes, depends_on |
| **Port forwarding** | ✅ | ✅ | nc-based bridge per mapping |
| **USER instruction** | ✅ | ✅ | real `setuid` via cocker-init |
| **Inter-container DNS** | ✅ | ✅ | via internal proxy |
| **Logs `-f` follow** | ✅ | ✅ | via ring buffer polling |
| **Events stream** | ✅ | ✅ | `cocker system events` |
| **Stats / top / cp** | ✅ | ✅ | implemented via container exec |
| **Restart policies** | ✅ | ✅ | with backoff + persistence |
| **Healthcheck** (declaration + probe runtime) | ✅ | ✅ | full pipeline — Dockerfile + CLI flags + Compose + State.Health JSON. The original VZ vsock callback quirk was sidestepped via a virtiofs file-based protocol. |
| **buildx multi-arch** | ⚠️ | ✅ | command exists, multi-arch cross-build not e2e-verified |
| **TTY allocation (`-t`)** | ⚠️ | ✅ | flag parsed, full PTY not yet wired |
| **`--privileged` / `--cap-add`** | ❌ | ✅ | not propagated to cocker-init |
| **Resource enforcement** (cgroup intra-VM) | ❌ | ✅ | VM-level limits work, intra-VM cgroup not exposed |
| **Network drivers** (overlay/macvlan) | ❌ | ✅ | bridge only |
| **Secrets / configs** | ❌ | ✅ | Swarm-mode primitives absent |
| **Logging drivers** (`json-file`/`syslog`) | ❌ | ✅ | ring buffer only |
| **Plugins** | ❌ | ✅ | no extension system |
| **Swarm / Stack / Service** | 🟡 single-node | ✅ | wrappers around compose |

**Known macOS gotcha — DHCP lease pool** : macOS's `vmnet` ships a built-in
`bootpd` that hands out IPs to each container VM from a pool capped at ~256
entries in `/var/db/dhcpd_leases`. Sustained churn (CI, big test suites)
saturates it in minutes and then `cocker run` silently produces a container
with no IP (port-forwarding lands on `127.0.0.1`, which doesn't work).

**The recommended fix** : run **once**, ever, on a new machine —
```
cocker daemon helper-install   # one sudo prompt, installs a tiny LaunchDaemon
```
After that, cockerd auto-triggers the helper at >200 leases and the issue
disappears for good. `cocker daemon status` shows the live count and helper
state. If you prefer not to install the helper, the one-shot escape hatch is
`cocker daemon clear-leases` (also prompts for sudo each call). The hard limit
is a `vmnet` design choice, not a cocker bug.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14.0 Sonoma or later
- Xcode 15.0 or later (for building / signing)
- An **Apple Development** signing certificate (free with any Apple ID — see below)
- Apple's container Linux kernel: `brew install container`

## Installation

### Via Homebrew (recommended)

```bash
brew tap gloiiire/cocker
brew install cocker          # pours the pre-built bottle in ~5 s
cocker daemon init           # one-command setup : signs, refreshes kernel, starts daemon
```

`cocker daemon init` is the single command you want to run after install. It walks through every prerequisite with a TUX-style checklist and fixes whatever needs fixing :

```
$ cocker daemon init
✓ binaries installed at /opt/homebrew/opt/cocker/bin
✓ Apple Container kernel found
→ cockerd is ad-hoc signed — resigning with your Apple Development cert…
✓ signed: Apple Development: you@icloud.com (XXXXXXXXXX)
→ refreshing ~/.cocker/kernel/ from /opt/homebrew/share/cocker…
✓ initrd installed, vmlinuz linked
→ starting daemon…
✓ cockerd running (pid 12345)

cocker is ready. Try : cocker run -it alpine sh
```

It's idempotent — run it again any time after `brew upgrade cocker`, or whenever a `cocker pull` complains about a missing kernel.

**Why the manual step ?** `brew install` runs its `post_install` hook inside a Homebrew seatbelt sandbox that denies writes to `~/.cocker/` and reads to `~/Library/Keychains/`. So the formula always ad-hoc signs cockerd and leaves the rest to `cocker daemon init`, which runs in your shell and can do everything cleanly. Splitting the work this way means `brew install cocker` never breaks with an "ad-hoc fallback" warning that looks like a failure.

If you prefer to run the steps individually :

```bash
cocker daemon resign         # resign cockerd with your real Apple Dev cert
cocker daemon setup          # refresh ~/.cocker/kernel/ from <prefix>/share/cocker/
brew services start cocker   # start the launchd-managed daemon
```

Why a real cert is preferable to ad-hoc : the ad-hoc signature is honored by macOS *on the machine that produced it* (you can still launch VMs), but you lose the `TeamIdentifier` field, so you can't copy the binary across machines without re-signing.

See the [`gloiiire/homebrew-cocker`](https://github.com/gloiiire/homebrew-cocker) tap for full details.

### From source

```bash
git clone https://github.com/gloiiire/cocker
cd cocker
./install.sh
```

`install.sh` does the whole dance: checks prereqs, builds `cocker` + `cockerd` + `cocker-init` (the Linux PID 1 used inside each VM), signs `cockerd` with your Apple Development cert, populates `~/.cocker/kernel/`, and registers a LaunchAgent that keeps the daemon running.

#### Side-by-side dev install

When you're hacking on cocker itself, you usually want a parallel install you can break without losing your prod daemon. Pass `SUFFIX=-dev` :

```bash
SUFFIX=-dev ./install.sh
```

This installs a complete second cocker stack with `-dev` appended to everything :

| | prod (default) | dev (`SUFFIX=-dev`) |
|---|---|---|
| CLI binary | `cocker` | `cocker-dev` |
| daemon binary | `cockerd` | `cockerd-dev` |
| MCP server | `cocker-mcp` | `cocker-mcp-dev` |
| data dir | `~/.cocker/` | `~/.cocker-dev/` |
| IPC socket | `~/.cocker/cocker.sock` | `~/.cocker-dev/cocker.sock` |
| launchd label | `com.cocker.cockerd` | `com.cocker.cockerd-dev` |

Both daemons can run at the same time (different sockets, different state). Run `cocker ps` and `cocker-dev ps` from the same shell — you'll see two independent worlds.

The lease-pool helper LaunchDaemon (system-wide, root-owned) is shared between the two installs ; only the first run prompts for sudo.

## Verify

```bash
cocker version    # or `cocker -v`
cocker info
```

## Running cockerd

`cockerd` is a long-running daemon (like `dockerd`). It listens on three Unix sockets and waits for requests — it does **not** exit on its own. Use the `cocker daemon` subcommands so you don't have to know shell idioms :

```bash
cocker daemon start              # spawn in background, returns to shell
cocker daemon status             # running? pid, uptime, log, socket
cocker daemon logs -f            # follow the log (ANSI-colorized by level when stdout is a TTY ; pass --no-color to disable)
cocker daemon stop               # graceful shutdown (SIGTERM)
cocker daemon restart            # stop + start
```

State lives in `~/.cocker/cockerd.pid` and `~/.cocker/cockerd.log` (log auto-rotates at 10 MiB, last 5 kept). `start` refuses to spawn a second cockerd if one is already alive.

### Alternative : as a managed service (auto-start at login)

```bash
brew services start cocker
brew services stop cocker
brew services list
```

### Alternative : foreground (for debugging)

```bash
cockerd                          # banner + listeners + "Ready", Ctrl-C to stop
```

You'll see the startup banner + listener summary + a "Ready" line, then it sits there. **That's normal** — the daemon is alive and waiting on requests. Open another terminal for `cocker ps`, `cocker run`, etc.

### Environment variables

| Variable | Effect |
|---|---|
| `COCKER_ROOT` | data directory (default `~/.cocker`) |
| `COCKER_SOCKET` | IPC socket path |
| `COCKER_LOG_LEVEL` | `debug` / `info` / `warn` / `error` (default `info`) |
| `COCKER_LOG_FORMAT` | `text` (default) or `json` for structured records |
| `COCKER_TRACE` | `stderr` to emit OTLP-compatible JSON spans |
| `COCKER_DNS_PORT` | override the internal DNS port (default `5300`) |
| `COCKER_TCP_TLS_PORT` | enable the TLS Docker-API listener on this TCP port (typically `2376`) |
| `COCKER_TCP_TLS_NO_CLIENT_AUTH` | accept TLS connections without client certs (server-auth only). Default is mTLS. |

## Remote access over TLS (mTLS on TCP)

Cocker can expose the Docker Engine API over TCP with mutual TLS so a
remote client can drive it from another machine. The setup is a single
command followed by an env-var-flagged daemon start :

```sh
cocker daemon tls-init                                     # one-time : generates ~/.cocker/tls/
COCKER_TCP_TLS_PORT=2376 cocker daemon start               # daemon now also listens on tcp://0.0.0.0:2376

# from a client (same or remote machine) :
DOCKER_HOST=tcp://your-host:2376 \
DOCKER_TLS_VERIFY=1 \
DOCKER_CERT_PATH=/path/to/copy/of/.cocker/tls \
docker ps
```

The Unix socket paths (`cocker.sock`, `docker.sock`) keep working in
parallel — TLS is purely additive.

### Why it's worth the README real-estate

Getting TLS server certs to work on macOS with `Network.framework` is
substantially trickier than on Linux. Two design decisions that look
arbitrary at first glance are forced by Apple-specific behaviour ;
documenting them here so the cocker maintainer (or you, in 6 months)
doesn't waste a day rediscovering them.

#### 1. ECDSA P-256 everywhere, not RSA

`cocker daemon tls-init` generates an EC-P256 key pair for the CA,
server, and client — not the classic RSA-4096 you'd get from a
`dockerd` quick-start recipe.

Why : the daemon imports its private key via Apple's `SecPKCS12Import`,
which on macOS always lands the key in the legacy **CSSM** keychain
(file-backed, originally from Mac OS X 10.2). When the TLS stack
(macOS's bundled boringssl) tries to use that key during a TLS 1.3
handshake, it needs to produce an **RSA-PSS** signature for the
`CertificateVerify` step. CSSM legacy keys can't do RSA-PSS — every
attempt fails immediately with `CSSMERR_CSP_INVALID_KEYATTR_MASK` and
the handshake stalls forever. Forcing the server down to TLS 1.2
(which uses the simpler RSA-PKCS1v15 signature) is a workaround but
gives up modern ciphersuites + 0-RTT.

ECDSA dodges the entire failure family : the signature algorithm is
the same in TLS 1.2 and 1.3, CSSM handles it fine, and the cert/key
files are roughly 5× smaller (~600 B vs ~3.3 KB for RSA-4096).

#### 2. Server-key pre-warm at daemon start

The first `SecKeyCreateSignature` on a freshly-imported PKCS#12
identity routinely takes **9–12 seconds** on macOS, and on a "cold"
keychain it can stretch to several minutes. The wait is keychain ACL
bootstrap inside macOS's `securityd` and is unavoidable. Subsequent
signatures cost ~5 ms.

So the daemon performs **one dummy signature synchronously at
startup**, *before* opening the listening TCP port. The operator pays
the ~10-second wait once at `cocker daemon start`. In exchange, the
first real client that connects sees an instant handshake — not an
SSL timeout at 8 s while macOS is still finishing its first signature.

In the daemon log :
```
[docker-api-tls] pre-warming server key (one-time, ~10s; up to 4 min on cold keychain)…
[docker-api-tls] server key pre-warmed in 9s
[docker-api-tls] TLS listening on tcp://0.0.0.0:2376
```

#### 3. mTLS by default — opt out via env

The verify block in `DockerAPITLSListener.swift` pins trust to the CA
generated by `tls-init` and rejects anything else. Connections
without a client cert are dropped during the handshake
(`-9863 certificate required`). If your operational story already has
TCP firewalled or you only want server-auth, set
`COCKER_TCP_TLS_NO_CLIENT_AUTH=1` before starting the daemon.

Files generated by `cocker daemon tls-init` are detailed in
`cocker daemon tls-init --help` ; same content lives in the man page
(`man cocker-daemon-tls-init`).

## Help & man pages

Every command and subcommand supports `-h` / `--help`:

```bash
cocker --help
cocker run --help
cocker compose up --help
```

`install.sh` also generates and installs man pages (via the `swift-argument-parser` `GenerateManual` plugin) into `$PREFIX/share/man/man1/`. Pages are named with dots, one per subcommand:

```bash
man cocker              # root page
man cocker.run          # subcommand (dot, not dash)
man cocker.compose.up
```

If `man cocker` returns "No manual entry", add the install prefix to your `MANPATH`:

```bash
export MANPATH="$HOME/.local/share/man:$(manpath 2>/dev/null)"
```

To regenerate pages from a source checkout:

```bash
swift package --allow-writing-to-package-directory generate-manual --multi-page
# output: .build/plugins/GenerateManual/outputs/CockerCLI/*.1
```

## Usage

```bash
# Pull and run a container
cocker pull alpine:latest
cocker run --name myapp -d -p 8080:80 nginx:alpine

# List containers
cocker ps
cocker ps -a   # include stopped

# Execute a command
cocker exec -it myapp sh

# Logs
cocker logs -f myapp

# Copy files
cocker cp myapp:/etc/nginx/nginx.conf ./nginx.conf
cocker cp ./index.html myapp:/usr/share/nginx/html/

# Stats
cocker stats

# Port mappings
cocker port myapp

# Stop / remove
cocker stop myapp
cocker rm myapp
```

### Image management

```bash
cocker images
cocker pull ubuntu:22.04
cocker rmi ubuntu:22.04
cocker tag myimage:latest myimage:v1.0
cocker image history alpine:latest

# Save / load
cocker save -o myimage.tar myimage:latest
cocker load -i myimage.tar

# Registry auth
cocker login registry.example.com
cocker logout registry.example.com

# Prune unused images
cocker image prune
```

### Compose

```bash
# Start all services
cocker compose up -d

# View logs
cocker compose logs -f

# List services
cocker compose ps

# Execute in service
cocker compose exec web sh

# Pull all images
cocker compose pull

# Build services with build: config
cocker compose build

# Hot-reload : watch the project dir, rebuild & restart on file change
cocker compose watch
cocker compose watch --debounce-ms 500     # tune batching window

# Restart / pause / unpause
cocker compose restart
cocker compose pause web
cocker compose unpause web

# Tear down
cocker compose down
```

`cocker compose up` (without `-d`) opens an attached session — press `d` to
detach (containers keep running, matches Docker Compose v2 UX) or Ctrl-C
for a traditional teardown. Stdin is auto-detected : piped input skips raw
TTY mode so `cocker compose up | tee` works.

`cocker compose watch` brings the project up via `compose up -d` first,
then opens a recursive FSEventStream on the source directory and rebuilds
+ restarts on batched events (default 300 ms debounce ;
`~/Library/Caches/cocker/`, `.DS_Store`, `.Spotlight-V100`, `.fseventsd`
are auto-skipped).

### Cockerfile

When a `Cockerfile` exists in the build context, it's preferred over
`Dockerfile`. This lets you keep a Docker-compatible Dockerfile and a
cocker-specific Cockerfile side by side — e.g. to opt into
cocker-only features without breaking your CI that still runs
`docker build`.

### System

```bash
cocker system info
cocker system prune
cocker system df
cocker system events
```

## iCloud Drive projects

Cocker auto-detects projects that live under iCloud Drive
(`~/Library/Mobile Documents/com~apple~CloudDocs/`, or any path carrying
a `com.apple.fileprovider.*` xattr — which also covers the
"Desktop & Documents Folders" sync) and works around the macOS `bird`
daemon's behaviour transparently. No flags, no opt-in.

### Why this is needed

Apple's `bird` (the iCloud Drive coordinator) materializes dataless
files on demand by intercepting filesystem syscalls. When `cockerd`
(a long-running daemon) issues many concurrent `read()`s through that
path, `bird` returns `EDEADLK` (Resource deadlock avoided) often enough
to break `cp -R`, `ditto`, and even raw `read()` from inside the daemon.
Past the first few files, every `COPY` or `compose build` will stall or
fail with no useful diagnostic.

### What cocker does automatically

When `cocker compose up` / `cocker build` runs on an iCloud-resident
project, the CLI :

1. Stages the project to
   `~/Library/Caches/cocker/staging/<basename>-<hash>/` via rsync
   (avoids the `bird` deadlock that affects every other copy path).
2. Auto-detects dataless files via
   `URLResourceValues.ubiquitousItemDownloadingStatus` and pre-downloads
   them via Apple's `startDownloadingUbiquitousItem` with progress
   reporting before the rsync starts.
3. Skips the pre-fetch step entirely when everything is already local.
4. Applies `.dockerignore` + `.cockerignore` from the project tree, plus
   hardcoded defaults (`.git`, `node_modules`, `.DS_Store`, `*.icloud`).
5. Reuses the staging directory on subsequent runs : rsync only re-reads
   files that changed in iCloud — incremental staging is "free" after
   the first run.

### `cocker icloud` — inspect & control

```bash
# Show materialization state (count of Materialized / Dataless /
# Downloading + total + pending bytes). Run before a build to predict
# whether staging will be fast or slow.
cocker icloud status
cocker icloud status ~/some/project
cocker icloud status --json

# Force-materialize all dataless files via brctl download, with a
# before/after delta report.
cocker icloud prefetch
cocker icloud prefetch ~/some/project

# Wipe ~/Library/Caches/cocker/staging/ (frees disk ; next build
# re-stages from scratch).
cocker icloud cache-clear
```

Sample output :

```
Scanning /Users/me/Projects/api…
  Files:       1247
  Total size:  84.3 MB
  ─────────────────────────────
  Downloaded:    1102 (88%)
    of which current:  1102
  Dataless:      143 (11%)
  Downloading:   2 (0%)
  Pending bytes: 8.7 MB

→ A `cocker icloud prefetch /Users/me/Projects/api` (or `cocker compose up`)
  will materialize the missing files first.
```

### Environment variables

| Variable | Effect |
|---|---|
| `COCKER_FORCE_STAGE` | `1` forces staging even for non-iCloud paths (CI / testing) |
| `COCKER_ICLOUD_TIMEOUT` | bird query timeout in seconds (default `30`) |

## Shell completion

```bash
# bash : append to your ~/.bashrc or ship system-wide
cocker completion bash > /usr/local/etc/bash_completion.d/cocker

# zsh : drop into your $fpath
cocker completion zsh > /usr/local/share/zsh/site-functions/_cocker

# fish
cocker completion fish > ~/.config/fish/completions/cocker.fish
```

Generated by ArgumentParser straight from the command graph — every new
subcommand / flag is reflected the next time you re-source the script.
Modern terminals (Warp, Zed, Kiro, VS Code terminal, iTerm autosuggest)
parse these scripts to build their inline command pickers, so completion
"just appears" once installed.

## Docker compatibility

Cocker implements the Docker Engine API v1.41. You can use the standard `docker` CLI against a running `cockerd` instance:

```bash
export DOCKER_HOST=unix://$HOME/.cocker/docker.sock
docker ps
docker run --rm alpine echo hello
```

## MCP (Claude Desktop / agents)

`cocker-mcp` is a stdio JSON-RPC bridge that exposes cockerd to any MCP-compatible
client (Claude Desktop, Claude Code, custom agents). It speaks the
[Model Context Protocol](https://spec.modelcontextprotocol.io/) on stdin/stdout
and forwards calls to the Docker socket + native IPC.

29 tools across containers (`cocker_ps`, `cocker_logs`, `cocker_run`,
`cocker_exec`…), images, volumes, networks, compose (`cocker_compose_up/down/ps/ls`),
and system (`cocker_info`, `cocker_version`, `cocker_events`).

Wire it up in `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cocker": { "command": "/opt/homebrew/bin/cocker-mcp" }
  }
}
```

Restart Claude Desktop and the tools appear in the tool picker. The bridge
talks to the Docker socket by default (`~/.cocker/docker.sock`); set
`DOCKER_HOST=unix://…` in the env block if you point it elsewhere.

## Architecture

```
┌─────────────────────────────────────────────┐
│  cocker (CLI)          cocker compose        │
│  ArgumentParser commands → IPC requests      │
└─────────────────┬───────────────────────────┘
                  │ Unix socket (~/.cocker/cocker.sock)
┌─────────────────▼───────────────────────────┐
│  cockerd (daemon)                            │
│  ┌──────────┐ ┌──────────┐ ┌─────────────┐  │
│  │Container │ │  Image   │ │  Compose    │  │
│  │ Engine   │ │ Manager  │ │  Engine     │  │
│  └────┬─────┘ └────┬─────┘ └─────────────┘  │
│       │             │                         │
│  ┌────▼─────────────▼──────────────────────┐ │
│  │  Apple Virtualization.framework          │ │
│  │  VZVirtualMachine (one per container)   │ │
│  └─────────────────────────────────────────┘ │
│  ┌─────────┐ ┌──────────┐ ┌───────────────┐ │
│  │ DNS     │ │ Network  │ │ Docker API    │ │
│  │ Server  │ │ Manager  │ │ (HTTP/Unix)   │ │
│  └─────────┘ └──────────┘ └───────────────┘ │
└─────────────────────────────────────────────┘
```

Each container runs as a lightweight Apple VM. Containers share the host kernel via Apple Virtualization.framework — there is no emulation layer.

## Project structure

```
Sources/
  CockerCore/      — Shared types: models, IPC protocol, OCI client
  CockerCLI/       — CLI commands (ArgumentParser)
  CockerDaemon/    — Daemon: engine, VM runtime, DNS, Docker API
Tests/             — unit tests + end-to-end scenarios
Formula/           — Homebrew formula
entitlements/      — codesign entitlements for cockerd
```

## Testing

```bash
swift test                  # unit tests
Tests/e2e/run-all.sh        # end-to-end, needs a running cockerd
```

**Hosted CI cannot boot containers, and that is a hardware limit.**
Measured on a GitHub-hosted `macos-15` runner (reproduce with the `VM
capability probe` workflow):

```
chip                          = Apple M1 (Virtual)
kern.hv_vmm_present           = 1      ← the runner is itself a VM
nestedVirtualizationSupported = false  ← nested virt requires M3+
VZVirtualMachineConfiguration.validate()
  → VZErrorDomain Code=2 "Virtualization is not available on this hardware."
```

Booting a guest from inside a VM requires nested virtualization, which
Apple ships only on M3 and later (macOS 15+); GitHub's macOS fleet is
M1/M2 and GitHub documents nested virtualization as unsupported. No Xcode
or CLI tooling works around this.

So CI splits in two:

| Job | Runs on | Covers |
| --- | --- | --- |
| `build + package` | GitHub-hosted | compilation, `cocker-init` cross-build, initrd packing, entitlement embedded in the signed binary |
| `e2e (self-hosted, real VMs)` | self-hosted Apple silicon | the full `Tests/e2e` suite, booting real containers |

### Self-hosted runner

The e2e job targets the labels `[self-hosted, macOS, ARM64, vm-capable]`.
When no such machine is online the job simply stays queued, so the setup
is optional and never blocks a PR.

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
VER=$(gh api repos/actions/runner/releases/latest --jq .tag_name | sed 's/^v//')
curl -fsSL -O "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-osx-arm64-${VER}.tar.gz"
tar xzf "actions-runner-osx-arm64-${VER}.tar.gz"

TOKEN=$(gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token)
./config.sh --unattended --url https://github.com/<owner>/<repo> --token "$TOKEN" \
  --name "$(scutil --get LocalHostName)" \
  --labels self-hosted,macOS,ARM64,vm-capable --work _work

# The launchd service does NOT inherit your shell PATH; zig lives in Homebrew.
echo 'PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' >> .env

./svc.sh install && ./svc.sh start
```

Requirements: Apple silicon that is **not** itself virtualised (the job
asserts `kern.hv_vmm_present = 0` and fails loudly otherwise), plus `zig`
and a kernel at `~/.cocker/kernel/vmlinuz`. The job runs its daemon on an
isolated `--root` under `RUNNER_TEMP`, so CI containers, images and build
cache never touch the machine owner's own state.

**Security — required on a public repository.** A self-hosted runner
executes whatever a workflow asks it to, on your machine. Two protections
are in place and must stay:

- the e2e job refuses to run for a pull request coming from a fork;
- the repository requires manual approval before any workflow runs for an
  external contributor:

```bash
gh api -X PUT repos/<owner>/<repo>/actions/permissions/fork-pr-contributor-approval \
  -f approval_policy=all_external_contributors
```

## License

MIT — see [LICENSE](LICENSE)
