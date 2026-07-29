#!/usr/bin/env bash
# 08-buildkit-and-copy-errors : build failures must be loud, not silent.
#
# Three bugs found while migrating a real project to `uv`, all sharing the
# same failure mode — the build looked like it had worked:
#
#   1. `RUN --mount=type=cache,...` was handed to /bin/sh, which tried to
#      execute the flag as a program. Modern Python/Rust/Node Dockerfiles
#      all use this syntax.
#   2. A `COPY` whose source is missing from the context only warned, and
#      the build still exited 0 — the image shipped without the file and
#      only failed at runtime. Typically hit with `-f` pointing outside
#      the context, since COPY resolves against the context.
#   3. A mount type that cannot be dropped safely (bind/secret/ssh) must
#      fail rather than silently build a different image.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "08 buildkit mounts + copy errors"
require_cockerd

tmp=$(mktemp -d)
img="cocker-e2e-bk-$$"
trap 'rc=$?; "$COCKER" rmi -f "$img" "$img-bind" "$img-copy" >/dev/null 2>&1 || true; rm -rf "$tmp"; on_exit "$rc"' EXIT

marker="bk-$$-$RANDOM"

# ---------------------------------------------------------------- 1/3
echo " → 1/3 RUN --mount=type=cache must not break the build"
mkdir -p "$tmp/ctx"
cat >"$tmp/ctx/Dockerfile" <<EOF
FROM alpine:latest
RUN --mount=type=cache,target=/root/.cache echo $marker > /marker
CMD ["/bin/sh", "-c", "cat /marker"]
EOF

"$COCKER" build -t "$img" "$tmp/ctx" >"$tmp/b1.log" 2>&1 || {
    echo "cache mount broke the build:" >&2; cat "$tmp/b1.log" >&2; exit 1
}
out=$("$COCKER" run --rm "$img")
if [[ "$out" != *"$marker"* ]]; then
    echo "command did not run under --mount=type=cache: $out" >&2
    exit 1
fi
grep -qi 'ignoring unsupported' "$tmp/b1.log" || {
    echo "dropping the cache mount was not reported to the user" >&2
    cat "$tmp/b1.log" >&2; exit 1
}

# ---------------------------------------------------------------- 2/3
echo " → 2/3 a mount that changes visible state must fail loudly"
cat >"$tmp/ctx/Dockerfile" <<'EOF'
FROM alpine:latest
RUN --mount=type=bind,source=/etc,target=/mnt ls /mnt
EOF

if "$COCKER" build -t "$img-bind" "$tmp/ctx" >"$tmp/b2.log" 2>&1; then
    echo "type=bind was silently ignored — the image would be wrong" >&2
    exit 1
fi
grep -qi 'not supported' "$tmp/b2.log" || {
    echo "type=bind failed without explaining why" >&2
    cat "$tmp/b2.log" >&2; exit 1
}

# ---------------------------------------------------------------- 3/3
echo " → 3/3 COPY of a missing source must fail, not warn"
# The classic shape: Dockerfile outside the context, so its neighbouring
# files are NOT part of what COPY can see.
mkdir -p "$tmp/emptyctx"
cat >"$tmp/outside.Dockerfile" <<'EOF'
FROM alpine:latest
COPY data.txt /data.txt
EOF
echo "present next to the Dockerfile" > "$tmp/data.txt"

if "$COCKER" build -f "$tmp/outside.Dockerfile" -t "$img-copy" "$tmp/emptyctx" \
       >"$tmp/b3.log" 2>&1; then
    echo "COPY of a missing source exited 0 — image is silently incomplete" >&2
    cat "$tmp/b3.log" >&2
    exit 1
fi
grep -qi 'no such file' "$tmp/b3.log" || {
    echo "missing COPY source failed without naming the cause" >&2
    cat "$tmp/b3.log" >&2; exit 1
}
# The hint is what turns a confusing failure into a two-second fix.
grep -qi 'build context' "$tmp/b3.log" || {
    echo "failure did not mention the build context" >&2
    cat "$tmp/b3.log" >&2; exit 1
}
