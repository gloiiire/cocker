# End-to-end test suite

These scripts spin up real containers via a local `cockerd` and check that the user-facing behaviour holds. They cannot run on GitHub-hosted macOS runners because those don't carry the `com.apple.security.virtualization` entitlement that `Virtualization.framework` requires — boot fails immediately with "operation not permitted".

To run locally :

```bash
# Requires : a signed cockerd running locally (brew install or ./install.sh)
./tests/e2e/run-all.sh
```

Or pick individual scenarios :

```bash
./tests/e2e/01-basic-run.sh
./tests/e2e/02-inter-container-by-ip.sh
./tests/e2e/03-inter-container-by-name.sh
./tests/e2e/04-port-forwarding.sh
./tests/e2e/05-compose-two-services.sh
```

Each script exits 0 on success, non-zero on failure, and prints a one-line summary at the end. The runner `run-all.sh` aggregates them.

## What's covered

| Script | Validates |
|---|---|
| `01-basic-run.sh` | `cocker run alpine echo hello` produces "hello" |
| `02-inter-container-by-ip.sh` | container A can `ping` and `wget` container B by IP |
| `03-inter-container-by-name.sh` | DNS resolves peer container names to their `cockerIP` |
| `04-port-forwarding.sh` | `cocker run -p 18080:80` is reachable from `localhost:18080` |
| `05-compose-two-services.sh` | `cocker compose up` for a web+db stack ; web reaches `db` by service name |

## What's missing (and why)

These would be valuable but require infrastructure we don't have today :

- **Postgres / Redis soak** (24h+) — would catch memory leaks in `cockerd`, not currently a problem we can blame on cocker
- **Sleep/wake VMs** — `caffeinate` can't simulate the full sleep cycle ; needs a physical Mac
- **CI on a self-hosted runner with VZ entitlement** — would need someone to host one ; not free
- **Memory pressure** — needs sustained load infrastructure

If you do soak-test postgres/redis and find issues, please file a bug under the `e2e` label with the daemon log.

## Running it by hand

CI cannot run this suite — it needs a self-hosted Apple-silicon runner that can
use Virtualization.framework, and hosted runners are themselves VMs. Until one
exists, a maintainer running this before tagging is the only thing standing
between a regression and a release.

Against an isolated daemon, so your own containers are untouched:

```bash
swift build -c release
codesign --force --sign - --entitlements entitlements/cockerd.entitlements \
  .build/release/cockerd

# cocker-init is cross-compiled and packed into the initrd the daemon boots.
(cd cocker-init && \
  zig cc -target aarch64-linux-musl -static -O2 -Wall -o cocker-init \
    init.c cmdline.c net.c dns_proxy.c qemu.c spec.c exec_listener.c \
    caps.c health_poll.c etc_overlay.c dhcp_min.c && \
  cp cocker-init initrd-staging/init && \
  (cd initrd-staging && find . | cpio -o -H newc 2>/dev/null) | gzip -9 > initrd.img)

ROOT=/private/tmp/cocker-e2e            # keep it SHORT — see below
rm -rf "$ROOT" && mkdir -p "$ROOT/kernel"
cp -L ~/.cocker/kernel/vmlinuz "$ROOT/kernel/vmlinuz"
cp cocker-init/initrd.img "$ROOT/kernel/initrd.img"

COCKER_DNS_PORT=5399 ./.build/release/cockerd \
  --root "$ROOT" --socket "$ROOT/cocker.sock" &

export COCKER_HOST="unix://$ROOT/cocker.sock"
./.build/release/cocker pull alpine:latest
COCKER="$(pwd)/.build/release/cocker" COCKER_ROOT="$ROOT" bash Tests/e2e/run-all.sh
```

Two things that will waste your afternoon otherwise:

- **`COCKER_DNS_PORT` is not optional.** `--root` and `--socket` do *not* fully
  isolate a test daemon: the DNS listener binds a fixed port and fights the
  machine's real daemon (`WARN [dns] TCP listener bind failed`). Results go
  flaky rather than failing outright, which is worse.
- **Keep the root path short.** A Unix socket path is capped at 103 bytes, and
  a nested temp directory blows through it with a confusing error.
