#!/usr/bin/env bash
# 11-exit-codes : cocker reports failure when the container fails.
#
# Every one of these returned 0 before v0.8. `cocker run img false && deploy`
# deployed, and every CI step that shelled out to cocker passed no matter what
# the container did. This is the regression test for the single most dangerous
# class of bug the engine had.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "11 exit codes"
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

# lib.sh sets `set -e`, and every interesting case here exits non-zero on
# purpose. Capture the status instead of letting it abort the script.
status_of() {
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# --- foreground run -------------------------------------------------------
check "run false"        1  "$(status_of $COCKER run --rm alpine:latest -- /bin/false)"
check "run 'exit 42'"    42 "$(status_of $COCKER run --rm alpine:latest -- /bin/sh -c 'exit 42')"
check "run true"         0  "$(status_of $COCKER run --rm alpine:latest -- /bin/true)"

# The shell idiom that silently passed. `--rm` matters: the container is
# removed the instant it stops, so the code has to be published before the
# removal rather than read back afterwards.
if $COCKER run --rm alpine:latest -- /bin/false >/dev/null 2>&1; then
    echo "  FAIL if-guard : a failing container reported success" >&2
    fail=1
else
    echo "  ok   if-guard"
fi

# --- wait -----------------------------------------------------------------
cid=$($COCKER run -d alpine:latest -- /bin/sh -c 'exit 7' 2>/dev/null | tail -1)
CREATED_CONTAINERS+=("$cid")
code=$($COCKER wait "$cid" 2>/dev/null | tail -1)
check "wait prints the code" 7 "$code"

# --- exec -----------------------------------------------------------------
name="cocker-e2e-exit-$$"
mk_container --name "$name" alpine:latest -- /bin/sleep 120 >/dev/null
wait_running "$name"

check "exec false"     1 "$(status_of $COCKER exec "$name" /bin/false)"
check "exec 'exit 9'"  9 "$(status_of $COCKER exec "$name" /bin/sh -c 'exit 9')"

# The runtime signals completion with an `exit:<n>` marker on the status
# channel. It used to be framed as stdout, so a literal "exit:0" was appended
# to whatever the command printed.
out=$($COCKER exec "$name" /bin/echo marker-check 2>/dev/null | tr -d '\r\n')
case "$out" in
    *exit:*)        echo "  FAIL exec stdout : exit marker leaked ($out)" >&2; fail=1 ;;
    *marker-check*) echo "  ok   exec stdout is clean" ;;
    *)              echo "  FAIL exec stdout : unexpected ($out)" >&2; fail=1 ;;
esac

# --- the documented taxonomy ---------------------------------------------
# docs/UX-CHARTER.md promises 127 no-such-object / 126 found-but-not-runnable
# / 125 cocker-itself-failed. It never reached a script: commands caught the
# error to print their failure block and then threw a blanket 1, and the IPC
# layer dropped the error's kind on the way back anyway.
check "stop: no such container"   127 "$(status_of $COCKER stop cocker-e2e-nosuch-$$)"
check "rm: no such container"     127 "$(status_of $COCKER rm cocker-e2e-nosuch-$$)"
check "rmi: no such image"        127 "$(status_of $COCKER rmi cocker-e2e-nosuch-$$:latest)"
check "volume rm: no such volume" 127 "$(status_of $COCKER volume rm cocker-e2e-nosuch-$$)"
check "unimplemented command"     126 "$(status_of $COCKER node ls)"

# --- the guest half of the same taxonomy ----------------------------------
# POSIX shells and docker separate "command not found" (127) from "found and
# not executable" (126). cocker-init hardcoded 127 at all three of its exec
# sites, so a directory or a non-executable file reported "not found" and a
# script could not tell a typo from a permissions problem.
check "run: no such command"      127 "$(status_of $COCKER run --rm alpine:latest -- /nosuchcommand)"
check "run: a directory"          126 "$(status_of $COCKER run --rm alpine:latest -- /etc)"
check "run: not executable"       126 "$(status_of $COCKER run --rm alpine:latest -- /etc/hostname)"
check "exec: no such command"     127 "$(status_of $COCKER exec "$name" /nosuchcommand)"
check "exec: a directory"         126 "$(status_of $COCKER exec "$name" /etc)"
check "exec: not executable"      126 "$(status_of $COCKER exec "$name" /etc/hostname)"

exit $fail
