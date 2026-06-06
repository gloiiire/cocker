#!/usr/bin/env bash
# 04-port-forwarding : host → container TCP via -p mapping.

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

init_test "04 port forwarding host → container"
require_cockerd

mk_container --name cocker-e2e-pf -p 18080:8080 alpine:latest -- /bin/sh -c 'while true; do echo -e "HTTP/1.0 200 OK\r\nContent-Length: 7\r\n\r\nPFWD-OK" | nc -l -p 8080; done' >/dev/null
wait_running cocker-e2e-pf

# Give the portfwd a beat to bind. It can race with udhcpc on slow Macs.
for _ in $(seq 1 10); do
    out=$(curl -fsS http://127.0.0.1:18080/ 2>/dev/null || true)
    [[ "$out" == *"PFWD-OK"* ]] && exit 0
    sleep 1
done

echo "no response from http://127.0.0.1:18080/"; exit 1
