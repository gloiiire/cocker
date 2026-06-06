#!/usr/bin/env bash
# 02-inter-container-by-ip : container B pings and wgets container A by cockerIP.

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

init_test "02 inter-container by IP"
require_cockerd

srv=$(mk_container --name cocker-e2e-srv alpine:latest -- /bin/sh -c 'while true; do echo -e "HTTP/1.0 200 OK\r\nContent-Length: 6\r\n\r\nFROM-A" | nc -l -p 8080; done')
wait_running cocker-e2e-srv

srv_ip=$($COCKER inspect cocker-e2e-srv --format '{{.NetworkSettings.IPAddress}}' 2>/dev/null || true)
# Fallback : grep the JSON for cockerIP if --format doesn't carry it yet.
if [ -z "$srv_ip" ]; then
    srv_ip=$($COCKER inspect cocker-e2e-srv 2>/dev/null | awk -F'"' '/cockerIP/{print $4; exit}')
fi
[ -n "$srv_ip" ] || { echo "no IP for srv-a"; exit 1; }

out=$($COCKER run --rm alpine:latest -- /bin/sh -c "ping -c 2 -W 2 $srv_ip > /dev/null && wget -qO- -T 5 http://$srv_ip:8080/")

[[ "$out" == *"FROM-A"* ]] || { echo "expected FROM-A, got: $out"; exit 1; }
