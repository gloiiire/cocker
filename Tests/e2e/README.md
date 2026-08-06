# End-to-end test suite

These scripts spin up real containers via a local `cockerd` and check that the user-facing behaviour holds. They cannot run on GitHub-*hosted* macOS runners, which don't carry the `com.apple.security.virtualization` entitlement `Virtualization.framework` requires — boot fails immediately with "operation not permitted".

They do run in CI, on a self-hosted Apple-silicon runner labelled `vm-capable` (see "Self-hosted runner" in the root `README.md`). The job is deliberately **not** a required check: the runner is one physical Mac, and a laptop being asleep shouldn't block a contributor. The `e2e coverage status` job writes into every run summary whether the suite actually ran, so a green tick can't be mistaken for e2e coverage.

To run locally :

```bash
# Requires : a signed cockerd running locally (brew install or ./install.sh)
Tests/e2e/run-all.sh
```

Or pick individual scenarios :

```bash
Tests/e2e/01-basic-run.sh
Tests/e2e/07-build-cache-runtime.sh
Tests/e2e/13-compose-override-and-exec-env.sh
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
| `06-image-run-directory.sh` | image content created below `/run` survives boot |
| `07-build-cache-runtime.sh` | a cached `RUN` layer is not reused across runtimes |
| `08-buildkit-and-copy-errors.sh` | build failures are loud, not silent |
| `09-ctrl-c-during-build.sh` | Ctrl-C interrupts a `compose watch` rebuild |
| `10-attach-flags.sh` | `-a`/`--attach` actually streams, and streams work off-TTY |
| `11-exit-codes.sh` | cocker reports failure when the container fails |
| `12-exec-after-start.sh` | `exec` works immediately after start, and repeatedly |
| `13-compose-override-and-exec-env.sh` | compose override files are merged, and `exec` sees the container's env |
| `15-run-flags.sh` | `--read-only`, `--tmpfs`, `--add-host` and `--dns` reach the guest |
| `14-exec-capabilities.sh` | `cocker exec` runs under the container's capability policy, not the full kernel set |

## What's missing (and why)

These would be valuable but require infrastructure we don't have today :

- **Postgres / Redis soak** (24h+) — would catch memory leaks in `cockerd`, not currently a problem we can blame on cocker
- **Sleep/wake VMs** — `caffeinate` can't simulate the full sleep cycle ; needs a physical Mac
- **Memory pressure** — needs sustained load infrastructure

If you do soak-test postgres/redis and find issues, please file a bug under the `e2e` label with the daemon log.

## Running it by hand

CI runs this suite on the self-hosted runner, but that runner is a single
machine and the job is not a required check, so it can be absent from a given
pull request. Running it by hand is also how you debug a failure — and worth
knowing: this suite boots real VMs and is sensitive to load. A saturated
machine fails `05` and `13` on timeouts that say nothing about the code, so
run it on an otherwise idle host before drawing conclusions.

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
