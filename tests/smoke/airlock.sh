#!/usr/bin/env bash
# Guest output airlock (spec: guest-output-airlock; sandbox-test-runs / Result collection;
# microvm-lifecycle / listing). Every run boots an extra airlock VM, so this takes a few minutes.
. "$(dirname "$0")/lib.sh"
echo "== airlock"

payload="$(mktemp -d)"
STAGING=/var/lib/fc-sandbox/staging

# airlock_run <cmd> [env...] -> sets RUN (run id), RC (exit code), ERR (stderr file)
airlock_run() {
  local cmd="$1"; shift
  ERR="$(mktemp)"
  env "$@" "$FCCTL" run --payload "$payload" --results-dir "$RESULTS" --cmd "$cmd" >/dev/null 2>"$ERR"
  RC=$?
  RUN="$(sed -n 's/^\[fcctl\] results: .*\/\([^/ ]*\) (exit code.*/\1/p' "$ERR" | tail -1)"
}
collection() { jq -r ".collection.$1" "$RESULTS/$RUN/meta.json"; }
out_empty() { [ -d "$RESULTS/$RUN/out" ] && [ -z "$(ls -A "$RESULTS/$RUN/out")" ]; }
no_airlock_left() { ! "$FCCTL" list | grep -q 'airlock:'; }
staging_empty() { [ -z "$(find "$STAGING" -mindepth 1 2>/dev/null)" ]; }
reason_has() { collection reason | grep -qF -- "$1"; }

# refused_case <description> <guest command> <expected reason fragment> [env...]
refused_case() {
  local desc="$1" cmd="$2" reason="$3"; shift 3
  airlock_run "$cmd" "$@"
  expect "$desc: guest exit code kept" test "$RC" = 0
  expect "$desc: collection refused in meta.json" test "$(collection status)" = refused
  expect "$desc: reason names the entry" reason_has "$reason"
  expect "$desc: out/ is empty" out_empty
  expect "$desc: error printed" grep -q 'collection refused' "$ERR"
}

# 1. Normal output goes through an airlock that is gone afterwards.
airlock_run 'mkdir -p out/sub && echo hello > out/a.txt && echo world > out/sub/b.txt'
expect "output collected" test "$(cat "$RESULTS/$RUN/out/a.txt")" = hello
expect "nested output collected" test "$(cat "$RESULTS/$RUN/out/sub/b.txt")" = world
expect "an airlock was used" grep -q 'starting airlock' "$ERR"
expect "collection ok in meta.json" test "$(collection status) $(collection files) $(collection bytes)" = "ok 2 12"
expect "no airlock left after the run" no_airlock_left

# 2. Hostile output is refused as a whole.
refused_case "symlink" 'echo keep > out/ok.txt; ln -s /etc out/link' "'./link'"
refused_case "fifo" 'mkfifo out/pipe' "FIFO is not allowed: './pipe'"
refused_case "reserved name" 'echo x > out/con.txt' "reserved device name 'con'"
refused_case "case collision" 'echo a > out/Report.txt; echo b > out/report.txt' "Report.txt"
refused_case "over the byte limit" 'head -c 8192 /dev/zero > out/big.bin' "larger than 4096" FC_AIRLOCK_TEST_MAX_BYTES=4096
refused_case "backslash in name" 'touch "out/a\\b"' "'\\' is not allowed in names"

# 3. A non-zero guest exit code is kept when collection is refused.
airlock_run 'ln -s / out/root; exit 7'
expect "refused collection keeps exit code 7" test "$RC" = 7

# 4. No output: no airlock at all.
airlock_run 'true'
expect "empty output starts no airlock" not grep -q 'starting airlock' "$ERR"
expect "empty output records ok with 0 files" test "$(collection status) $(collection files)" = "ok 0"

# 5. The airlock is listed with its role while it runs.
"$FCCTL" run --payload "$payload" --results-dir "$RESULTS" --cmd 'echo x > out/x' >/dev/null 2>&1 &
ctl=$!
seen=no
for _ in $(seq 160); do
  if "$FCCTL" list | grep -qE 'airlock:[0-9]{8}-[0-9]{6}-[0-9a-f]{4}'; then seen=yes; break; fi
  sleep 0.25
done
wait "$ctl"
expect "list shows airlock:<run-id> during a collection" test "$seen" = yes

expect "no airlock VMs left" no_airlock_left
expect "no staging folders left" staging_empty
expect "no leftovers" no_leftovers

rm -rf "$payload"
finish
