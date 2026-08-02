#!/usr/bin/env bash
# 12-exec-after-start : exec works immediately, and repeatedly.
#
# Measured before the connect retry landed: 20 consecutive plain `cocker exec`
# calls on a freshly-started container ALL failed with ECONNRESET. The guest
# had already logged "exec-listener ready on vsock port 9000" — it just wasn't
# reachable yet, and a single connect attempt lost that race.
#
# Docker clients exec in loops (CI steps, healthchecks, dev scripts, and
# cocker's own `top`), so this is the shape that actually broke people.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "12 exec immediately after start"
require_cockerd

name="cocker-e2e-execstart-$$"
mk_container --name "$name" alpine:latest -- /bin/sleep 180 >/dev/null
wait_running "$name"

# No settling sleep on purpose — the window right after start is the bug.
ok=0
attempts=20
for _ in $(seq 1 $attempts); do
    out=$($COCKER exec "$name" /bin/echo ping 2>/dev/null | tr -d '\r\n')
    [ "$out" = "ping" ] && ok=$((ok + 1))
done

echo "  $ok/$attempts execs succeeded"
if [ "$ok" -ne "$attempts" ]; then
    echo "exec is unreliable right after container start ($ok/$attempts)" >&2
    exit 1
fi
