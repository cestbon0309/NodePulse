#!/bin/sh
# Linux RSS after a full 120-second retention window. Publisher fixture gives each process a unique ID.
set -eu
probe=$1
publisher=$2
seconds=${3:-130}
target=${4:-127.0.0.1:9001}
pids=
cleanup() { for pid in $pids; do kill "$pid" 2>/dev/null || :; done; }
trap cleanup EXIT INT TERM
"$probe" -l 0.0.0.0:9002 -k measurement -E off >/dev/null 2>&1 &
baseline=$!; pids="$pids $!"
"$probe" -l 0.0.0.0:9000 -k measurement -S 0.0.0.0:9001 -T measurement -E off >/dev/null 2>&1 &
combined=$!; pids="$pids $!"
i=0
while [ "$i" -lt 10 ]; do
    "$publisher" -R "$target" -T measurement -G measurement-group -n "publisher-$i" -i 5 -E off >/dev/null 2>&1 &
    pids="$pids $!"; i=$((i + 1))
done
i=0
while [ "$i" -lt "$seconds" ]; do
    sleep 1
    i=$((i + 1))
    if [ "$i" -ge 120 ]; then
        for mode in baseline combined; do
            if [ "$mode" = baseline ]; then pid=$baseline; else pid=$combined; fi
            awk -v mode="$mode" -v tick="$i" '/^VmRSS:/ { print "RSS", mode, tick, $2, "KiB" }' "/proc/$pid/status"
        done
    fi
done
