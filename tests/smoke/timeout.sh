#!/usr/bin/env bash
# Hard timeout, including when the controller dies (spec: microvm-lifecycle,
# sandbox-test-runs). Takes about 2 minutes.
. "$(dirname "$0")/lib.sh"
echo "== timeout"

payload="$(mktemp -d)"

# 1. Timeout handled by the controller.
"$FCCTL" run --payload "$payload" --results-dir "$RESULTS" --timeout 20s \
  --cmd 'echo before-sleep; sleep 300' >/dev/null 2>&1
rc=$?
run="$(ls -t "$RESULTS" | head -1)"
expect "timed-out run exits with 124" test "$rc" = 124
expect "meta.json records timed_out" test "$(jq -r .timed_out "$RESULTS/$run/meta.json")" = true
expect "output produced before the timeout is kept" grep -q before-sleep "$RESULTS/$run/stdout.log"
expect "VM is gone after the timeout" bash -c "! '$FCCTL' list | grep -q '$run'"

# 2. Controller killed with SIGKILL; the watchdog must still stop the VM.
before="$(ls "$RESULTS")"
"$FCCTL" run --payload "$payload" --results-dir "$RESULTS" --timeout 15s \
  --cmd 'sleep 300' >/dev/null 2>&1 &
ctl=$!
for _ in $(seq 60); do
  run="$(comm -13 <(echo "$before") <(ls "$RESULTS") | head -1)"
  [ -n "$run" ] && [ -f "$RESULTS/$run/meta.json" ] && break
  sleep 1
done
sleep 3
kill -9 "$ctl"
sleep 50   # timeout (15s) + collect grace (30s) + margin
expect "watchdog destroyed the VM after the controller died" bash -c "! '$FCCTL' list | grep -q '$run'"
expect "watchdog recorded the timeout in meta.json" \
  test "$(jq -r '.timed_out, .exit_code' "$RESULTS/$run/meta.json" | tr '\n' ' ')" = "true 124 "
expect "no leftovers after the watchdog" no_leftovers

rm -rf "$payload"
finish
