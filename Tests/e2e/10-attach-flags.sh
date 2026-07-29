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
    command: ["/bin/sh", "-c", "for i in 1 2 3 4 5 6; do echo ALPHA-$i; sleep 1; done; sleep 120"]
  beta:
    image: alpine:latest
    command: ["/bin/sh", "-c", "for i in 1 2 3 4 5 6; do echo BETA-$i; sleep 1; done; sleep 120"]
EOF

# ---------------------------------------------------------------- 1/2
echo " → 1/2 compose up -a restricts streaming (and works redirected)"
( cd "$tmp" && "$COCKER" compose up -a alpha ) >"$tmp/attached.log" 2>&1 &
sleep 14
pkill -f "compose up -a alpha" >/dev/null 2>&1 || true
sleep 1

if [ ! -s "$tmp/attached.log" ]; then
    echo "attached up wrote nothing when redirected (stdout never flushed)" >&2
    exit 1
fi
if ! grep -q 'ALPHA-' "$tmp/attached.log"; then
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

# ---------------------------------------------------------------- 2/2
echo " → 2/2 start -a streams the container's output"
"$COCKER" run -d --name "$cname" alpine:latest \
    sh -c 'for i in 1 2 3; do echo TICK-$i; sleep 1; done' >/dev/null 2>&1
# Let it run and exit so `start` has something stopped to restart.
sleep 6

"$COCKER" start -a "$cname" >"$tmp/start.log" 2>&1 || true
if ! grep -q 'TICK-' "$tmp/start.log"; then
    echo "start -a printed no container output — the flag is being ignored" >&2
    cat "$tmp/start.log" >&2
    exit 1
fi
