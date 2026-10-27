#!/usr/bin/env bash
# list / stop / keep / cleanup after a crash (spec: microvm-lifecycle).
. "$(dirname "$0")/lib.sh"
echo "== lifecycle"

a="$(start_vm --vcpu 1 --mem 256)"
b="$(start_vm --vcpu 1 --mem 256 --net networked)"
expect "two VMs get distinct ids" test -n "$a" -a -n "$b" -a "$a" != "$b"
expect "list shows both VMs" bash -c "'$FCCTL' list | grep -q '$a.*running.*isolated' && '$FCCTL' list | grep -q '$b.*running.*networked'"

"$FCCTL" stop "$a" 2>/dev/null
expect "stopped VM's process is gone" bash -c "! '$FCCTL' list | grep -q '$a'"
expect "stopped VM's jail and disk are gone" test ! -e "/srv/jailer/firecracker/$a"

# Simulate a controller crash mid-start: kill fcctl while the third VM boots.
"$FCCTL" start --vcpu 1 --mem 256 --net networked >/dev/null 2>&1 &
sleep 2
kill -9 $! 2>/dev/null
sleep 1
"$FCCTL" cleanup 2>/dev/null
expect "cleanup removes running and orphaned VMs, taps and nft chains" no_leftovers
expect "list is empty after cleanup" test "$("$FCCTL" list | wc -l)" = 1

# --keep preserves the disk until explicit cleanup.
payload="$(mktemp -d)"
"$FCCTL" run --keep --payload "$payload" --results-dir "$RESULTS" --cmd 'echo kept > /root/marker' >/dev/null 2>&1
run="$(ls -t "$RESULTS" | head -1)"
expect "kept run shows as kept" bash -c "'$FCCTL' list | grep -q '$run.*kept'"
expect "kept disk is preserved" test -f "/var/lib/fc-sandbox/vms/$run/rootfs.ext4"
"$FCCTL" cleanup 2>/dev/null
expect "cleanup removes kept disks" test ! -e "/var/lib/fc-sandbox/vms/$run"
rm -rf "$payload"

finish
