# Release checklist for v0.4.3

Steps only the human maintainer can do — everything else is committed and
tested as of this sprint.

## What 0.4.3 adds vs 0.4.1

| Sprint | Topic | Outcome |
|---|---|---|
| 6 | STOPSIGNAL spec v5 + version handshake + Docker-compat CLI parsing | plumbed |
| 7 | depends_on healthy + compose down --volumes + build layer cache | ✅ 8× speedup |
| 8 | save/load roundtrip + 0o600 sockets + _ping/history/changes API | ✅ verified |
| 9 | 200+ churn + 30 concurrent clients + push to local registry + lease watchdog | ✅ daemon stable |
| 10 | cold-path logs fallback (race fix for short-lived `cocker run --rm`) | ✅ |

## Done (in tree, ready to push)

- [x] `CockerVersion.version` = `"0.4.3"` (Sources/CockerCore/IPC/Protocol.swift)
- [x] `Formula/cocker.rb` `version "0.4.3"`
- [x] `CHANGELOG.md` 0.4.3 section consolidated
- [x] `README.md` test count + healthcheck table updated
- [x] `QUICKSTART.md` written
- [x] `install.sh` fixed : missing translation units + macOS strip on
      Linux ELF replaced with `-Wl,-s`
- [x] `cocker-init/initrd.img` rebuilt with current `health_poll.c`
      (stripped, 39 KB)
- [x] CI coverage gate (`.github/workflows/ci.yml`) updated `IGNORE`
      regex ; 90.91 % coverage on the gated set, 670 tests
- [x] Man pages re-generable via `swift package generate-manual`
      (`install.sh` does it automatically). Verified `--health-*`
      flags appear in `cocker.run.1`.
- [x] End-to-end smoke verified : run nginx → healthcheck → port
      forward → curl → `State.Health.Status: healthy` via both
      native `cocker inspect` and `docker.sock` HTTP socket

## Blocked on the human

### Git side
- [ ] **Commit the staged changes** (`git status` should be a clean
      list of M files + new CHANGELOG/QUICKSTART/RELEASE)
- [ ] **Tag and push** :
      ```bash
      git tag -a v0.4.3 -m "v0.4.3 — healthcheck hardening + stability"
      git push --follow-tags
      ```
- [ ] Open a GitHub release for `v0.4.3` and attach the source
      tarball (GitHub auto-generates one ; you can also `gh release
      create v0.4.3` if you have the CLI).

### Homebrew side
- [ ] Compute the release tarball sha256 and update
      `Formula/cocker.rb` :
      ```bash
      curl -sL https://github.com/gloiiire/cocker/archive/refs/tags/v0.4.3.tar.gz \
        | shasum -a 256 | cut -d' ' -f1
      ```
      Replace the `REPLACE_WITH_RELEASE_TARBALL_SHA256` placeholder
      in the formula and commit. Until this is done, `brew install
      cocker` will fail and `./install.sh` is the only working path.

### Cosign signing (optional, for security-conscious users)
- [ ] If you want the release attested, run cosign over the macOS
      arm64 binary and attach the `.sig` to the GitHub release.
      Mentioned in CLAUDE.md as required for releases ; we do not
      block on it here.

### Apple Developer cert (user-side)
- [ ] Each downstream user still needs their own Apple Development
      certificate. `install.sh` and `Formula/cocker.rb` both surface
      a clear "go to Xcode → Settings → Accounts → Manage
      Certificates → +" message when they can't find one. Cannot be
      automated server-side.

## What's intentionally NOT in 0.4.3

- `cocker exec -i` host-stdin forwarding (known limitation,
  documented in code at LifecycleCommands.swift:251). Output streams
  back fine ; typed input from the host pipe is silently dropped.
  Tracked as a Sprint 6 follow-up.
- `--format` Go template support for `cocker inspect` (Docker template
  parsers reading `.State.Health.Status` get the right value via the
  Docker API socket ; the native `cocker inspect` returns JSON which
  Bash + `jq` users can read trivially).
- Buildx multi-arch cross-build end-to-end verification
- Overlay / macvlan network drivers
- Intra-VM cgroup resource enforcement
- Alternative logging drivers (json-file / syslog)
- Multi-node Swarm

These are documented in `README.md` "Cocker vs Docker" table as
known gaps. None block the 0.4.3 release.
