#!/usr/bin/env bash
# 09-ctrl-c-during-build : Ctrl-C must interrupt a running build.
#
# Reported from real use : `cocker compose watch` ignored Ctrl-C while a
# rebuild was in flight. Reproduced before the fix — two SIGINTs delivered
# during a `RUN sleep 60`, process still alive, `kill -9` required.
#
# Cause: the footer did `signal(SIGINT, SIG_IGN)` (disarming the kernel's
# terminate-by-default) and installed its replacement handler on the MAIN
# queue, which `await composeUp()` occupies for the whole rebuild. The
# signal arrived and nothing ever handled it.
#
# Only a real process can prove this, hence an e2e scenario rather than a
# unit test.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "09 ctrl-c during build"
require_cockerd

tmp=$(mktemp -d)
proj="cocker-e2e-ctrlc-$$"
cleanup() {
    rc=$?
    pkill -f "compose watch" >/dev/null 2>&1 || true
    "$COCKER" compose -f "$tmp/docker-compose.yml" down >/dev/null 2>&1 || true
    rm -rf "$tmp"
    on_exit "$rc"
}
trap cleanup EXIT

cat >"$tmp/Dockerfile" <<EOF
FROM alpine:latest
# The marker makes this layer unique to this run, so the build cache can
# never turn the long step into an instant cache hit — without it the
# scenario silently tested nothing.
RUN echo "$proj" > /run-id
# Long enough that the SIGINT below lands mid-build, which is the case
# that used to be uninterruptible.
RUN sleep 60 && echo built > /marker
CMD ["/bin/sh", "-c", "sleep 300"]
EOF

cat >"$tmp/docker-compose.yml" <<'EOF'
services:
  slow:
    build:
      context: .
      dockerfile: Dockerfile
EOF

echo " → starting a build in the background"
( cd "$tmp" && "$COCKER" compose up --build ) >"$tmp/build.log" 2>&1 &
shell_pid=$!

# Wait for the build to actually reach the long RUN step.
build_pid=""
for _ in $(seq 1 40); do
    build_pid=$(pgrep -f "compose up --build" | head -1)
    [ -n "$build_pid" ] && grep -q "sleep 60" "$tmp/build.log" 2>/dev/null && break
    sleep 1
done

if [ -z "$build_pid" ]; then
    # Distinguish "never started" from "finished before we looked" — the
    # latter means the scenario tested nothing, which must not read as a
    # pass.
    if grep -q "All services started" "$tmp/build.log" 2>/dev/null; then
        echo "the build completed instantly (cache hit?) — nothing was interrupted" >&2
    else
        echo "the build never started" >&2
    fi
    cat "$tmp/build.log" >&2
    exit 1
fi
echo " → build running (pid $build_pid), sending SIGINT"

kill -INT "$build_pid" 2>/dev/null || true

# A correct implementation restores the terminal, tears down and exits.
# Allow a generous window : teardown talks to the daemon.
for _ in $(seq 1 20); do
    kill -0 "$build_pid" 2>/dev/null || break
    sleep 1
done

if kill -0 "$build_pid" 2>/dev/null; then
    echo "SIGINT ignored — the build is still running after 20s" >&2
    echo "(this is the bug: signal disarmed, handler starved on the main queue)" >&2
    kill -9 "$build_pid" 2>/dev/null || true
    exit 1
fi

wait "$shell_pid" 2>/dev/null || true
echo " → interrupted cleanly"
