# Security

## Reporting a vulnerability

Open a [security advisory](https://github.com/gloiiire/cocker/security/advisories/new)
rather than a public issue. Include the cocker version (`cocker --version`), your
macOS version, and the smallest reproduction you have.

## What running cocker gives away

Worth reading before you install it on a machine you share.

### The daemon socket is root-equivalent

Anyone who can write to `~/.cocker/cocker.sock` or `~/.cocker/docker.sock` can run
privileged containers, bind-mount any host path into one, and exec into it as root.
Both sockets are `0600`, owner-only. **Treat them like an SSH private key.** The
same applies to the `DOCKER_HOST` variable — pointing a tool at that socket hands
it the machine.

### Registry credentials are stored in plaintext

`cocker login` writes to `~/.cocker/credentials.json` (mode `0600`) in the clear.
It is not the macOS Keychain, and `docker-credential-*` helpers are not supported,
so ECR/GAR workflows that rely on them won't work. If your registry password is
also used elsewhere, assume a local attacker with your uid can read it.

### `brew install` plants a root LaunchDaemon

`post_install` uses `sudo` to install `/Library/LaunchDaemons/com.cocker.leases-helper.plist`,
a root job that truncates `/var/db/dhcpd_leases` — the workaround for macOS
`bootpd` refusing new leases past a ceiling Apple doesn't expose. It runs as root,
for as long as it is installed. Remove it with:

```bash
sudo launchctl bootout system/com.cocker.leases-helper
sudo rm /Library/LaunchDaemons/com.cocker.leases-helper.plist
```

Cocker still works without it; you may hit the lease ceiling after a few hundred
containers.

### Containers are VMs, but not a security boundary you should lean on

Each container is a real Apple VM, which is a stronger isolation story than
namespaces. But `--privileged`, `--cap-add` and host bind mounts all do what they
say. A container you gave `-v /:/host` to has your disk.

### TLS for the remote socket

The mTLS listener requires **ECDSA (prime256v1)** identities. RSA keys imported
through `SecPKCS12Import` are CSSM-backed and cannot do RSA-PSS, which boringssl
demands for TLS 1.3 — the handshake then hangs rather than failing. Generate
ECDSA, or don't expose the socket over TCP.

## Supported versions

Pre-1.0, only the latest release gets fixes. Once 1.0 ships, the current minor
line does — see the compatibility promise in [`docs/ROADMAP-1.0.md`](docs/ROADMAP-1.0.md).
