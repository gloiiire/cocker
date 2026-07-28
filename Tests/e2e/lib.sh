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
mk_container() {
    local id
    id=$("$COCKER" run -d "$@")
    CREATED_CONTAINERS+=("$id")
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
