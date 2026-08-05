# Getting off Apple's vmnet DHCP pool

Status: **proposed**, nothing implemented. Written 2026-08-02 after a
production incident on the maintainer's machine.

## The problem, measured

macOS's `bootpd` stops handing out DHCP leases once `/var/db/dhcpd_leases`
holds roughly 256 entries. That file is **host-wide** and `root:wheel`.
Every container cocker starts consumes one entry, and **nothing ever
reclaims them** — on 2026-08-02 the file held leases dated 4 July next to
leases minutes old.

Observed that day: 317 entries against a ~256 ceiling. Every `cocker run`
failed to get an IP. One full e2e run costs ~25 leases, so from an empty
pool CI gets two or three passes before the machine stops working.

Three consequences, in order of how much they hurt:

1. **A hard ceiling of ~256 containers per machine, ever** — not
   concurrent, cumulative, until someone truncates the file.
2. **cocker needs root to recover.** Hence `LeasePoolMonitor`, the
   `com.cocker.leases-helper` LaunchDaemon, `cocker daemon clear-leases`
   and `cocker daemon helper-install` — a whole privileged subsystem whose
   only job is working around a file we don't own.
3. **Two cockerd instances on one host fight**, because the pool is
   shared. This is what made CI e2e runs flaky against the maintainer's
   own daemon.

1.0.1.0 made the failure *visible* (it used to be completely silent). It
did not make it go away, and it cannot: truncating a root-owned file is
not something an unprivileged daemon gets to do.

## What the code actually does today

Verified by reading, 2026-08-02. Line numbers are from that day.

### Every container has two NICs

| NIC | Attachment | Address from | Carries |
|---|---|---|---|
| `eth0` | `VZNATNetworkDeviceAttachment` (Apple vmnet, 192.168.64.0/24) | **DHCP** | outbound internet, **inbound published ports** |
| `eth1` | `VZFileHandleNetworkDeviceAttachment` → cocker's own userspace L2 switch | **static**, via kernel cmdline | container ↔ container |

`VMRuntime.swift:562-612` builds both. DNS uses **neither** — it rides
vsock (`DNSVsockListener.swift:23`, `cocker-init/dns_proxy.c:40-48`).

**Only `eth0` consumes a lease.** The comment on `VMRuntime.swift:562`
says it plainly: *"eth0 — outbound NAT to the internet (Apple-managed
vmnet)"*.

### So what actually depends on the lease

| Feature | Needs the vmnet address? |
|---|---|
| Outbound internet | **yes** — default route comes from the DHCP router option (`dhcp_min.c:200-214`) |
| Published ports `-p` | **yes** — the forwarder dials `container.ip`, which is the DHCP address (`ContainerEngine.swift:938-965`, `PortForwarder.swift:103-106`) |
| Container ↔ container | no — `eth1`, `cockerIP`, the L2 switch |
| DNS by service name | no — vsock |

Two features to move. Not ten.

### The half we already own

`Sources/CockerDaemon/Network/L2Switch.swift` is a real userspace learning
switch: MAC learning, anti-spoofing (drops frames whose source MAC isn't
the one assigned to that port, `:155-161`), broadcast flood, unicast
forward. It sits behind the `L2Switching` protocol so it can be faked in
tests. Addresses on it come from `CockerSwitchAllocator` — `10.42.0.0/16`,
allocated by cocker, **costing nothing**.

That is half a network stack, already written, already working.

### Two dead ends already in the tree

Worth knowing before designing anything:

- **The gateway `10.42.0.1` is fictional.** Nothing answers ARP for it.
  `KernelCommandLine.swift:123` emits `cocker.cnet_gw`, and **no code in
  `cocker-init/` ever reads it** — grep finds only `cnet_ip`
  (`net.c:162`). `eth1` has a connected /16 route and no default route.
- **There is no static-IP path for `eth0`.** `net_setup_eth0_dhcp`
  (`net.c:142-159`) is DHCP-only. But `configure_iface`
  (`dhcp_min.c:184-217`) — which sets address, netmask and a default route
  via `SIOCSIFADDR` / `SIOCSIFNETMASK` / `SIOCADDRT` — is right there,
  currently fed only by DHCP results.

### The cost of `eth0` beyond the lease

Publishing a port today takes **three processes**:

```
cockerd  →  cocker-portfwd (one per mapping)  →  /usr/bin/nc (one per connection)
```

`cocker-portfwd` exists only because macOS Sequoia refuses `connect()` to
the private vmnet bridge from a binary carrying
`com.apple.security.virtualization`; the sidecar is signed without it, and
Apple-signed `/usr/bin/nc` is permitted even as a subprocess
(`PortForwarder.swift:6-15`, `Sources/CockerPortFwd/main.swift:4-14`).
UDP mappings are silently skipped (`PortForwarder.swift:36-39`).

Removing `eth0` deletes that entire structure: a shipped binary, its
signing rules, its PID tracking and its SIGTERM lifecycle.

## Step 0 — the one-day spike, before anything else

> Tracked as **#392**. **Run 2026-08-05: it works.** Everything below the
> spike section is therefore very likely unnecessary — see the results
> before building any of it.

**Hypothesis:** the pool fills because we *ask* for an address. What if we
don't?

Assign `eth0` a static address inside `192.168.64.0/24` from the kernel
cmdline, with the gateway `192.168.64.1`, and let cocker track its own
allocations. `configure_iface` already does exactly this — it just needs
to be called with fixed values instead of DHCP results.

**If it works, the entire rest of this document is unnecessary.** The pool
stops growing, the ~256 ceiling disappears, and the whole privileged
subsystem can be deleted. Cost: a day.

**Known risk.** `VMRuntime.swift:578-579` records that pinning a
self-chosen `02:cc:*` MAC made vmnet's bootpd refuse to issue leases. That
was an attempt to *get a lease* with our own MAC. Not asking for a lease
at all is a different scenario and has not been tested.

**Second risk: address collisions.** Nothing else allocates for us. cocker
would have to own a range and check what is taken — it already parses
`/var/db/dhcpd_leases` for exactly this kind of lookup
(`LeasePoolMonitor.lookupLeasedIP`).

**Pass/fail:** a container with a static `eth0` reaches the internet *and*
answers on a published port. Yes → stop here. No → below.

### Result, 2026-08-05 — it works

Run against a pool **already saturated at 317/256**, where every container
should have failed to boot. Shipped opt-in behind `COCKER_STATIC_ETH0=1`;
**it has since become the default** (opt out with `COCKER_STATIC_ETH0=0`),
once the spike allocator was replaced by a real one.

| | |
|---|---|
| Container boots | yes — `inet 192.168.64.192/24 eth0`, `default via 192.168.64.1` |
| Fabric unaffected | yes — `10.42.0.0/16 dev eth1 src 10.42.0.2` |
| Outbound by IP | HTTP 200, `ping` 2/2, 6.7 ms |
| Outbound by name | full HTTPS fetch of `example.com` — DNS + TLS |
| Published port | `-p 18097:80` answered from the host |
| **Full e2e suite** | **13/13 passed** |
| **Leases consumed** | **0** — 317 before, 317 after, including across the entire e2e run |

An e2e run normally costs ~25 leases. This one cost none, on a pool that
was already past the ceiling.

So the ~256 ceiling is not a constraint we have to live with, and the
userspace network stack below is not the price of removing it.

**What this does not yet settle:**

- The allocator is spike-grade: `.180`–`.244` derived from the container
  id (FNV-1a, so it survives a daemon restart — `hashValue` is seeded per
  process). It is deterministic and collision-free per id, but it does not
  coordinate with anything else on the host. A shipping version must read
  the lease file and track its own assignments.
- It is opt-in. Making it the default is the next decision, and it wants a
  release of its own.
- Long-lived hosts sharing a /24 with other VMs still need the collision
  question answered properly.

## If the spike fails: give `eth1` a way out

Goal: the fabric cocker already owns becomes the only network, and `eth0`
is deleted.

### Step 1 — a real gateway on the fabric

Answer ARP for `10.42.0.1`, serve DHCP on the fabric (cocker hands out its
own addresses instead of writing them on the kernel cmdline), and make
`cocker-init` actually read `cocker.cnet_gw` so a default route exists.
The plumbing is already emitted and dead; this connects it.

Purely additive — `eth0` stays, nothing can regress.

### Step 2 — the outbound path: **relay over vsock**

This is the load-bearing decision.

**Rejected — a userspace TCP/IP stack on the host.** Terminating the
guest's TCP connections host-side means implementing TCP: handshake,
sequence numbers, retransmission, windows, half-close. Podman's
`gvisor-tap-vsock` does this by embedding gVisor's netstack; **there is no
equivalent in Swift**. Months of work, concentrated in the code that is
hardest to get right.

**Chosen — relay bytes over vsock.** Outbound connections inside the guest
are transparently redirected to a local proxy in `cocker-init`, which
forwards to `cockerd` over vsock; `cockerd` opens an ordinary socket.

```
container app ──► redirect ──► proxy in cocker-init ──vsock──► cockerd ──► internet
   (Linux kernel does TCP)                                  (macOS kernel does TCP)
```

Nobody reimplements TCP. Both ends use a real kernel stack and we carry
payload bytes between them.

Why vsock specifically: cocker's DNS already runs over vsock, and the
reason is documented in two places — Apple's App Sandbox drops vmnet
payload to a user-signed daemon (UDP lost; TCP `accept()` succeeds then
`read()` returns 0) — `DNSVsockListener.swift:9-14`,
`cocker-init/dns_proxy.c:10-12`. On this platform vsock is the channel
this project has *proven* works.

**Where the work actually is:** guest-side. An application's connection
must reach the proxy without the application knowing, which means
transparent redirection in the guest's kernel. `cocker-init` is a small
static musl binary; this is the substantial part of the change.

**What this costs, stated plainly:**

- **Throughput.** Every byte crosses userspace instead of staying in the
  kernel. Podman and Lima ship with this trade-off, so it is liveable —
  but it must be *measured and published*, not discovered by users.
- **TCP is the easy case.** UDP needs more care. ICMP (`ping`) is awkward
  without raw sockets and may have to be emulated or declared
  unsupported — and if unsupported, it must fail loudly, not silently.

### Step 3 — inbound published ports

`cockerd` listens on the host port and dials the container **on the
fabric**. The vmnet sandbox restriction no longer applies, so the
connection can be made in-process. Delete `cocker-portfwd`, and the
per-connection `nc`. UDP mappings become implementable rather than
silently dropped.

### Step 4 — flip the default, keep an escape hatch

New path becomes the default; `eth0` stays reachable behind a flag that
warns. `docs/ROADMAP-1.0.md` commits to deprecating with a warning for a
full minor cycle — that applies here.

### Step 5 — delete

`eth0`, `LeasePoolMonitor`, the root LaunchDaemon, `clear-leases`,
`helper-install`, the ~256 ceiling. Roughly 400 lines and one privileged
system service removed.

## What this buys

- No per-machine container ceiling.
- **cocker never needs root again, for anything.**
- One shipped binary and one root LaunchDaemon deleted.
- Concurrent daemons stop interfering — CI and a developer's own daemon
  can coexist.
- Published UDP ports become possible.

## Out of scope, but found while mapping this

Independent of the network work, each worth its own fix:

1. **#393 — duplicate fabric addresses after a daemon restart.**
   `NetworkManager.allocatedCockerIPs` / `cockerHostCounter` are in-memory
   and `init(store:)` never rehydrates them from existing containers, so a
   restarted daemon allocates from `10.42.0.2` again while surviving
   containers keep theirs. Read from code, not reproduced.
2. **#394 — `cocker network create --subnet` is inert.** The subnet is
   stored and never used: no address is drawn from it, no isolation is
   applied, and DNS resolves globally across all networks
   (`DNSServer.swift:142`, `:329`). `configurePortForwarding`
   (`NetworkManager.swift:222-229`) is a `print()` with no caller.
3. **#395 — `container.ipv6` is fabricated.** Allocated, stored and
   reported by `inspect`; nothing ever configures it in a guest.
4. **#396 — `/etc/hosts` gets the placeholder address** (172.17.0.x)
   because it is written before boot, when the real address isn't known.
   Mitigated: only written when absent.
5. **#397 — `dhcp_min 2.c`** is a stray duplicate in the tree.

(2) and (3) are the same category as the fabricated `node ls` output fixed
for 1.0: cocker reporting something that does not exist.
