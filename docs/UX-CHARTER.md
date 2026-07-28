# Cocker — UX Charter

> The single source of truth for how every `cocker` command should look on screen.
> If you're adding or refactoring a command, this is the document you read first.

**Status** : draft — target release `0.7.0 "Polished"`
**Scope** : every CLI command without exception (~93 commands across 16 categories).

---

## 1. Why this exists

Today, cocker's commands feel like they were each written by a different person on a different day. Some print colored status, some don't. Some say "Successfully built", others just echo an ID, others stay silent. Tables don't share column gaps. Errors are one-liners with no hint. The result : it works, but it doesn't **feel** like a single, deliberately-designed product.

The goal of this charter is simple : **every command should look like it was designed by the same person, in the same moment, with the same taste.** And that taste should be one notch above Docker.

---

## 2. Five principles

1. **Predictable.** The same symbol, the same color, the same verb means the same thing everywhere.
2. **Explicit.** Always name what's happening (`Container web_1`, not `web_1`). Always show elapsed time when an action takes more than ~0.5s.
3. **Honest about failure.** Every error answers three questions : *what failed*, *why*, *how to fix*.
4. **Pipe-safe.** When the output is not a terminal (redirected to a file, piped to `grep`...), drop colors, drop animations, drop cursor tricks. The plain text must be perfectly clean.
5. **Quiet beats noisy.** Don't print a status line for an operation that completes in < 100ms unless the user explicitly asked (`--verbose`).

---

## 3. The token system

The charter is built on a small set of **tokens** (icons, colors, verbs). Tokens are defined in **one** place in the code and reused everywhere — no command invents its own.

### 3.1 Icons

| Icon | Meaning | When to use |
|------|---------|-------------|
| `✓`  | Success, terminated OK | After any action that completed successfully |
| `✗`  | Failure | After any action that failed |
| `⠋`  | In progress (animated spinner) | While an action is running |
| `→`  | Action in progress (static, used in tables) | When the spinner can't animate in a sticky context |
| `•`  | Neutral list item | List/table rows, no status implied |
| `⚠`  | Warning, attention required | Non-fatal but the user should look |
| `↻`  | Restart, retry, change detected | `compose watch` rebuilds, healthcheck retries |
| `?`  | Interactive prompt | Beginning of `[y/N]` confirmation lines |

The spinner uses the **Braille frames** : `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` at ~80ms per frame.

### 3.2 Colors

| Token        | ANSI       | Used for |
|--------------|------------|----------|
| `success`    | green      | `✓` icon, "Started", "Built", "Pulled", positive numbers |
| `failure`    | red        | `✗` icon, error messages, exit codes ≠ 0 |
| `progress`   | cyan       | `⠋` spinner, `→` arrow, "Starting", "Pulling" verbs |
| `warn`       | yellow     | `⚠` icon, "deprecated", drift warnings |
| `restart`    | yellow     | `↻` icon, "Rebuilding", "Restarting" |
| `accent`     | magenta    | Container IDs, image hashes (the short hex bits) |
| `dim`        | gray       | Timestamps, elapsed timers, secondary info |
| `default`    | (none)     | Body text, user data |

### 3.3 Verbs (the lexicon)

| Action  | While running   | Done            |
|---------|-----------------|-----------------|
| start   | `Starting`      | `Started`       |
| stop    | `Stopping`      | `Stopped`       |
| build   | `Building`      | `Built`         |
| pull    | `Pulling`       | `Pulled`        |
| push    | `Pushing`       | `Pushed`        |
| remove  | `Removing`      | `Removed`       |
| create  | `Creating`      | `Created`       |
| connect | `Connecting`    | `Connected`     |
| restart | `Restarting`    | `Restarted`     |
| pause   | `Pausing`       | `Paused`        |
| inspect | `Inspecting`    | (no end verb — output IS the result) |
| commit  | `Committing`    | `Committed`     |
| export  | `Exporting`     | `Exported`      |
| import  | `Importing`     | `Imported`      |
| tag     | (instant)       | `Tagged`        |
| rebuild | `Rebuilding`    | `Rebuilt`       |

**Rule** : present continuous while running, simple past when done. Never "Successfully X" (Docker does this, it's noise). Never localize to a different tense.

### 3.4 Object types (the nouns)

| Type        | Width (chars) | Examples |
|-------------|---------------|----------|
| `Container` | 9             | `Container myapp_web_1` |
| `Image`     | 9             | `Image    nginx:latest` |
| `Network`   | 9             | `Network  myapp_default` |
| `Volume`    | 9             | `Volume   myapp_data` |
| `Service`   | 9             | `Service  api` |
| `Secret`    | 9             | `Secret   db_password` |
| `Config`    | 9             | `Config   nginx_conf` |
| `Plugin`    | 9             | `Plugin   logging-driver` |
| `Daemon`    | 9             | `Daemon   cockerd` |
| `Context`   | 9             | `Context  production` |

**Rule** : always type-then-name, type left-padded to 9 chars (longest is `Container`). Type itself is `dim`, name is `default` color. Allows perfect column alignment across multi-line output.

---

## 4. The universal action line

Every action a command performs renders as a line in this shape :

```
 <icon> <Type>     <name>              <verb/status>     <timing-or-detail>
```

Five fields, three of them aligned to fixed columns :

```
 ✓ Container  myapp_web_1         Started            1.8s
 ⠋ Image      nginx:latest        Pulling            [████████░░] 12 MB / 18 MB
 ✗ Network    legacy_net          Remove failed
   └ reason  : in use by 2 containers
   └ hint    : `cocker network disconnect legacy_net <container>` first
 ↻ Container  myapp_api_1         Rebuilding         3.2s
 • Volume     myapp_data          Already exists
```

**Spacing rule** : single space after icon, two spaces between columns. Timing is right-aligned in its column when displayed in a sticky table.

---

## 5. Tables

All `ls`-style commands (`ps`, `images`, `network ls`, `volume ls`, etc.) share :

- **Header** : bold + dim, single space between columns equal to the longest value in that column + 2.
- **No vertical bars**, no box-drawing borders — Docker style.
- **Empty state** : when the result is empty, no header. Print a single dim italic line :
  ```
   no containers — run `cocker run <image>` to create one
  ```
- **ID columns** : always 12 hex chars max, colored `accent` (magenta).
- **Timestamp columns** : always relative (`3 hours ago`, `2 days ago`), colored `dim`.
- **Status columns** in `ps` : colored according to state — `success` for running, `failure` for exited (≠ 0), `dim` for stopped/created, `warn` for restarting/unhealthy.

Example, `cocker ps` :
```
CONTAINER ID  IMAGE          COMMAND              CREATED         STATUS              PORTS                NAMES
abc123def456  nginx:1.27     "nginx -g 'daemon"   3 hours ago     Up 3 hours          0.0.0.0:80->80/tcp   web
fa9b21c4ee01  postgres:16    "docker-entrypoint"  3 hours ago     Up 3 hours          5432/tcp             db
```

---

## 6. Errors

The single most impactful change in this charter. Every error answers three questions :

```
 ✗ Cannot remove container myapp_db
   reason : container is still running
   hint   : stop it first with `cocker stop myapp_db`
```

- Red `✗` icon + red headline (the *what*).
- Two indented lines for `reason :` and `hint :` (the *why* and *how*).
- `reason` is what the daemon/system actually returned, translated to plain English.
- `hint` is actionable — the exact command to type next when we can guess it.
- When there's truly no hint, omit the line. Don't fake one.

When the error has a stack trace, log file, or correlation ID, mention it on a 4th `details :` line :
```
   details: see ~/.cocker/logs/cockerd.log around 14:32:01 UTC
```

---

## 7. Confirmation prompts

Every destructive command uses the same shape :

```
 ⚠ This will remove 12 containers, 4 networks, 2.3 GB of data.
   Continue? [y/N]
```

- Yellow `⚠` icon, body in default color.
- The summary line is **always** present and quantifies impact (count + size when relevant).
- Default is `N` (capital = default). User presses Enter without typing = abort.
- `--force` / `-f` flag skips the prompt. The summary line is still printed for the log.

---

## 8. Spinners, progress bars, and sticky UI

### 8.1 Spinner

Used when an action is running and we don't know how long it'll take. Single line with `⠋` (animated) + verb + name :

```
 ⠋ Pulling nginx:latest...
```

Replaced in place when done :

```
 ✓ Pulled nginx:latest                                     2.1s
```

### 8.2 Progress bar

Used when we know how much is done out of how much (pulls, downloads, file copies, image saves/loads, iCloud prefetch) :

```
 ⠋ Pulling nginx:latest      [████████████░░░░░░] 12.4 MB / 18.0 MB    65%
```

- Bar width : 18 chars.
- Filled with `█`, empty with `░`.
- Bytes shown in human-readable units (MB, GB), 1 decimal.
- Percentage right-aligned at the end.

### 8.3 Sticky multi-line tables

For `cocker build`, `cocker compose up`, `cocker compose watch` : a multi-line table that **redraws in place** instead of scrolling. Each line follows the universal action-line shape (§4).

Example `cocker build` :
```
 [+] Building 12.3s (5/5) FINISHED
 => [1/5] FROM ubuntu:22.04                              CACHED   0.0s
 => [2/5] RUN apt-get update && apt-get install -y curl           4.2s
 => [3/5] COPY . /app                                             0.1s
 => [4/5] RUN npm install                                         7.8s
 => [5/5] EXPORTING image sha256:abc123...                        0.2s
 ✓ Successfully built sha256:abc123 (5 layers, 142 MB) in 12.3s
```

Example `cocker compose up` :
```
 [+] Running 3/3
 ✓ Network    myapp_default       Created     0.1s
 ✓ Container  myapp_db_1          Started     1.8s
 ✓ Container  myapp_web_1         Started     2.3s
```

### 8.3.1 Service-URL footer

Commands that **start containers publishing ports and then hold the terminal** (`compose up`, `compose watch`, `run --publish`) append a sticky **footer** under the sticky table, redrawn at the bottom after every event so it's always in view without scrolling :

```
 → Running    myapp
   myapp_api_1    http://localhost:8000
   myapp_web_1    http://localhost:3000
   press q quit
```

One `name   http://localhost:<port>` row per published service (name padded, URL in `accent`). The last row is the interactive-keys hint (§9.4). All of this lives in one shared primitive (`UX.InteractiveFooter`) so every holding command looks identical.

### 8.4 Frame budget

Spinners and sticky tables redraw at most every **80ms** (12.5 fps). No matter how fast events arrive, never redraw faster than that — saves CPU and avoids flicker.

---

## 9. Streaming commands (`logs`, `compose logs`, `attach`, `events`)

### 9.1 Per-stream coloring

- `stdout` : default color.
- `stderr` : red dim (the line is still readable, but visually marked as the error stream).

### 9.2 Per-service coloring in `compose logs`

Each service gets a stable color from a rotation of **8 named colors** (cyan, magenta, green, yellow, blue, red, white, gray). The color is derived from a hash of the service name, so it's stable across runs.

Format :
```
web   | GET /api 200 12ms
db    | connection accepted
web   | ERROR: timeout                ← dim red even within the green prefix
```

The service-name prefix is **always padded** to the width of the longest active service name + 1 space + `|` + space.

### 9.3 Timestamps

When `--timestamps` is passed :
```
2026-06-20T14:32:01Z web   | GET /api 200 12ms
```

Timestamp colored `dim`, RFC3339 format, UTC always.

### 9.4 Interactive keys (`d` / `q`)

Every command that **holds the terminal** offers single-keypress controls (cbreak/no-echo via `termios`, `ISIG` kept so Ctrl-C still works). One contract, everywhere — all of it flows through `UX.InteractiveFooter` :

| Key | Meaning | Offered by |
|-----|---------|------------|
| `d` | **Detach** — stop your involvement and **leave everything running**, return the shell. On a start-command the containers stay up under the daemon (`compose watch` also keeps a background watcher, re-attach with `--attach`). On a **viewer** it just stops following. `d` **never stops anything**. | **every** holding command |
| `q` | **Quit for real** — tear down what *this command* started, then return the shell. `compose up` / `watch` → `compose down` (stop + remove the project). `run` → stop the container. | only commands that **start** something : `compose up`, `run`, `compose watch` |
| `Ctrl-C` | `= q` on start-commands (teardown) ; `= d` on viewers (just stop following). Kept working via `ISIG`. | every holding command |

The crux : **`d` never stops anything, `q` never surprises.** A pure viewer (`logs`, `events`) started nothing, so it offers **`d` alone** — there is nothing to "quit for real", and showing `q` there would falsely imply a teardown. A start-command offers **both** (`press d detach · q quit`) because detach-and-leave-running and quit-and-tear-down are genuinely different choices.

Rules :
- **Always restore the terminal** to cooked mode on *every* exit path (`q`, `d`, Ctrl-C, error, normal end). Never leave the shell in raw mode.
- `q` / Ctrl-C teardown runs **async** (an IPC round-trip to the daemon : `composeDown` / `stop`) *before* the process exits ; the footer is erased and a one-line result is printed.
- The hint row reads `press d detach` (viewers) or `press d detach · q quit` (start-commands), `q`/`d` in `accent`, the rest `dim`.
- **Off-TTY** (pipe, CI, redirected) : no raw mode, no hint row, no keys — see §10. `logs -f | grep` must stay clean, and a piped `compose up` never tears down on its own.
- **Never** put stdin in cbreak for commands that forward stdin to a container (`exec -it`, an interactive `attach`) — it would steal the user's keystrokes.

---

## 10. Behavior outside a TTY

When `stdout` is not a terminal (redirected to a file, piped to another command, run in CI without a PTY) :

- **No colors.** Strip every ANSI code.
- **No spinner.** Replace with a single static `→` (or omit entirely if a static line was already printed).
- **No sticky tables.** Print each event on its own line, in chronological order, without cursor movement.
- **No progress bars.** Replace with periodic "12 MB / 18 MB" lines (every ~500ms).

Detection order (first match wins) :
1. `NO_COLOR` env var set (any value) → no color, no animation.
2. `FORCE_COLOR` env var set → color even when not a TTY (useful in CI with color support).
3. `--no-color` flag → no color.
4. `isatty(STDOUT_FILENO) == 0` → no color, no animation, no sticky.

---

## 11. Quiet, verbose, and JSON modes

Every command supports the same three flags :

| Flag         | Behavior |
|--------------|----------|
| `-q, --quiet` | Print only the essential : ID for create commands, nothing for instant operations. No status lines, no headers, no progress. |
| `-v, --verbose` | Print everything : sub-step timings, daemon round-trip duration, debug info that's normally hidden. |
| `--format json` | Emit a stream of JSON objects, one per line (NDJSON). No human formatting at all. For scripting. |

When unsure between two output styles, default to the human-friendly one. `--quiet` and `--format json` are explicit opt-ins for scripting.

---

## 12. macOS system daemons — naming them explicitly

cocker talks to several macOS system daemons. Today, this is invisible to the user. The charter says : **when we interact with one, we say so.** This builds trust and helps debugging.

| Daemon | What it does for us | When to mention it |
|--------|---------------------|--------------------|
| `bird` | iCloud Drive file materialization | When the project path is in iCloud and files need to be downloaded before use |
| `mDNSResponder` | DNS resolution from the host | When `--dns` is used or container DNS misconfigured |
| `configd` | Network configuration (port mapping, routes) | When opening/freeing host ports |
| `launchd` | Daemon process management | When `cocker daemon start/stop/restart` is run |
| `FSEvents` | File-change watcher | When `cocker compose watch` is active |

Example, `cocker compose watch` :
```
 → Watching 3 services (api, web, db)
   ✓ FSEvents listening on /Users/you/myapp
   ✓ bird (iCloud)  /Users/you/myapp is fully materialized

 ↻ Change detected : Sources/api/main.swift
   ⠋ Rebuilding api ...                    2.3s
   ✓ Rebuilt api                           4.1s
   ✓ Restarted myapp_api_1                 0.8s
```

The daemon's name is dim, parenthetical context is dim, and we always confirm what role it plays in plain English.

---

## 13. Before / after

### 13.1 `cocker compose up`

**Before**
```
Starting project myapp...
Created network myapp_default
Starting myapp_db_1...
Container myapp_db_1 Started (id: abc123def4)
Starting myapp_web_1...
Container myapp_web_1 Started (id: fa9b21c4ee)
```

**After**
```
 [+] Running 3/3
 ✓ Network    myapp_default       Created     0.1s
 ✓ Container  myapp_db_1          Started     1.8s
 ✓ Container  myapp_web_1         Started     2.3s
```

### 13.2 `cocker rm myapp_db` on a running container

**Before**
```
Error: cannot remove running container myapp_db
```

**After**
```
 ✗ Cannot remove container myapp_db
   reason : container is still running
   hint   : stop it first with `cocker stop myapp_db`
```

### 13.3 `cocker build`

**Before**
```
Building myimg from ./Dockerfile...
Step 0/5: Parsing Dockerfile
Step 1/5: FROM ubuntu:22.04
Step 2/5: RUN apt update
Step 3/5: COPY . /app
Step 4/5: RUN npm install
Step 5/5: Tagging myimg:latest
Successfully built sha256:abc123def4
```

**After** (sticky, redraws in place)
```
 [+] Building 12.3s (5/5) FINISHED
 => [1/5] FROM ubuntu:22.04                              CACHED   0.0s
 => [2/5] RUN apt-get update && apt-get install -y curl           4.2s
 => [3/5] COPY . /app                                             0.1s
 => [4/5] RUN npm install                                         7.8s
 => [5/5] EXPORTING image sha256:abc123                           0.2s
 ✓ Built sha256:abc123 (5 layers, 142 MB) in 12.3s
```

### 13.4 `cocker daemon status`

**Before**
```
Daemon is running.
```

**After**
```
 ✓ Daemon    cockerd             Running     pid 4218, uptime 3 days
   └ launchd : ~/Library/LaunchAgents/sh.cocker.daemon.plist
   └ logs    : ~/.cocker/logs/cockerd.log
   └ socket  : /var/run/cocker.sock
```

---

## 14. Implementation map

When PR #1 lands, the charter lives in code at :

| Module | Contents |
|--------|----------|
| `Sources/CockerCLI/UX/Tokens.swift`        | Icons, colors, verbs, object types (enum-based) |
| `Sources/CockerCLI/UX/TTY.swift`           | TTY detection, NO_COLOR/FORCE_COLOR, isatty wrappers |
| `Sources/CockerCLI/UX/ActionLine.swift`    | The universal §4 line renderer |
| `Sources/CockerCLI/UX/Table.swift`         | Unified table (replaces TableFormatter) |
| `Sources/CockerCLI/UX/Spinner.swift`       | Braille spinner, 80ms frame budget |
| `Sources/CockerCLI/UX/Progress.swift`      | Progress bar (replaces ProgressReporter) |
| `Sources/CockerCLI/UX/StickyView.swift`    | Multi-line redraw container for build/compose |
| `Sources/CockerCLI/UX/Error.swift`         | Three-line error formatter |
| `Sources/CockerCLI/UX/Confirm.swift`       | Unified [y/N] prompt |
| `Sources/CockerCLI/UX/Stream.swift`        | logs/compose-logs colored prefix, stream coloring |

Each existing command becomes a thin caller of these primitives. **No command may import ANSI codes directly or implement its own table layout** — if a need arises, extend the UX module instead.

---

## 15. Out of scope (for now)

- True parallel build steps (BuildKit DAG) — needs daemon-side work, future release.
- Custom themes (dark/light/high-contrast presets) — possible later, not urgent.
- Mouse interactivity in the sticky views — not worth it for a CLI.
- Internationalization of verbs — English only for v1.

---

*Charter version 1, drafted 2026-06-20. Owner : cocker maintainers. Changes require updating §3–9 in lockstep with code.*
