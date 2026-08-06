# Changelog

Notable changes per release. Versions are `MAJOR.MINOR.PATCH.BUILD` — see
[`docs/ROADMAP-1.0.md`](docs/ROADMAP-1.0.md) for what each segment means and what
1.0 commits to.

Entries describe what changed for *you*, not what moved in the code. A user
should be able to read one line and know whether it affects them.

## 1.1.0.1 — 2026-08-05

### Fixed

- **`cocker daemon restart` could leave two daemons running on the same
  data directory.** Both printed "Daemon is running", both wrote the same
  `state.json`, and which one answered a given command was a coin flip —
  with a real risk of losing containers to concurrent writes.

  It happened whenever cocker was started through `brew services`, which is
  the documented way: macOS relaunches the daemon within a second of it
  being stopped, and `restart` then started a second one because the check
  guarding against that read a process id which is briefly stale during any
  restart.

  Starting a second daemon on a directory another one owns is now refused
  outright, and says which process holds it. `cocker daemon restart` also
  routes through `brew services` when that's what manages the daemon,
  instead of working against it.

## 1.1.0.0 — 2026-08-05

Networking. Three things cocker claimed and didn't do, and one ceiling it
shouldn't have had.

### Added

- **Networks actually isolate.** `cocker network create` accepted a name, a
  driver, a subnet and a gateway, stored all of it, and enforced none of it:
  every container sat on one flat segment and DNS resolved globally, so two
  "separate" networks reached each other and resolved each other by name. If
  you split two stacks apart for isolation, you got none, and nothing said
  so. Traffic between networks is now dropped by the switch — **including
  when the container already knows the address** — and DNS only resolves
  names on your own network.

- **No more ~256-container ceiling.** macOS hands each container VM an IP
  from a lease pool that is host-wide, capped at roughly 256 entries, never
  reclaimed, and owned by root. The limit was therefore cumulative rather
  than concurrent: after 256 containers over the machine's lifetime, every
  `cocker run` failed to get an address and only someone with root could
  clear it. Containers now assign their own address and ask for no lease.
  `COCKER_STATIC_ETH0=0` goes back to DHCP if something else on your machine
  owns that subnet.

### Fixed

- **`cocker inspect` and the Docker API reported an IPv6 address that
  existed nowhere.** cocker computed `fd00:c0c4::…` for every container,
  stored it, and — worse than the display — **answered DNS with it**. Any
  client trying IPv6 first got a confident answer pointing at an interface
  that does not exist. Removed.

- **The Docker API reported Docker's default bridge, not cocker's network.**
  `IPAddress: 172.17.0.2`, `Gateway: 172.17.0.1` — addresses cocker never
  creates. A client reading `Gateway` and dialling it reached nothing.

- **`/etc/hosts` carried a placeholder address** on images that don't ship
  their own, because it was written before the real address was known.

- **Two containers could end up with the same IP** after a daemon restart.
  Allocation was a counter held in memory: restart cockerd and it began
  again from the start of the range while surviving containers still held
  those addresses. It now allocates from what is actually in use, read from
  persisted state, and refuses when the range is full rather than wrapping
  around onto somebody else's address.

### Changed — may break a script

- **`cocker network create --subnet` / `--gateway` now fail** (exit 126)
  instead of being accepted and ignored. Containers always drew from one
  shared address range regardless of what you asked for. Networks isolate
  now but still share that range, so honouring a custom subnet needs an
  allocator that doesn't exist yet. Drop the flag to create the network.

## 1.0.1.0 — 2026-08-02

### Fixed

- **`cocker daemon helper-install` said the helper was running without ever
  checking.** It printed "✓ Helper installed and running." whenever its shell
  exited 0 — and `launchctl load` exits 0 even when it loads nothing. Writing
  the config file is not the same as having a running service, and the command
  couldn't tell the difference. Seen in the field: a helper installed in June,
  never present in `launchctl list`, its log 0 bytes, and a user who had been
  told it was fine.

  This is the root of the lease-pool failures fixed in 1.0.0.0 rather than
  another instance of them: every one of those checks trusted this claim, so
  a saturated pool produced no diagnostics at all and containers failed to get
  an IP in silence.

  The command now proves it: it asks the helper for a clear and confirms the
  trigger file gets consumed, which only a live helper does. It reports the
  resulting lease count, or tells you the helper is installed but not
  responding and how to inspect it. As a side effect it actually clears the
  pool — which is why you ran it.

## 1.0.0.0 — 2026-08-02

The 1.0 correctness pass. Almost everything here is a case where cocker either
reported success for something that failed, or lost data quietly. Verified on
Apple silicon against real VMs.

### Fixed — cocker was reporting success for failures

- **`cocker run img false` exited 0.** The foreground path never read the
  container's exit code. `run`, `wait`, `exec`, `compose exec` and the Docker
  API's `/wait` and `/exec/{id}/json` all report the real code now. Anything
  that shelled out to cocker in CI was passing unconditionally.
- **`docker compose down` could tear down another project.** `?filters=` was
  ignored on every list endpoint, so compose — which identifies its containers
  purely by label — received every container on the host and treated the rest
  as orphans.
- **The 125/126/127 exit codes were flattened to 1.** Both by the IPC layer
  dropping the error's kind and by commands throwing a blanket failure. A
  script can now tell "no such container" (127) from "the daemon is down" (125).
- **`login` never contacted the registry**, so a typo'd password "succeeded".
- **`context create --docker host=tcp://…`** was accepted and silently routed
  to the local daemon. **`network create -d overlay`** silently gave you a
  bridge. Both refuse now.
- **`node ls` invented a fresh UUID on every call**; `buildx ls` claimed a
  BuildKit builder that doesn't exist; `container diff` marked the whole
  filesystem as changed; `/containers/{id}/top` reported the same fake process
  for every container. All either implemented properly or failing honestly.
- **`cocker daemon clear-leases` cleared nothing and exited 0.** macOS stops
  handing out container IP addresses past ~256 leases, and this is the command
  the daemon's own error message tells you to run. It asked a root helper that
  wasn't listening, ignored the failure, printed the *unchanged* count and
  reported success — measured: 317 leases before, "Leases now: 317 entries.",
  exit 0, 317 after. The safety net around it had the same flaw and was worse:
  because it treated "the helper's config file exists" as "the helper works",
  an installed-but-never-loaded helper silenced *both* the automatic cleanup
  and the warning, so containers failed to get an IP with nothing logged at
  all. All three now report whether the helper actually answered.

### Fixed — data loss

- **A failed volume mount only logged a warning**, so the container started
  with nothing mounted and wrote into the ephemeral rootfs. Everything was
  gone at removal, silently. Fatal now.
- **No filesystem check ever ran, and volumes were never unmounted** before
  power-off — every volume was left dirty on every stop, forever.
- **Two containers could mount the same volume image read-write.**
- **`volume rm --force` deleted a volume out from under a running container.**
- **`--shm-size` was dropped on every state reload**, so a database that asked
  for 1 GiB of `/dev/shm` quietly got the default back after a daemon restart.

### Fixed — things that never worked

- **`cocker exec` failed for a window after every container start.** Measured:
  20 consecutive plain `exec` calls all failed on a fresh container.
- **`cocker buildx` was entirely broken** — a malformed flag declaration made
  every subcommand, including `--help`, fail before running.
- **The real `docker build` sent an empty context.** Request bodies arrive
  chunked and the parser only read `Content-Length`.
- **`docker-compose.override.yml` was ignored**, as were extra `-f` files.
- **`build: ./dir`, long-syntax `ports`/`volumes`/`env_file`** rejected the
  entire compose file. `entrypoint:` was parsed and discarded. `command:` in
  string form was never shell-wrapped, so it couldn't run.
- **`profiles:` made a service unstartable** — nothing populated the active set,
  and there was no `--profile` flag.
- **`cocker exec` couldn't see the container's environment.**
- **`/containers/{id}/archive` was 501**, so Dev Containers couldn't inject the
  VS Code server and `docker cp` didn't work.

### Added

- **Interactive terminals.** `run -it`, `exec -it`, `compose exec -it` and
  `attach` all carry keystrokes, propagate exit codes, and follow window
  resizes. Previously `exec -it` printed a warning saying typed input would
  not reach the container.
- **`cocker wait`.**
- Docker API: `/containers/{id}/attach`, `/resize`, `/exec/{id}/resize`, and
  hijacked raw streams so exec output is no longer corrupted by chunk framing.
- `compose --profile` (and `COMPOSE_PROFILES`), repeatable `-f` with override
  merging, `build.target`.

### Changed

- **Releases are gated on tests.** A tag used to be built, signed, attested and
  published to the Homebrew tap without `swift test` ever running on it.
- `swarm`, `stack`, `service`, `node` and `buildx` no longer appear in
  `cocker --help`. The commands still exist and still parse.
- Man pages are regenerated on every version bump — they had been frozen at
  v0.5.0, and 14 commands had no page at all.
- Coverage reporting publishes two numbers: the gated scope and all of
  `Sources/`.

### Known limitations

See [`docs/ROADMAP-1.0.md`](docs/ROADMAP-1.0.md). In short: healthchecks go
through virtiofs rather than vsock; roughly 256 concurrent containers; a
100 MiB cap on request bodies sent to the Docker socket; `COPY --chown`,
`--chmod`, `ONBUILD` and `SHELL` are parsed but not applied (they warn).

> **Superseded.** The ~256 figure was cumulative, not concurrent — macOS never
> reclaimed the lease entries — and it stopped applying in 1.1.0.0, where
> containers assign their own `eth0` address and take no lease at all.
