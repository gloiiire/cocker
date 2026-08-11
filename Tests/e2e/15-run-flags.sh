#!/usr/bin/env bash
# 15-run-flags : --read-only, --tmpfs, --add-host and --dns actually do it.
#
# All four were accepted and ignored. Measured on 1.1.0.1:
#
#     cocker run --rm --read-only alpine sh -c 'touch /x && echo written'
#     written                                    ← root was writable
#     cocker run --rm --dns 1.1.1.1 alpine cat /etc/resolv.conf
#     nameserver 127.0.0.1                       ← never arrived
#
# They reach the guest through the v7 /cocker-spec trailer now. This can only
# be tested against a real VM, which is why it lives here.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

init_test "15 run flags"
require_cockerd

fail=0
check() {  # check <label> <expected> <actual>
    if [ "$2" != "$3" ]; then
        echo "  FAIL $1 : expected '$2', got '$3'" >&2
        fail=1
    else
        echo "  ok   $1"
    fi
}
# The guest console hands back CRLF.
clean() { tr -d '\r'; }
# lib.sh sets `set -e`. A grep that matches nothing exits 1 and would kill
# the script before a single check ran — the failure has to surface as a
# failed expectation, not as silence.
# cocker-init's boot log goes to the container's STDOUT, not stderr, so a
# naive capture picks up "[cocker-init] …" lines and every extraction below
# reads them instead of the answer. One filter, applied once.
say() {  # say <run args…> — container stdout, init chatter removed
    $COCKER run --rm "$@" 2>/dev/null | tr -d '\r' | grep -v '^\[' || true
}

# Filter by what an answer LOOKS like, not by what noise looks like.
#
# `say` excludes lines starting with "[cocker-init]", which fails the moment
# the guest console splits one of those lines: the tail of it arrives with no
# prefix and sails through. That is not hypothetical — a fragment of
# cocker-init's own resolv.conf message, ") + --dns servers", was parsed as a
# container's DNS answer and failed this suite on an installed 1.2.0.1.
#
# An exclusion filter over a stream you do not control is fragile by
# construction. These match the shape of the expected answer instead.
first_ip_line() { grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]' | head -1; }

# --- --read-only -----------------------------------------------------------
probe='touch /probe 2>/dev/null && echo writable || echo readonly'
check "--read-only makes / read-only" "readonly" \
      "$(say --read-only alpine:latest -- /bin/sh -c "$probe" | head -1)"

# Without the flag nothing changed — a fix in this shape is one mount away
# from making every container read-only.
check "without it / stays writable" "writable" \
      "$(say alpine:latest -- /bin/sh -c "$probe" | head -1)"

# The read-only view is private to the container's process tree, so PID 1 can
# still write /cocker-exit-code — the only way the host learns the status at
# all. Remounting / for everyone broke exactly this, measured.
rc=0
$COCKER run --rm --read-only alpine:latest -- /bin/sh -c 'exit 42' >/dev/null 2>&1 || rc=$?
check "exit codes survive --read-only" "42" "$rc"

# Submounts keep their own flags: a read-only root still needs somewhere to
# write.
tmpprobe='touch /tmp/x 2>/dev/null && echo writable || echo readonly'
check "/tmp stays writable under --read-only" "writable" \
      "$(say --read-only alpine:latest -- /bin/sh -c "$tmpprobe" | head -1)"

# --- --tmpfs ---------------------------------------------------------------
check "--tmpfs mounts with its options" "size=16384k" \
      "$(say --tmpfs /run:size=16m alpine:latest -- \
             /bin/sh -c 'grep " /run " /proc/mounts' | grep -o 'size=16384k' || true)"

# --- --add-host ------------------------------------------------------------
# getent rather than grepping the file: what matters is that it resolves.
check "--add-host resolves" "10.9.9.9" \
      "$(say --add-host db:10.9.9.9 alpine:latest -- getent hosts db \
         | first_ip_line | awk '{print $1}')"

# --- --dns -----------------------------------------------------------------
check "--dns reaches resolv.conf" "nameserver 1.1.1.1" \
      "$(say --dns 1.1.1.1 alpine:latest -- cat /etc/resolv.conf \
         | grep '^nameserver 1.1.1.1$' || true)"

check "--dns-search keeps cocker appended" "search example.com cocker" \
      "$(say --dns-search example.com alpine:latest -- cat /etc/resolv.conf \
         | grep '^search' || true)"

# The reason 127.0.0.1 stays first: it is what resolves other containers.
# Honouring --dns by replacing it would have traded service discovery for the
# flag, and nothing would have said so.
peer="cocker-e2e-flags-peer-$$"
mk_container --name "$peer" alpine:latest -- /bin/sleep 120 >/dev/null
wait_running "$peer"
check "container DNS survives --dns" "$peer" \
      "$(say --dns 1.1.1.1 alpine:latest -- getent hosts "$peer" \
         | first_ip_line | awk '{print $2}')"

exit $fail
