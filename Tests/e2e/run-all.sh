#!/usr/bin/env bash
# Run every numbered E2E script and report aggregate pass/fail.
#
# CI cannot run these — GitHub's macOS runners have no
# Virtualization.framework — so a maintainer running this before tagging
# is the only thing standing between a regression and a release.
#
# Usage :
#   Tests/e2e/run-all.sh                            # installed `cocker`
#   COCKER=./.build/release/cocker Tests/e2e/run-all.sh

set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
COCKER=${COCKER:-cocker}
export COCKER

if ! $COCKER ping >/dev/null 2>&1 && ! $COCKER info >/dev/null 2>&1; then
    echo "cockerd unreachable — start it with \`cocker daemon start\`" >&2
    exit 2
fi

echo "==> E2E suite ($($COCKER --version 2>/dev/null || echo '?'))"

# Leftovers from an interrupted run make later scenarios fail with
# "Container name already in use", which looks like a product bug.
for c in cocker-e2e-srv cocker-e2e-srv2 cocker-e2e-pf cocker-e2e-db cocker-e2e-web; do
    $COCKER rm -f "$c" >/dev/null 2>&1 || true
done

pass=0
fail=0
skipped=0
failures=()

for script in "$DIR"/[0-9]*.sh; do
    name=$(basename "$script")
    # Capture once and classify from that output. The previous version ran
    # every script a second time just to look for SKIP, which doubled the
    # suite's runtime and could boot a second set of VMs.
    output=$(bash "$script" 2>&1)
    rc=$?
    verdict=$(echo "$output" | grep -E '^==> (PASS|FAIL|SKIP)' | tail -1)

    if [ "$rc" -ne 0 ]; then
        fail=$((fail + 1)); failures+=("$name")
        echo " ✗ $name"
        echo "$output" | grep -vE '^\[cocker-init\]|^udhcpc|^\[ +[0-9]' | tail -12 | sed 's/^/     /'
    elif [[ "$verdict" == *SKIP* ]]; then
        skipped=$((skipped + 1))
        echo " – $name (skipped)"
    elif [ -z "$verdict" ]; then
        # Exit 0 but no verdict : the scenario replaced init_test's trap
        # without calling on_exit, so its result was never reported. Silent
        # success is indistinguishable from silent failure, so treat it as
        # a failure of the harness.
        fail=$((fail + 1)); failures+=("$name (no verdict reported)")
        echo " ✗ $name — exited 0 but printed no PASS/FAIL"
    else
        pass=$((pass + 1))
        echo " ✓ $name"
    fi
done

echo
echo "===================="
echo "E2E results"
echo "  passed  : $pass"
echo "  failed  : $fail"
echo "  skipped : $skipped"
for f in "${failures[@]:-}"; do [ -n "$f" ] && echo "    ✗ $f"; done
echo "===================="

[ "$fail" -eq 0 ]
