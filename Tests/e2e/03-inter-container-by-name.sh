#!/usr/bin/env bash
# 03-inter-container-by-name : DNS resolves a peer's name to its cockerIP.

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

init_test "03 inter-container by DNS name"
require_cockerd

mk_container --name cocker-e2e-srv2 alpine:latest -- /bin/sh -c 'while true; do echo -e "HTTP/1.0 200 OK\r\nContent-Length: 6\r\n\r\nNAMED!" | nc -l -p 8080; done' >/dev/null
wait_running cocker-e2e-srv2

out=$($COCKER run --rm alpine:latest -- /bin/sh -c "nslookup cocker-e2e-srv2 2>&1 | tail -5; echo ---; wget -qO- -T 5 http://cocker-e2e-srv2:8080/")

[[ "$out" == *"NAMED!"* ]] || { echo "expected NAMED!, got: $out"; exit 1; }
