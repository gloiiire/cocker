#!/usr/bin/env bash
# 04-port-forwarding : host → container TCP via -p mapping.

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

init_test "04 port forwarding host → container"
require_cockerd

mk_container --name cocker-e2e-pf -p 18080:8080 alpine:latest -- /bin/sh -c 'while true; do echo -e "HTTP/1.0 200 OK\r\nContent-Length: 7\r\n\r\nPFWD-OK" | nc -l -p 8080; done' >/dev/null
wait_running cocker-e2e-pf

# Give the portfwd a beat to bind. It can race with udhcpc on slow Macs.
tcp_ok=0
for _ in $(seq 1 10); do
    out=$(curl -fsS http://127.0.0.1:18080/ 2>/dev/null || true)
    if [[ "$out" == *"PFWD-OK"* ]]; then tcp_ok=1; break; fi
    sleep 1
done
if [ "$tcp_ok" != 1 ]; then
    echo "  FAIL tcp : no response from http://127.0.0.1:18080/" >&2
    exit 1
fi
echo "  ok   tcp"

# UDP. These mappings were accepted, shown by `ps`, and forwarded nowhere:
# the relay piped TCP through /usr/bin/nc and there was no datagram path at
# all, so a DNS container published on -p 53:53/udp answered nobody.
mk_container --name cocker-e2e-pf-udp -p 18201:7777/udp alpine:latest \
    -- /bin/sh -c 'while true; do nc -u -l -p 7777 -e /bin/cat; done' >/dev/null
wait_running cocker-e2e-pf-udp

udp_ok=0
for _ in $(seq 1 10); do
    reply=$(python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
try:
    s.sendto(b'PFWD-UDP', ('127.0.0.1', 18201))
    sys.stdout.write(s.recvfrom(1024)[0].decode())
except Exception:
    pass
" 2>/dev/null || true)
    if [ "$reply" = "PFWD-UDP" ]; then udp_ok=1; break; fi
    sleep 1
done
if [ "$udp_ok" != 1 ]; then
    echo "  FAIL udp : no datagram came back from 127.0.0.1:18201" >&2
    exit 1
fi
echo "  ok   udp"
exit 0
