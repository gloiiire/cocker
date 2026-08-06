#!/usr/bin/env bash
# 14-exec-capabilities : `cocker exec` runs under the container's capability
# policy, not the kernel's full set.
#
# It didn't. Measured on 1.1.0.1, same container:
#
#     main process   CapBnd: 00000000a80425fb   (docker's restricted default)
#     cocker exec    CapBnd: 000001ffffffffff   (FULL kernel set)
#
# So a container deliberately started with --cap-drop handed every capability
# back to anyone who exec'd into it — CAP_SYS_ADMIN, CAP_SYS_MODULE,
# CAP_SYS_PTRACE included.
#
# Two causes, both in cocker-init: exec_listener.c never called caps_apply,
# and exec_listener_spawn() ran one line BEFORE spec_load(), so the listener
# inherited empty cap arrays and could not have applied the right policy even
# if it had tried. init.c's own comment warns about exactly that ordering for
# health_poll, one line further down.
#
# This can only be tested against a real VM, which is why it lives here rather
# than in `swift test`.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "14 exec capabilities"
require_cockerd

fail=0
check() {  # check <label> <expected> <actual>
    if [ "$2" != "$3" ]; then
        echo "  FAIL $1 : expected $2, got $3" >&2
        fail=1
    else
        echo "  ok   $1 ($3)"
    fi
}

# CapBnd is the bounding set: the ceiling on what any process in this
# container can ever hold. Reading it from /proc is the kernel's own answer,
# not cocker's account of what it did.
# The guest console hands back CRLF, so every value gets its carriage
# return stripped — without it two identical sets compare unequal and the
# test fails for a reason that has nothing to do with capabilities.
capbnd() {  # capbnd <container>
    $COCKER exec "$1" grep CapBnd /proc/self/status 2>/dev/null \
        | tail -1 | awk '{print $2}' | tr -d '\r'
}

# --- the default set --------------------------------------------------------
name="cocker-e2e-caps-$$"
mk_container --name "$name" alpine:latest -- /bin/sleep 120 >/dev/null
wait_running "$name"

main_caps=$($COCKER run --rm alpine:latest -- /bin/sh -c \
    'grep CapBnd /proc/self/status' 2>/dev/null | grep CapBnd | awk '{print $2}' | tr -d '\r')
exec_caps=$(capbnd "$name")

# The point of the test: the two must agree. Comparing against a hardcoded
# constant would break on a kernel with a different CAP_LAST_CAP; comparing
# them to each other asks the real question.
check "exec matches the main process" "$main_caps" "$exec_caps"

# And it must not be the full set — if both were 1ffffffffff the check above
# would pass while the container had no restrictions at all.
if [ "$exec_caps" = "000001ffffffffff" ]; then
    echo "  FAIL exec holds the full kernel capability set" >&2
    fail=1
else
    echo "  ok   exec is not the full kernel set"
fi

# --- --cap-drop reaches exec ------------------------------------------------
dropname="cocker-e2e-capdrop-$$"
mk_container --name "$dropname" --cap-drop NET_RAW alpine:latest \
    -- /bin/sleep 120 >/dev/null
wait_running "$dropname"
drop_caps=$(capbnd "$dropname")

if [ "$drop_caps" = "$exec_caps" ]; then
    echo "  FAIL --cap-drop NET_RAW changed nothing for exec ($drop_caps)" >&2
    fail=1
else
    echo "  ok   --cap-drop is visible to exec ($drop_caps vs $exec_caps)"
fi

# --- --privileged reaches exec ----------------------------------------------
privname="cocker-e2e-cappriv-$$"
mk_container --name "$privname" --privileged alpine:latest \
    -- /bin/sleep 120 >/dev/null
wait_running "$privname"
check "--privileged is visible to exec" "000001ffffffffff" "$(capbnd "$privname")"

exit $fail
