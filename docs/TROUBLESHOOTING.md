# Cocker troubleshooting

## Symptoms

### `cockerd` won't start

```
[cockerd] FATAL: failed to create VM: 0x80000004 (operation not permitted)
```

The binary isn't signed with the virtualization entitlement. Run :

```bash
codesign --force --sign - --entitlements entitlements/cockerd.entitlements .build/release/cockerd
```

If you installed via Homebrew, run `brew postinstall cocker` — the formula auto-detects your Apple Development cert. If none exists, create one in Xcode → Settings → Accounts → Manage Certificates → +. The cert is free.

### `cocker run` hangs forever

Almost always means the VM failed to obtain DHCP. Check the daemon log :

```bash
tail -f ~/.cocker/cockerd.log
```

Look for `udhcpc: started` followed by `udhcpc: lease of …`. If you only see `started`, vmnet is broken — restart the daemon (`brew services restart cocker`) which recreates the bridge.

### `Container is not running: <id>` after `cockerd` restarts

The container records left in `state.json` claim to be running but the VMs they reference died with the previous daemon. Since v0.2.0 cockerd reconciles this on startup automatically (marks them `.stopped` with exit code -1). If you're on an older build, `rm ~/.cocker/state.json` and start fresh, or upgrade.

### `wget: bad address 'srv-a:8080'` from one container to another

DNS resolution failed. Steps :

1. Check both containers are running on the same daemon (`cocker ps`)
2. Check the in-VM proxy started : container's stderr should show `[cocker-init] dns-proxy spawned (pid=..., upstream=vsock CID=2 port=5353 via TCP)`
3. Check vsock is reaching cockerd : on the host, `lsof -p $(pgrep cockerd) | grep vsock` should show an open socket
4. Confirm the target container has a `cockerIP` : `cocker inspect <name> | grep cockerIP` should show `10.42.0.X`. If empty, the L2 switch isn't wired — restart the container

### `wget: connection refused` from container A to B's IP

Container B is up but its service isn't listening. Verify from inside B :

```bash
cocker exec <B> -- netstat -lnp | grep <port>
```

The L2 fabric only forwards Ethernet frames ; it doesn't synthesize TCP.

### macOS Sequoia : `connect: Operation not permitted` from cockerd to a container IP

The App Sandbox restricts user-signed daemons from `connect()`ing to private vmnet IPs. cockerd works around this by spawning `cocker-portfwd` (a separately-signed binary) and `/usr/bin/nc` (Apple-signed) for the actual outbound connection. If `cocker-portfwd` is missing or unsigned, host → container port forwarding silently fails — `brew reinstall cocker` should fix it.

### iCloud Drive deadlocks (`EDEADLK` during build / compose up)

If you see `cockerd` failing partway through `COPY` with
`Resource deadlock avoided`, or `cocker compose up` hanging on the
first `read()`, the project lives under iCloud Drive
(`~/Library/Mobile Documents/com~apple~CloudDocs/` or a path with the
"Desktop & Documents Folders" sync xattr).

Apple's `bird` (the iCloud coordinator) serializes filesystem syscalls
on iCloud-resident paths inside user-space. A long-running daemon
issuing many concurrent `read()`s past the first few files trips
`bird` into returning `EDEADLK`. This affects `cp -R`, `ditto`, and
even raw `read()` from inside cockerd — there is no host-side fix.

**Cocker handles this automatically since 0.5.13.20.** `cocker compose up`
/ `cocker build` auto-detect iCloud paths, pre-fetch any dataless
files, and rsync the tree to `~/Library/Caches/cocker/staging/` before
handing it to the daemon. Subsequent runs are incremental.

If you hit the deadlock on an older build, or want to inspect what
cocker is doing :

```bash
cocker icloud status                  # what's dataless ?
cocker icloud prefetch                # warm the cache via brctl
cocker icloud cache-clear             # nuke the staging dir
```

Manual workaround if you're stuck on a build that pre-dates staging :
copy the project out of iCloud (`rsync -a ~/Library/Mobile\ Documents/com~apple~CloudDocs/myproject ~/Projects/`)
and run cocker from the local copy.

The `COCKER_FORCE_STAGE=1` env var forces staging for non-iCloud paths
too — useful when reproducing the issue against a local copy.

### Containers pile up after a crash

`cockerd` reconciles on startup (since v0.2.0) but only marks them stopped — it doesn't delete them. List with `cocker ps -a` and bulk-remove with `cocker rm -f $(cocker ps -a -q)`.

## Diagnostic commands

```bash
# Daemon health
cocker info
cocker version
cocker system df

# Logs
tail -f ~/.cocker/cockerd.log
cocker logs -f <container>

# Metrics
DOCKER_HOST=unix://$HOME/.cocker/docker.sock curl http://localhost/metrics

# Inspect networking
cocker inspect <container> | grep -E 'IP|MAC'

# Verify Apple kernel is symlinked
ls -la ~/.cocker/kernel/

# Verify entitlements on cockerd
codesign -d --entitlements - $(which cockerd) 2>&1 | grep virtualization
```

## Filing a bug

Open an issue at https://github.com/gloiiire/cocker/issues with :

- `cocker version` output
- `sw_vers` (macOS version)
- Relevant lines from `~/.cocker/cockerd.log` (last 100 lines is fine)
- The exact command that failed and what you expected
