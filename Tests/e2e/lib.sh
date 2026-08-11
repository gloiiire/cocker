#!/usr/bin/env bash
# Common helpers for the cocker E2E scripts.

set -euo pipefail

COCKER=${COCKER:-cocker}

# Print PASS/FAIL summary + cleanup hook
on_exit() {
    rc=${1:-$?}
    # Best-effort cleanup of any container the test created via mk_container.
    for c in "${CREATED_CONTAINERS[@]:-}"; do
        $COCKER rm -f "$c" >/dev/null 2>&1 || true
    done
    if [ -n "${CLEANUP_FILE:-}" ] && [ -f "$CLEANUP_FILE" ]; then
        while read -r c; do
            [ -n "$c" ] && $COCKER rm -f "$c" >/dev/null 2>&1 || true
        done < "$CLEANUP_FILE"
        rm -f "$CLEANUP_FILE"
    fi
    if [ "$rc" -eq 0 ]; then
        echo "==> PASS : $TEST_NAME"
    else
        echo "==> FAIL : $TEST_NAME (rc=$rc)"
    fi
}

# Call this once at the top of each script with a short test name.
init_test() {
    TEST_NAME="$1"
    CREATED_CONTAINERS=()
    # mk_container is always called as `x=$(mk_container …)`, i.e. inside a
    # command substitution — a subshell. Anything it appends to the array above
    # dies with that subshell and never reaches on_exit, so the array has in
    # fact been empty for every test that used it. A file crosses the boundary.
    CLEANUP_FILE=$(mktemp "${TMPDIR:-/tmp}/cocker-e2e-cleanup.XXXXXX")
    trap on_exit EXIT
    echo "==> RUN  : $TEST_NAME"
}

# Check cockerd is reachable. Skip the test cleanly if not — we don't want
# to fail loudly on a workstation where cockerd happens to be down.
require_cockerd() {
    if ! $COCKER ping >/dev/null 2>&1 && ! $COCKER info >/dev/null 2>&1; then
        echo "==> SKIP : $TEST_NAME (cockerd unreachable)"
        exit 0
    fi
}

# Create a named container and remember it for cleanup.
# Register the requested --name for cleanup BEFORE creating anything.
#
# `run -d` can leave a container behind while printing no id — a name clash
# is the common way. The old version recorded only the id, so on that path
# CREATED_CONTAINERS stayed empty, the container survived the test, and every
# later run failed on the same clash. Measured: 02-inter-container-by-ip
# failed identically three runs in a row with "container cocker-e2e-srv never
# became running", and passed the moment a leftover cocker-e2e-srv was removed
# by hand. A test that poisons its own next run reads as a code regression.
mk_container() {
    local id name="" i j
    for ((i = 1; i <= $#; i++)); do
        if [ "${!i}" = "--name" ]; then j=$((i + 1)); name="${!j}"; break; fi
    done
    [ -n "$name" ] && echo "$name" >> "$CLEANUP_FILE"
    id=$("$COCKER" run -d "$@")
    # Failing here beats failing 20s later in wait_running: that message names
    # the container, not the reason it was never created.
    if [ -z "$id" ]; then
        echo "mk_container: '$COCKER run -d $*' produced no container id" >&2
        return 1
    fi
    echo "$id" >> "$CLEANUP_FILE"
    echo "$id"
}

# Wait until a container reports the expected status (default: running).
wait_running() {
    local name="$1"
    local timeout="${2:-20}"
    for _ in $(seq 1 "$timeout"); do
        status=$("$COCKER" inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "?")
        [ "$status" = "running" ] && return 0
        sleep 1
    done
    echo "container $name never became running" >&2
    return 1
}

# Run a command inside a container and capture stdout.
in_container() {
    local name="$1"; shift
    "$COCKER" exec "$name" "$@"
}
