#!/usr/bin/env bash
# 01-basic-run : `cocker run alpine echo hi` produces "hi" on stdout.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "01 basic run"
require_cockerd

out=$($COCKER run --rm alpine:latest -- /bin/sh -c 'echo cocker-e2e-ok')

if [[ "$out" != *"cocker-e2e-ok"* ]]; then
    echo "unexpected output : $out" >&2
    exit 1
fi
