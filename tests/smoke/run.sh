#!/usr/bin/env bash
# Test-run workflow, exit codes and shell (spec: sandbox-test-runs).
. "$(dirname "$0")/lib.sh"
echo "== run"

payload="$(mktemp -d)"
cat > "$payload/scan.sh" <<'EOF'
#!/bin/sh
echo "scanning from $(pwd)"
echo "warning on stderr" >&2
uname -r > out/kernel.txt
mkdir -p out/sub && echo nested > out/sub/file.txt
EOF
chmod +x "$payload/scan.sh"

"$FCCTL" run --payload "$payload" --results-dir "$RESULTS" --cmd './in/scan.sh' >/dev/null 2>&1
rc=$?
run="$(ls -t "$RESULTS" | head -1)"
expect "successful run exits 0" test "$rc" = 0
for f in exit_code stdout.log stderr.log meta.json out/kernel.txt out/sub/file.txt; do
  expect "results contain $f" test -f "$RESULTS/$run/$f"
done
expect "command ran in /work" grep -q "scanning from /work" "$RESULTS/$run/stdout.log"
expect "stderr captured separately" grep -q "warning on stderr" "$RESULTS/$run/stderr.log"
expect "meta.json has run metadata" \
  test "$(jq -r '[.run_id, .net, .vcpu, .timed_out, .exit_code] | join(" ")' "$RESULTS/$run/meta.json")" = "$run isolated 2 false 0"
expect "VM destroyed after the run" bash -c "! '$FCCTL' list | grep -q '$run'"

"$FCCTL" run --payload "$payload" --results-dir "$RESULTS" --cmd 'exit 3' >/dev/null 2>&1
expect "guest exit code 3 is passed through" test $? = 3

"$FCCTL" run --payload /nonexistent --results-dir "$RESULTS" --cmd true >/dev/null 2>&1
expect "missing payload exits 125" test $? = 125

"$FCCTL" run --payload "$payload" --results-dir "$RESULTS" --cmd "printf '%s' \"it's quoted\" > out/q.txt" >/dev/null 2>&1
run="$(ls -t "$RESULTS" | head -1)"
expect "commands with quotes survive" test "$(cat "$RESULTS/$run/out/q.txt")" = "it's quoted"

out="$(printf 'echo "uid=$(id -u) host=$(hostname)"\nexit\n' | "$FCCTL" shell 2>/dev/null)"
expect "shell gives a root shell in the guest" grep -q "uid=0 host=fc-guest" <<<"$out"
expect "shell VM is destroyed on exit" no_leftovers

rm -rf "$payload"
finish
