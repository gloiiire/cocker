#!/usr/bin/env bash
# 06-image-run-directory : image content created below /run survives boot.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "06 image /run directory"
require_cockerd

tmp=$(mktemp -d)
image="cocker-e2e-run-dir-$$"
trap 'rc=$?; "$COCKER" rmi -f "$image" >/dev/null 2>&1 || true; rm -rf "$tmp"; on_exit "$rc"' EXIT

cat >"$tmp/Dockerfile" <<'EOF'
FROM alpine:latest
RUN mkdir -p /run/nginx && echo image-marker > /run/nginx/cocker-e2e
CMD ["/bin/sh", "-c", "test -f /run/nginx/cocker-e2e && cat /run/nginx/cocker-e2e"]
EOF

"$COCKER" build -t "$image" "$tmp"
out=$("$COCKER" run --rm "$image")

if [[ "$out" != *"image-marker"* ]]; then
    echo "image content below /run was hidden at boot: $out" >&2
    exit 1
fi
