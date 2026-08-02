# The road to 1.0.0.0

This supersedes the old `ROADMAP.md`, which was written around v0.5.14 and had
drifted two minor versions out of date. That file was never tracked by git —
`.gitignore` keeps markdown out of the repo except for named spec docs — so
this one is added to the exception list alongside the UX charter.

## What 1.0.0.0 promises

Nothing in the repo has ever said what 1.0 would mean, which made it
impossible to know when we were done. It means these four things, and nothing
more:

1. **Cocker never reports success for something that failed.** Exit codes are
   real, destructive operations refuse rather than guess, and a flag that
   can't be honoured says so instead of being ignored.
2. **A Docker client that works against Docker works against cocker, or fails
   loudly.** Not "every endpoint is implemented" — an honest 501 is fine. What
   is not fine is a well-formed request getting a wrong-shaped answer, or a
   filter being ignored so a client acts on data it never asked for.
3. **Your data survives.** Named volumes are not silently unmounted, not
   corrupted by concurrent attach, not deleted out from under a running
   container, and not left dirty on every stop.
4. **The documented surface is the real surface.** `--help`, the man pages and
   the README describe what the binary does, and the release that ships was
   tested.

### Compatibility we commit to at 1.0

- **Docker Engine API floor: v1.41.** Clients negotiating down to 1.41 keep
  working for the whole 1.x line. Endpoints may be added; implemented ones
  won't change shape.
- **CLI flags don't change meaning.** A flag may be added, or deprecated with
  a warning for a full minor cycle, but `cocker run -d` means the same thing
  in 1.9 as in 1.0.
- **On-disk state migrates forward.** `~/.cocker/state.json` carries a schema
  version and a 1.x daemon reads anything a 1.x daemon wrote. Downgrades are
  not supported.

### The version scheme

`MAJOR.MINOR.PATCH.BUILD` — four segments, which is not semver and has never
been documented.

- `MAJOR` — a break in any of the three commitments above.
- `MINOR` — new capability.
- `PATCH` — bug fixes.
- `BUILD` — a re-release of the same intended content: a bottle refresh, a
  packaging fix, a release-pipeline retry. No behaviour change.

`VERSION` is the source of truth; `scripts/bump-version.sh` propagates it.

---

## Milestones

### v0.8 — "Never lie" ✅

Every item here was a case of cocker reporting success for something that
failed, or losing data. Shipped in #357.

| | |
|---|---|
| ✅ | Exit codes propagate — `run`, `wait`, `exec`, and the Docker API's `/wait` and `/exec/{id}/json`, all of which returned a hardcoded 0 |
| ✅ | `?filters=` honoured on every list endpoint — compose identified its containers by label and received every container on the host, so `compose down` could tear down another project |
| ✅ | Volume mount failure is fatal in the guest instead of starting with nothing mounted |
| ✅ | `e2fsck` on attach, `umount` before power-off — volumes were left dirty on every stop, forever |
| ✅ | Exclusive `flock` on a volume image — two containers could mount the same ext4 read-write |
| ✅ | `volume rm -f` refuses a live container instead of unlinking the image under it |
| ✅ | `exec` can no longer hang forever on the Virtualization.framework callback bug |
| ✅ | `push` no longer crashes the daemon on a registry's `Location` header |
| ✅ | ~15 flags that parsed, appeared in `--help`, and did nothing |

### v0.9 — "Actually Docker-compatible"

| | |
|---|---|
| ✅ | Chunked request bodies — the real `docker build` streams its context chunked, so the build context arrived empty and every build failed (#358) |
| ✅ | `/volumes/*` no longer eaten by the API-version strip; `/networks/{id}` and `/volumes/{name}` no longer dead code; registry-qualified image names no longer 501 (#358) |
| ✅ | Compose long syntax, `build:` shorthand, `entrypoint:`, shell-form `command:`, udp/range/host-IP ports (#358) |
| ✅ | `/containers/{id}/archive` — Dev Containers can't inject the VS Code server without it |
| ✅ | **Interactive TTY** — `run -it`, `exec -it` and `compose exec -it` work. Verified on an M3 Max: 5/5 interactive shell sessions, exit codes propagate through the shell (`exit 7` → 7), Ctrl-D reaches the container. Still missing: SIGWINCH mid-session, and `attach` |
| ⬜ | Hijacked raw streams on the API side, plus `/attach` and `/resize`. Today exec output is chunk-framed, so chunk headers land inside the stdcopy stream and corrupt it. (The *native* CLI path works — this is the Docker-socket surface) |
| ✅ | Multiple `-f` / `override.yml` merging, and `--profile` |

### v0.10 — "Focus"

| | |
|---|---|
| ⬜ | **Decide the punt.** `ROADMAP.md` said to cut `swarm`/`stack`/`service`/`node` in v0.5 and it never happened — 23 commands still ship, still lead the help screen, and some invent data (`node ls` returns a fresh UUID per call). This is a breaking change for anyone scripting them, so it needs a decision, not a patch |
| ⬜ | README: the tagline still never adopted the iCloud positioning, and iCloud — the actual differentiator — first appears at line 427 of 677. (The broken `cocker completion` lines, the hardcoded test count and the contradictory API version are fixed.) |
| ✅ | `docs/man/` regenerated (145 → 159 pages) and `bump-version.sh` keeps it current |
| ⬜ | **Decide the `*.md` policy.** `.gitignore` deliberately keeps every markdown file out of the repo except `README.md` and named spec docs, so there is no `CHANGELOG.md`, `CONTRIBUTING.md` or `SECURITY.md` by choice rather than by oversight. A 1.0 arguably needs at least a changelog — a user currently cannot tell what changed between `0.7.13.19` and `0.7.13.26` — and a security file, since cocker installs a root LaunchDaemon and stores registry passwords in plaintext at `~/.cocker/credentials.json`. Either add exceptions for those three or write down why they live outside the repo |
| ✅ | `cockerd` and the `daemon` command group now use the charter §6 block, shared with the CLI rather than copied. The 125/126/127 taxonomy reaches scripts — it was flattened both by the IPC layer dropping the error kind and by commands throwing a blanket 1. (`exit(64)` stays: it's a documented EX_USAGE for schema-too-new, deliberately preserved.) |

### v1.0.0.0 — "Guaranteed"

| | |
|---|---|
| ⬜ | **Run the e2e suite in CI.** The job targets a self-hosted `vm-capable` runner that doesn't exist, and is explicitly designed never to block a PR. Needs one M-series Mac — hosted runners are M1/M2 VMs and nested virtualisation is M3+, so this is hardware, not configuration |
| ✅ | **Releases gated on tests.** `build-and-sign` now `needs: test` — `swift test` plus a cocker-init cross-compile and its C test, which `swift test` never covered |
| 🚧 | e2e coverage. Added `11-exit-codes` and `12-exec-after-start`; suite is 12/12 green on real hardware. Still uncovered: registry push/pull, block volumes, `compose down`, `logs -f`, volume/network lifecycle |
| ✅ | Coverage reports two numbers — the gated scope and all of `Sources/` — and says which is which |
| ⬜ | This document's commitments written into the README, and a deprecation policy |

---

## Explicitly not in 1.0

- Swarm-mode orchestration in any real form.
- BuildKit. Anything forcing `DOCKER_BUILDKIT=1` — `buildx`, compose cache
  mounts, heredocs — fails today and will keep failing; there is no `/session`
  endpoint and no plan for one.
- Overlay/macvlan network drivers. `-d overlay` is accepted and coerced to
  bridge, which is worse than refusing it; that gets fixed by refusing it.
- A persistent VM mode. That's `container machine`'s job.
- Credential helpers (`docker-credential-ecr-login` and friends). Wanted, but
  not a 1.0 blocker.

## Known limitations that ship with 1.0

These are real and documented rather than fixed:


- **Healthchecks go through virtiofs files, not vsock.** Apple's
  `VZVirtioSocketDevice.connect()` doesn't reliably fire its callback when
  called repeatedly from a background context. Report and reproducer in
  `docs/APPLE-FEEDBACK-VSOCK-CALLBACK.md`.
- **~256 concurrent containers.** macOS `bootpd` stops handing out leases past
  a ceiling Apple doesn't expose.
- **100 MiB request-body cap**, which bounds build contexts sent over the
  Docker socket. Lifting it needs streaming-to-disk in the HTTP parser.
- **`COPY --chown` / `--chmod`, `ONBUILD` and `SHELL` are not applied.** They
  warn rather than silently changing the image.
