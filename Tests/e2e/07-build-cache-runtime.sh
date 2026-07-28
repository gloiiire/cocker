#!/usr/bin/env bash
# 07-build-cache-runtime : a cached RUN layer is not reused across runtimes.
#
# Regression from the field : 0.7.13.14 fixed the `/run` tmpfs bug in
# cocker-init, but machines that had already built `RUN mkdir -p /run/nginx`
# kept replaying the *empty* layer captured by the old runtime, so nginx
# still failed with `open() "/run/nginx/nginx.pid" failed`. The only escape
# was a manual `--no-cache`. A build layer is only replayable under the
# runtime that produced it, so an upgraded initrd must invalidate it.
#
# This test drives the real cache from the outside :
#   1. build (populates the cache),
#   2. rebuild → must hit the cache (otherwise the fix just disabled it),
#   3. tamper with the cached entry's runtime fingerprint to simulate an
#      upgraded cocker-init, rebuild → must NOT hit the cache.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "07 build cache runtime fingerprint"
require_cockerd

tmp=$(mktemp -d)
image="cocker-e2e-cache-rt-$$"
trap 'rc=$?; "$COCKER" rmi -f "$image" >/dev/null 2>&1 || true; rm -rf "$tmp"; on_exit "$rc"' EXIT

COCKER_ROOT="${COCKER_ROOT:-$HOME/.cocker}"
CACHE_DIR="$COCKER_ROOT/build-cache"

# A marker unique to this run so the RUN step is never already cached.
marker="cache-rt-$$-$RANDOM"

cat >"$tmp/Dockerfile" <<EOF
FROM alpine:latest
RUN mkdir -p /run/nginx && echo $marker > /run/nginx/marker
CMD ["/bin/sh", "-c", "cat /run/nginx/marker"]
EOF

# Snapshot the cache before building so we can tell *our* entries apart
# and never disturb the developer's existing cache.
before_entries="$tmp/before.txt"
: >"$before_entries"
[ -d "$CACHE_DIR" ] && find "$CACHE_DIR" -name '*.json' | sort >"$before_entries"

echo " → 1/3 first build (populates the cache)"
"$COCKER" build -t "$image" "$tmp" >"$tmp/build1.log" 2>&1 || {
    cat "$tmp/build1.log" >&2; exit 1
}

echo " → 2/3 rebuild must reuse the cache"
"$COCKER" build -t "$image" "$tmp" >"$tmp/build2.log" 2>&1 || {
    cat "$tmp/build2.log" >&2; exit 1
}
if ! grep -q "Using cache" "$tmp/build2.log"; then
    echo "identical rebuild did not hit the build cache — caching is broken" >&2
    cat "$tmp/build2.log" >&2
    exit 1
fi

# Rewriting the runtime fingerprint of the entries this test just created is
# exactly what a cocker-init upgrade does to them.
echo " → 3/3 simulate a runtime upgrade, cache must be invalidated"
if [ ! -d "$CACHE_DIR" ]; then
    echo "build cache dir not found at $CACHE_DIR" >&2
    exit 1
fi

after_entries="$tmp/after.txt"
find "$CACHE_DIR" -name '*.json' | sort >"$after_entries"

touched=0
while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    grep -q '"runtime"' "$entry" || continue
    python3 - "$entry" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    entry = json.load(fh)
entry["runtime"] = "e2e-simulated-upgraded-runtime"
with open(path, "w") as fh:
    json.dump(entry, fh)
PY
    touched=$((touched + 1))
done < <(comm -13 "$before_entries" "$after_entries")

if [ "$touched" -eq 0 ]; then
    echo "the build wrote no cache entry carrying a runtime fingerprint" >&2
    exit 1
fi

"$COCKER" build -t "$image" "$tmp" >"$tmp/build3.log" 2>&1 || {
    cat "$tmp/build3.log" >&2; exit 1
}
if grep -q "Using cache" "$tmp/build3.log"; then
    echo "stale layer replayed after a runtime change — the /run bug can resurface" >&2
    cat "$tmp/build3.log" >&2
    exit 1
fi

# And the rebuilt image must still be correct.
out=$("$COCKER" run --rm "$image")
if [[ "$out" != *"$marker"* ]]; then
    echo "rebuilt image lost its /run content: $out" >&2
    exit 1
fi
