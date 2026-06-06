#!/usr/bin/env bash
# Run every numbered E2E script and report aggregate pass/fail.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

pass=0
fail=0
skipped=0

for script in "$DIR"/[0-9]*.sh; do
    name=$(basename "$script")
    set +e
    bash "$script"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        if grep -q SKIP <<<"$(bash "$script" 2>&1 | tail -3)"; then
            skipped=$((skipped + 1))
        else
            pass=$((pass + 1))
        fi
    else
        fail=$((fail + 1))
    fi
done

echo
echo "===================="
echo "E2E results"
echo "  passed  : $pass"
echo "  failed  : $fail"
echo "  skipped : $skipped"
echo "===================="

[ "$fail" -eq 0 ]
