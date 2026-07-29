#!/usr/bin/env bash
# 10-attach-flags : -a/--attach actually streams, and streams work off-TTY.
#
# Two things this pins down, both found by running the real commands:
#
#   1. `compose up -a SERVICE` restricts log streaming to that service.
#      Docker's `--attach` RESTRICTS an aggregate that is already on by
#      default; implementing it as "enable for these" looks right with one
#      service and is wrong with two.
#   2. Streaming commands wrote NOTHING when redirected. stdout is
#      block-buffered off-TTY and a follow stream never closes, so
#      `compose up -a web > log.txt` produced 0 bytes indefinitely.
#      This scenario runs redirected on purpose — a TTY would hide it.
#   3. `start -a` used to declare the flag and never read it.
#   4. `compose logs -f` keeps each line whole, behind exactly one container
#      prefix, and leaks no interactive key hint into redirected output.
#   5. `cocker attach` keeps following after its initial backlog. The old
#      daemon sent the last 20 lines, then only waited for the VM to stop;
#      output produced after the client attached was silently lost.
#
# On (4): the line-splitting bug underneath it (Swift treats "\r\n" as a
# single Character, so `contains("\n")` is false and CRLF output never
# splits) is pinned precisely by LineBufferTests / LineEndingsTests, which
# fail against the old implementation. Here the observable end-user
# guarantee is asserted instead: whole lines, one prefix, clean pipe.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "10 attach flags"
require_cockerd

tmp=$(mktemp -d)
cname="cocker-e2e-attach-$$"
cleanup() {
    rc=$?
    pkill -f "compose up -a alpha" >/dev/null 2>&1 || true
    pkill -f "compose logs -f" >/dev/null 2>&1 || true
    pkill -f "cocker attach $cname" >/dev/null 2>&1 || true
    ( cd "$tmp" && "$COCKER" compose down >/dev/null 2>&1 ) || true
    "$COCKER" rm -f "$cname" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    on_exit "$rc"
}
trap cleanup EXIT

cat >"$tmp/docker-compose.yml" <<'EOF'
services:
  alpha:
    image: alpine:latest
    # $$i, not $i : compose expands $VAR itself, so $i would reach the shell
    # empty and every line would print a bare "ALPHA-".
    command: ["/bin/sh", "-c", "for i in 1 2 3 4 5 6; do echo ALPHA-$$i; sleep 1; done; sleep 120"]
  beta:
    image: alpine:latest
    command: ["/bin/sh", "-c", "for i in 1 2 3 4 5 6; do echo BETA-$$i; sleep 1; done; sleep 120"]
EOF

# ---------------------------------------------------------------- 1/4
echo " → 1/4 compose up -a restricts streaming (and works redirected)"
( cd "$tmp" && "$COCKER" compose up -a alpha ) >"$tmp/attached.log" 2>&1 &
seen_alpha=0
for _ in $(seq 1 60); do
    if grep -q 'ALPHA-' "$tmp/attached.log"; then
        seen_alpha=1
        break
    fi
    sleep 1
done
# Leave a short observation window in which an incorrectly attached beta
# would also have time to print.
sleep 3
pkill -f "compose up -a alpha" >/dev/null 2>&1 || true
sleep 1

if [ ! -s "$tmp/attached.log" ]; then
    echo "attached up wrote nothing when redirected (stdout never flushed)" >&2
    exit 1
fi
if [ "$seen_alpha" -ne 1 ]; then
    echo "the attached service produced no output" >&2
    cat "$tmp/attached.log" >&2
    exit 1
fi
if grep -q 'BETA-' "$tmp/attached.log"; then
    echo "-a alpha still streamed beta — --attach must RESTRICT" >&2
    cat "$tmp/attached.log" >&2
    exit 1
fi

( cd "$tmp" && "$COCKER" compose down ) >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 2/4
echo " → 2/4 compose logs -f: one prefix per line, clean when redirected"
( cd "$tmp" && "$COCKER" compose up -d ) >/dev/null 2>&1
logs_ready=0
for _ in $(seq 1 60); do
    ( cd "$tmp" && "$COCKER" compose logs ) >"$tmp/readiness.log" 2>&1 || true
    if grep -q 'ALPHA-' "$tmp/readiness.log"; then
        logs_ready=1
        break
    fi
    sleep 1
done
if [ "$logs_ready" -ne 1 ]; then
    echo "alpha never produced output before compose logs -f" >&2
    cat "$tmp/readiness.log" >&2
    exit 1
fi
( cd "$tmp" && "$COCKER" compose logs -f ) >"$tmp/logs.log" 2>&1 &
sleep 8
pkill -f "compose logs -f" >/dev/null 2>&1 || true
sleep 1

# Container output ends in CRLF, and in Swift "\r\n" is a single Character,
# so `contains("\n")` is false. Line splitting written in terms of Character
# matched nothing at all: every line stayed buffered and the view was blank.
if ! grep -q 'ALPHA-' "$tmp/logs.log"; then
    echo "compose logs -f produced no output (CRLF line splitting regressed?)" >&2
    head -20 "$tmp/logs.log" >&2
    exit 1
fi

# The prefix is the CONTAINER name (project_service_1), stamped once per
# line. It used to be stamped once per stream *event*, and one line spans
# several events, so the name landed mid-line:
#
#     [proj_alpha_1] ALPHA-2[proj_alpha_1]
#
# Two prefixes on one line is the unambiguous signature. (A line holding
# only a prefix is NOT: containers emit blank lines, and a blank line is
# real output that gets prefixed like any other.)
if grep -qE '\[[a-z0-9_]*alpha[a-z0-9_]*\].*\[[a-z0-9_]*alpha[a-z0-9_]*\]' "$tmp/logs.log"; then
    echo "two container prefixes on one line — prefixing must be per line" >&2
    grep -E '\[[a-z0-9_]*alpha[a-z0-9_]*\].*\[' "$tmp/logs.log" | head -5 >&2
    exit 1
fi

# Every application line must arrive whole, on one line, behind exactly one
# prefix. Which numbers land depends on timing, so assert the shape of all
# of them rather than looking for a particular one.
bad=$(grep 'ALPHA-' "$tmp/logs.log" \
      | grep -cvE '^\[[a-z0-9_]*alpha[a-z0-9_]*\] ALPHA-[0-9]+[[:space:]]*$' || true)
if [ "$bad" -ne 0 ]; then
    echo "$bad ALPHA- line(s) are not a single whole prefixed line" >&2
    grep 'ALPHA-' "$tmp/logs.log" \
      | grep -vE '^\[[a-z0-9_]*alpha[a-z0-9_]*\] ALPHA-[0-9]+[[:space:]]*$' | head -5 >&2
    exit 1
fi
good=$(grep -cE '^\[[a-z0-9_]*alpha[a-z0-9_]*\] ALPHA-[0-9]+[[:space:]]*$' "$tmp/logs.log" || true)
if [ "$good" -lt 3 ]; then
    echo "only $good well-formed ALPHA- lines — expected the stream to carry several" >&2
    head -20 "$tmp/logs.log" >&2
    exit 1
fi

# Redirected output has no keyboard, so the key hint must not appear in it.
# Pinning the footer had put "press d detach" at the top of piped output.
if grep -q 'press' "$tmp/logs.log"; then
    echo "interactive key hint leaked into redirected output" >&2
    grep -n 'press' "$tmp/logs.log" | head -3 >&2
    exit 1
fi

( cd "$tmp" && "$COCKER" compose down ) >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 3/4
echo " → 3/4 start -a streams the container's output"
"$COCKER" run -d --name "$cname" alpine:latest \
    sh -c 'for i in 1 2 3; do echo TICK-$i; sleep 1; done' >/dev/null 2>&1
# Let it exit so `start` has something stopped to restart. A fixed sleep was
# flaky under VM load: boot itself can consume most of the budget, leaving the
# three-second command still running when `start -a` arrives.
status="running"
for _ in $(seq 1 20); do
    status=$("$COCKER" inspect "$cname" --format '{{.State.Status}}' 2>/dev/null || echo unknown)
    [ "$status" != "running" ] && break
    sleep 1
done
if [ "$status" = "running" ]; then
    echo "container did not stop before the start -a check" >&2
    exit 1
fi

"$COCKER" start -a "$cname" >"$tmp/start.log" 2>&1 || true
if ! grep -q 'TICK-' "$tmp/start.log"; then
    echo "start -a printed no container output — the flag is being ignored" >&2
    cat "$tmp/start.log" >&2
    exit 1
fi

# ---------------------------------------------------------------- 4/4
echo " → 4/4 direct attach follows output produced after attachment"
"$COCKER" rm -f "$cname" >/dev/null 2>&1 || true
"$COCKER" run -d --name "$cname" alpine:latest \
    sh -c 'echo ATTACH-BEFORE; sleep 8; echo ATTACH-AFTER; sleep 120' \
    >/dev/null 2>&1

# VM boot time varies a lot when the complete suite has already exercised
# nine scenarios. Start the follow window from an observed container line,
# not from an arbitrary host-side sleep, so ATTACH-AFTER is guaranteed to be
# produced after the client subscribed.
seen_before=0
for _ in $(seq 1 60); do
    if "$COCKER" logs "$cname" 2>/dev/null | grep -q 'ATTACH-BEFORE'; then
        seen_before=1
        break
    fi
    sleep 0.5
done
if [ "$seen_before" -ne 1 ]; then
    echo "container never produced ATTACH-BEFORE" >&2
    exit 1
fi

"$COCKER" attach "$cname" >"$tmp/direct-attach.log" 2>&1 &
sleep 15
pkill -f "cocker attach $cname" >/dev/null 2>&1 || true
sleep 1

if ! grep -q 'ATTACH-BEFORE' "$tmp/direct-attach.log"; then
    echo "direct attach did not replay its initial backlog" >&2
    cat "$tmp/direct-attach.log" >&2
    exit 1
fi
if ! grep -q 'ATTACH-AFTER' "$tmp/direct-attach.log"; then
    echo "direct attach stopped after its backlog — live output was lost" >&2
    cat "$tmp/direct-attach.log" >&2
    exit 1
fi
if grep -q 'press d detach' "$tmp/direct-attach.log"; then
    echo "interactive attach hint leaked into redirected output" >&2
    cat "$tmp/direct-attach.log" >&2
    exit 1
fi
