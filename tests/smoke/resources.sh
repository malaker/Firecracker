#!/usr/bin/env bash
# vCPU / memory options and validation (spec: microvm-lifecycle).
. "$(dirname "$0")/lib.sh"
echo "== resources"

id="$(start_vm)"
expect "default VM has 2 vCPUs" test "$(gssh "$id" nproc)" = 2
expect "default VM has about 1024 MiB" test "$(gssh "$id" "free -m | awk '/^Mem:/ {print \$2}'")" -ge 900
"$FCCTL" stop "$id" 2>/dev/null

id="$(start_vm --vcpu 4 --mem 2048)"
expect "VM honours --vcpu 4" test "$(gssh "$id" nproc)" = 4
expect "VM honours --mem 2048" test "$(gssh "$id" "free -m | awk '/^Mem:/ {print \$2}'")" -ge 1900
"$FCCTL" stop "$id" 2>/dev/null

expect "--vcpu 0 is rejected with a non-zero exit" bash -c "! '$FCCTL' start --vcpu 0 2>/dev/null"
expect "--mem larger than free memory is rejected" bash -c "! '$FCCTL' start --mem 10000000 2>/dev/null"
expect "rejected starts leave nothing behind" no_leftovers

finish
