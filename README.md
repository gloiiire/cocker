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
- Xcode 15.0 or later (for building)
- Apple container runtime: `brew install apple/container/container`

## Installation

### Via Homebrew (recommended)

```bash
brew tap gloiiire-/cocker
brew install cocker
brew services start cocker
```

### From source

```bash
git clone https://github.com/gloiiire-/cocker
cd cocker
swift build -c release --disable-sandbox

# Sign cockerd with required entitlements
codesign --force --sign - \
  --entitlements entitlements/cockerd.entitlements \
  .build/release/cockerd

# Install
cp .build/release/cocker /usr/local/bin/
cp .build/release/cockerd /usr/local/bin/
```

## Setup

```bash
# Install Apple container runtime (provides Linux kernel + initrd)
brew install apple/container/container

# Set up Cocker (links kernel files)
cockerd setup

# Start the daemon
cockerd &

# Verify
cocker version
cocker info
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
