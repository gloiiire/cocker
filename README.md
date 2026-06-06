# Cocker

A Docker-compatible container engine for Apple Silicon, powered by Apple Virtualization.framework.

Cocker runs Linux containers natively on macOS using lightweight Apple VMs — no x86 emulation, no Rosetta, no Docker Desktop required.

## Features

- Docker-compatible CLI (`cocker run`, `cocker ps`, `cocker exec`, etc.)
- OCI image registry support (pull from Docker Hub, GHCR, ECR, etc.)
- Docker Compose v3 support (`cocker compose up/down/logs/ps`)
- Native Apple Virtualization.framework — fast VM startup (~1s)
- Built-in DNS server for container name resolution
- Docker-compatible API socket (works with docker CLI via `DOCKER_HOST`)
- Port forwarding, named volumes, custom networks
- Swift 6 with strict concurrency — safe and fast

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
brew install cocker
brew services start cocker
```

The formula builds from source and, in `post_install`, auto-detects your **Apple Development** certificate to sign `cockerd` with the Virtualization entitlement. If no cert is found, it tells you exactly how to create one (Xcode → Settings → Accounts → Manage Certificates → +) and then run `brew postinstall cocker`.

Why a cert is required: `cockerd` calls `Virtualization.framework`, and macOS only grants the `com.apple.security.virtualization` entitlement to binaries signed by a real Apple developer certificate — not an ad-hoc signature. The cert is free; only an Apple ID is needed.

See the [`gloiiire/homebrew-cocker`](https://github.com/gloiiire/homebrew-cocker) tap for full details.

### From source

```bash
git clone https://github.com/gloiiire/cocker
cd cocker
./install.sh
```

`install.sh` does the whole dance: checks prereqs, builds `cocker` + `cockerd` + `cocker-init` (the Linux PID 1 used inside each VM), signs `cockerd` with your Apple Development cert, populates `~/.cocker/kernel/`, and registers a LaunchAgent that keeps the daemon running.

## Verify

```bash
cocker version
cocker info
```

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

# Restart / pause / unpause
cocker compose restart
cocker compose pause web
cocker compose unpause web

# Tear down
cocker compose down
```

### System

```bash
cocker system info
cocker system prune
cocker system df
cocker system events
```

## Docker compatibility

Cocker implements the Docker Engine API v1.41. You can use the standard `docker` CLI against a running `cockerd` instance:

```bash
export DOCKER_HOST=unix://$HOME/.cocker/docker.sock
docker ps
docker run --rm alpine echo hello
```

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
Tests/             — 21 unit tests
Formula/           — Homebrew formula
entitlements/      — codesign entitlements for cockerd
```

## License

MIT — see [LICENSE](LICENSE)
