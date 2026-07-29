#!/usr/bin/env bash
# 09-ctrl-c-during-build : Ctrl-C must interrupt a compose-watch rebuild.
#
# Reported from real use : `cocker compose watch` ignored Ctrl-C while a
# rebuild was in flight. The footer had installed SIG_IGN, but its replacement
# DispatchSource ran on the main queue, which the rebuild occupied.
#
# This scenario deliberately exercises that exact path:
#   1. start compose watch in a PTY and wait for its interactive footer;
#   2. change the Dockerfile so FSEvents starts a unique long RUN;
#   3. deliver two SIGINTs to the exact watch PID.
#
# The first signal starts graceful teardown. The second is the documented
# "leave now" path and must exit even while the daemon is still building.
# Before SignalTrap moved to its dedicated queue, both signals remained
# starved until the RUN ended.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "09 ctrl-c during build"
require_cockerd

python=$(command -v python3 || true)
if [ -z "$python" ]; then
    echo "python3 is required to reset inherited signal dispositions" >&2
    exit 1
fi

tmp=$(mktemp -d)
project="$tmp/project"
proj="ctrlc$$"
container_name="${proj}_slow_1"
watch_pid=""
script_pid=""

cleanup() {
    rc=$?

    # Only stop processes created by this scenario. The previous test used a
    # global pgrep/pkill and could signal another CI run, leaving its own build
    # VM alive to break the following DHCP scenario.
    if [ -n "${watch_pid:-}" ] && kill -0 "$watch_pid" 2>/dev/null; then
        kill -TERM "$watch_pid" 2>/dev/null || true
        sleep 0.2
        kill -KILL "$watch_pid" 2>/dev/null || true
    fi
    if [ -n "${script_pid:-}" ] && kill -0 "$script_pid" 2>/dev/null; then
        kill -TERM "$script_pid" 2>/dev/null || true
        sleep 0.2
        kill -KILL "$script_pid" 2>/dev/null || true
    fi
    [ -n "${watch_pid:-}" ] && wait "$watch_pid" 2>/dev/null || true
    [ -n "${script_pid:-}" ] && wait "$script_pid" 2>/dev/null || true

    # The first SIGINT queues compose down behind the active ComposeEngine
    # build. Wait for that teardown instead of queuing a second compose down,
    # which used to add another full stop timeout to every test run.
    removed=0
    for _ in $(seq 1 25); do
        if ! "$COCKER" inspect "$container_name" >/dev/null 2>&1; then
            removed=1
            break
        fi
        sleep 1
    done
    if [ "$removed" -ne 1 ]; then
        "$COCKER" rm -f "$container_name" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
    on_exit "$rc"
}
trap cleanup EXIT

mkdir -p "$project"
printf 'initial\n' >"$project/marker.txt"

# Initial build has no RUN VM, so reaching the watch footer is quick.
cat >"$project/Dockerfile" <<'EOF'
FROM alpine:latest
COPY marker.txt /marker
CMD ["/bin/sh", "-c", "exit 0"]
EOF

cat >"$project/docker-compose.yml" <<'EOF'
services:
  slow:
    build:
      context: .
      dockerfile: Dockerfile
EOF

echo " → starting compose watch"

# Bash starts asynchronous jobs with SIGINT/SIGTERM ignored. A child cannot
# reliably undo an inherited SIG_IGN with `trap -`, so this tiny Python launcher
# restores the default dispositions, writes its own PID, then execs cocker.
# `script` supplies the PTY required for the interactive footer under test.
script -q "$tmp/watch.pty" "$python" -c '
import os, signal, sys
open(sys.argv[1], "w").write(str(os.getpid()))
for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, signal.SIG_DFL)
os.chdir(sys.argv[2])
os.execv(sys.argv[3], sys.argv[3:])
' "$tmp/watch.pid" "$project" "$COCKER" compose watch --project-name "$proj" --debounce-ms 100 \
    >"$tmp/watch.outer" 2>&1 &
script_pid=$!

# Wait until InteractiveFooter is installed. Sending SIGINT before this point
# would only test the kernel's default disposition, not SignalTrap.
watching=0
for _ in $(seq 1 90); do
    if [ -s "$tmp/watch.pid" ] && grep -q "Watching" "$tmp/watch.pty" 2>/dev/null; then
        watch_pid=$(cat "$tmp/watch.pid")
        watching=1
        break
    fi
    kill -0 "$script_pid" 2>/dev/null || break
    sleep 1
done

if [ "$watching" -ne 1 ]; then
    echo "compose watch never reached its interactive footer" >&2
    cat "$tmp/watch.pty" >&2
    exit 1
fi

# Rewrite the Dockerfile after FSEvents is listening. The per-run value makes
# the long layer uncacheable, so the test cannot silently become instant.
cat >"$project/Dockerfile" <<EOF
FROM alpine:latest
COPY marker.txt /marker
RUN echo "$proj" > /run-id && sleep 12 && echo built > /marker2
CMD ["/bin/sh", "-c", "exit 0"]
EOF

# The raw watch renderer writes each Dockerfile step directly in the PTY. This
# proves the rebuild reached the unique long RUN before we send the signals.
rebuilding=0
for _ in $(seq 1 60); do
    if grep -q "RUN echo.*$proj.*sleep 12" "$tmp/watch.pty" 2>/dev/null; then
        rebuilding=1
        break
    fi
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 1
done

if [ "$rebuilding" -ne 1 ]; then
    echo "compose watch never reached the long rebuild step" >&2
    cat "$tmp/watch.pty" >&2
    exit 1
fi

echo " → rebuild running (pid $watch_pid), sending two SIGINTs"
kill -INT "$watch_pid" 2>/dev/null || true
sleep 1
kill -INT "$watch_pid" 2>/dev/null || true

# The second Ctrl-C is the immediate-exit contract. With the old main-queue
# handler the process remains alive until the RUN completes.
for _ in $(seq 1 5); do
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 1
done

if kill -0 "$watch_pid" 2>/dev/null; then
    echo "SIGINT ignored — compose watch is still alive during the rebuild" >&2
    echo "(the signal handler is starved or did not receive the exact PID)" >&2
    exit 1
fi

wait "$script_pid" 2>/dev/null || true
script_pid=""
echo " → interrupted cleanly"
