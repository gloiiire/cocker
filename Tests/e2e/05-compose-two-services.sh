#!/usr/bin/env bash
# 05-compose : a tiny web+db stack ; web resolves "db" by service name.

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

init_test "05 compose two services"
require_cockerd

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/docker-compose.yml" <<'YAML'
services:
  db:
    image: alpine:latest
    container_name: cocker-e2e-db
    command: ["/bin/sh", "-c", "while true; do echo -e 'HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nDB-OK' | nc -l -p 8080; done"]
  web:
    image: alpine:latest
    container_name: cocker-e2e-web
    command: ["/bin/sh", "-c", "while true; do wget -qO- -T 5 http://db:8080/ || echo none; sleep 2; done"]
YAML

(cd "$tmp" && $COCKER compose up -d) >/dev/null

# Clean up either via compose down or by removing both containers individually.
trap '$COCKER rm -f cocker-e2e-web cocker-e2e-db >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

wait_running cocker-e2e-db
wait_running cocker-e2e-web

# Give web a moment to do its first request loop.
sleep 5
out=$($COCKER logs cocker-e2e-web 2>&1 | tail -5)

[[ "$out" == *"DB-OK"* ]] || { echo "web never saw DB-OK, got: $out"; exit 1; }
