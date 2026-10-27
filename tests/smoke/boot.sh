#!/usr/bin/env bash
# Boot, jail isolation and disposable disk (spec: microvm-lifecycle).
. "$(dirname "$0")/lib.sh"
echo "== boot"

base_sum_before="$(sha256sum /opt/fc-sandbox/images/rootfs.ext4 | cut -d' ' -f1)"
id="$(start_vm --vcpu 1 --mem 256)"
expect "VM boots and answers over vsock SSH" gssh "$id" true

pid="$(vm_pid "$id")"
expect "firecracker runs as a non-root uid" test "$(stat -c %u "/proc/$pid")" -ne 0
expect "firecracker is chrooted into its jail" \
  test "$(awk '$5 == "/" {print $4; exit}' "/proc/$pid/mountinfo")" = "/srv/jailer/firecracker/$id/root"
expect "firecracker has its own cgroup" test -d "/sys/fs/cgroup/firecracker/$id"

gssh "$id" 'echo tampered > /etc/fc-smoke-marker; rm -f /usr/bin/socat; sync'
"$FCCTL" stop "$id" 2>/dev/null
expect "base image unchanged after the guest modified its disk" \
  test "$(sha256sum /opt/fc-sandbox/images/rootfs.ext4 | cut -d' ' -f1)" = "$base_sum_before"

id="$(start_vm --vcpu 1 --mem 256)"
expect "next VM boots from a clean image" gssh "$id" '! test -e /etc/fc-smoke-marker && test -x /usr/bin/socat'
"$FCCTL" stop "$id" 2>/dev/null

finish
