# Cocker architecture

Cocker is a Docker-compatible container engine for Apple Silicon. A container is **not** a Linux namespace on macOS — each container is a lightweight Linux VM booted via Apple's `Virtualization.framework`. The rest of the design follows from that constraint.

## Process model

```
                                 ┌────────────────────────────────────┐
   cocker (CLI)                  │            cockerd (daemon)        │
   ───────────                   │            ──────────────          │
   ArgumentParser ──IPC──▶  ◀────│  ContainerEngine                   │
                                 │   ├─ ImageManager   (OCI registry) │
                                 │   ├─ NetworkManager (NAT + switch) │
                                 │   ├─ VolumeManager  (named vols)   │
                                 │   ├─ StateStore     (state.json)   │
                                 │   ├─ VMRuntime      (Virtualization)│
                                 │   ├─ PortForwarder  (host→container)│
                                 │   └─ ComposeEngine  (compose v3)   │
                                 │                                    │
                                 │  Three concurrent listeners :       │
                                 │   • cocker.sock     (native CLI)   │
                                 │   • docker.sock     (Docker API)   │
                                 │   • DNS (UDP/TCP + vsock listener) │
                                 └────────────────────────────────────┘
                                            │
                                            │ creates one
                                            ▼
                          ┌─────────────────────────────────────────┐
                          │   container VM (Apple Virtualization)   │
                          │   ─────────────────────────────────────  │
                          │   PID 1 = cocker-init (C, static musl)  │
                          │     ├─ mounts virtiofs rootfs           │
                          │     ├─ brings up lo / eth0 / eth1       │
                          │     ├─ spawns DNS proxy (UDP :53)       │
                          │     └─ execs the container's argv       │
                          └─────────────────────────────────────────┘
```

## Networking

Each container gets **two NICs** :

| NIC | Backend | Purpose |
|---|---|---|
| `eth0` | `VZNATNetworkDeviceAttachment` (Apple NAT) | outbound internet (DHCP, source NAT) |
| `eth1` | `VZFileHandleNetworkDeviceAttachment` | inter-container fabric via cockerd's userspace L2 switch (`10.42.0.0/16`) |

Why two NICs : Apple's vmnet NAT isolates VMs from each other (a packet from container A to container B is dropped at the driver level), so we add a second NIC plugged into a switch we control. The switch does standard learning-switch forwarding (MAC learning + broadcast/multicast flood + unicast). Anti-spoofing is enforced by validating the source MAC against the MAC we assigned to that port at VM creation time.

### DNS

Apps in the container read `/etc/resolv.conf` which doesn't carry a port column, so they query `127.0.0.1:53`. `cocker-init` spawns a tiny in-VM DNS proxy that binds `0.0.0.0:53` and tunnels each query to cockerd over **vsock** (DNS-over-TCP framing). Why vsock and not vmnet : Apple's App Sandbox silently drops payload data from the vmnet kernel extension to user-signed daemons (cockerd is user-signed because the `com.apple.vm.networking` entitlement is gated behind a paid Apple Developer account). vsock bypasses vmnet entirely — it's a direct host↔VM channel provided by `Virtualization.framework`.

Container name resolution :
1. Container name (exact match)
2. Compose service alias (`com.cocker.service` label)
3. Short container ID (12 hex chars)
4. Hostname
5. Any name in `com.cocker.aliases` (comma-separated)
6. Anything else → forwarded to upstream DNS (1.1.1.1 by default)

## Storage

| Directory | Contents |
|---|---|
| `~/.cocker/state.json` | container, network, volume records |
| `~/.cocker/images/blobs/sha256/` | OCI blob store |
| `~/.cocker/images/rootfs/` | extracted container rootfs (mounted via virtiofs) |
| `~/.cocker/images/containers/<id>/rootfs/` | per-container rootfs clone (APFS copy-on-write) |
| `~/.cocker/volumes/` | named volumes |
| `~/.cocker/kernel/` | symlinks to vmlinuz + initrd.img |
| `~/.cocker/cockerd.log[.N]` | daemon logs (rotated at 10 MiB, keep 5) |

## VM bootstrap protocol

Two files written by cockerd before booting the VM, parsed by cocker-init :

- **`/cocker-spec`** — length-prefixed binary (`COCKER\x02` magic + u32 BE lengths). Carries argv + env + workdir. The previous line-separated format broke on `bash -c "a\nb"`.
- **`/etc/resolv.conf`** — initial pointer to the in-VM DNS proxy (re-pinned after udhcpc to survive DHCP overwrites).

The kernel command line carries the rest : `cocker.id`, `cocker.name`, `cocker.dns`, `cocker.dns_vsock_port`, `cocker.cnet_ip`, `cocker.cnet_mac`, `cocker.port.N`, `cocker.volN`.

## Code modules

### `CockerCore` (pure Swift, ≥ 90% covered)
Logic-only, no I/O dependencies. Linked by both the CLI and the daemon.
- `Models.swift` — `Container`, `ImageInfo`, …
- `Errors.swift`
- `Context.swift`, `Credentials.swift`
- `OCI/Manifest.swift`
- `IPC/Protocol.swift`
- `Dockerfile.swift`
- `VM/KernelCommandLine.swift`, `VM/RootfsBootstrap.swift`
- `DNS/DNSProtocol.swift`, `DNS/DNSNameResolver.swift`, `DNS/DNSQueryProcessor.swift`
- `Network/CockerSwitchAllocator.swift`
- `Logging/CockerLog.swift`, `Logging/LogRotator.swift`
- `Metrics/PrometheusExposition.swift`

### `CockerDaemon`
The daemon. Glues Virtualization.framework, the L2 switch, the DNS listeners, the Docker HTTP API, the IPC server, the Compose engine.

### `CockerCLI`
ArgumentParser commands. Each one parses argv, builds an `IPCRequest`, sends it to `cockerd` via the Unix socket, prints the response.

### `CockerPortFwd`
A separate small binary signed without the virtualization entitlement so the macOS sandbox lets it `connect()` into the vmnet bridge for host → container TCP forwarding.

### `cocker-init` (C, statically linked against musl)
The PID 1 inside each container VM. Cross-compiled with `zig cc -target aarch64-linux-musl`. Five translation units :

| File | Responsibility |
|---|---|
| `cocker_init.h` | shared decls + `die()` / `info()` macros |
| `cmdline.c` | parse `/proc/cmdline` for `cocker.*` params |
| `net.c` | bring up `lo` / `eth0` (DHCP) / `eth1` (static, cocker switch) |
| `dns_proxy.c` | UDP :53 → vsock cockerd tunnel |
| `spec.c` | parse `/cocker-spec` (argv + env + workdir) |
| `init.c` | main : virtiofs + mounts + orchestration |

## Operational hooks

- **Log levels** : `COCKER_LOG_LEVEL=debug|info|warn|error`
- **Log format** : `COCKER_LOG_FORMAT=text|json`
- **DNS port override** : `COCKER_DNS_PORT=5300`
- **Prometheus scrape** : `curl --unix-socket ~/.cocker/docker.sock http://_/metrics` or `DOCKER_HOST=… curl …/metrics`
