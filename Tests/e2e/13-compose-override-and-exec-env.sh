#!/usr/bin/env bash
# 13 : compose override files are merged, and exec sees the container's env.
#
# Two silent-wrong-result bugs, both invisible until you looked inside a
# running container:
#
#   * `docker-compose.override.yml` is loaded automatically by Docker Compose
#     and is one of the most common things in a real project. Cocker read a
#     single file and never merged, so a dev-only port, bind mount or env var
#     was ignored — the project came up, looked healthy, and wasn't
#     configured the way its author wrote it.
#   * `cocker exec` passed only what the caller gave with `-e`. Anything the
#     image's ENV or compose's `environment:` had set was invisible, so
#     `cocker exec c sh -c 'echo $DATABASE_URL'` printed nothing.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "13 compose override + exec env"
require_cockerd

proj=$(mktemp -d)
# Pin the project name : mktemp dirs contain characters the normaliser
# rewrites, so deriving it would make the container name unpredictable.
project="cocker-e2e-ov$$"
name="${project}_app_1"

# NB: no `trap ... EXIT` here — lib.sh's init_test already installed one that
# prints the PASS/FAIL line. Replacing it silently swallows the result.
cleanup() {
    (cd "$proj" 2>/dev/null && $COCKER compose down -p "$project" >/dev/null 2>&1) || true
    rm -rf "$proj"
}

# `$$VAR` survives compose substitution and reaches the container as `$VAR`.
cat > "$proj/docker-compose.yml" <<'YML'
services:
  app:
    image: alpine:latest
    command: ["/bin/sh", "-c", "echo RESULT MODE=$$MODE EXTRA=$$EXTRA; sleep 60"]
    environment:
      MODE: production
YML

cat > "$proj/docker-compose.override.yml" <<'YML'
services:
  app:
    environment:
      MODE: development
      EXTRA: from-override
YML

fail=0

(cd "$proj" && $COCKER compose up -d -p "$project" >/dev/null 2>&1)
wait_running "$name"
sleep 3

got=$($COCKER logs "$name" 2>/dev/null | grep RESULT | tail -1)
case "$got" in
    *"MODE=development"*"EXTRA=from-override"*)
        echo "  ok   override merged ($got)" ;;
    *)
        echo "  FAIL override not merged : $got" >&2; fail=1 ;;
esac

# exec must see the same environment the container is running with.
got=$($COCKER exec "$name" /bin/sh -c 'echo MODE=$MODE EXTRA=$EXTRA' 2>/dev/null | tr -d '\r\n')
case "$got" in
    *"MODE=development"*"EXTRA=from-override"*)
        echo "  ok   exec inherits the container env ($got)" ;;
    *)
        echo "  FAIL exec env : $got" >&2; fail=1 ;;
esac

# ...and an explicit -e still wins, which is what the flag is for.
got=$($COCKER exec -e MODE=explicit "$name" /bin/sh -c 'echo MODE=$MODE' 2>/dev/null | tr -d '\r\n')
case "$got" in
    *"MODE=explicit"*) echo "  ok   -e overrides the inherited value" ;;
    *) echo "  FAIL -e precedence : $got" >&2; fail=1 ;;
esac

# Without the override file, only the base values apply.
(cd "$proj" && $COCKER compose down -p "$project" >/dev/null 2>&1)
mv "$proj/docker-compose.override.yml" "$proj/disabled.yml"
(cd "$proj" && $COCKER compose up -d -p "$project" >/dev/null 2>&1)
wait_running "$name"
sleep 3

got=$($COCKER logs "$name" 2>/dev/null | grep RESULT | tail -1)
case "$got" in
    *"MODE=production"*)
        echo "  ok   base values apply with no override ($got)" ;;
    *)
        echo "  FAIL base-only : $got" >&2; fail=1 ;;
esac

cleanup
exit $fail
