#!/usr/bin/env bash
# put / get for started VMs (spec: sandbox-test-runs / Copy files into a started VM,
# Copy files out of a started VM, Guest files leave only through the airlock).
. "$(dirname "$0")/lib.sh"
echo "== files"

host="$(mktemp -d)"
echo sample > "$host/sample.bin"
mkdir -p "$host/tools/sub" && echo t1 > "$host/tools/t1.txt" && echo t2 > "$host/tools/sub/t2.txt"

id="$(start_vm --vcpu 1 --mem 256)"

"$FCCTL" put "$id" "$host/sample.bin" 2>/dev/null
expect "put file lands in /work/in" test "$(gssh "$id" cat /work/in/sample.bin)" = sample
"$FCCTL" put "$id" "$host/tools" /work/tools 2>/dev/null
expect "put folder copies its contents" test "$(gssh "$id" 'cat /work/tools/t1.txt /work/tools/sub/t2.txt' | tr '\n' ' ')" = "t1 t2 "

gssh "$id" 'mkdir -p /work/out/sub && echo report > /work/out/report.txt && echo deep > /work/out/sub/deep.txt'
"$FCCTL" get "$id" /work/out "$RESULTS/get-dir" 2>/dev/null
expect "get folder" test "$(cat "$RESULTS/get-dir/report.txt") $(cat "$RESULTS/get-dir/sub/deep.txt")" = "report deep"
"$FCCTL" get "$id" /work/in/sample.bin "$RESULTS/get-file" 2>/dev/null
expect "get single file" test "$(ls "$RESULTS/get-file")/$(cat "$RESULTS/get-file/sample.bin")" = "sample.bin/sample"

"$FCCTL" get "$id" /work/nope "$RESULTS/get-missing" 2>"$RESULTS/missing.err"
rc=$?
expect "missing guest path fails" test "$rc" != 0
expect "missing guest path is named" grep -q '/work/nope' "$RESULTS/missing.err"

gssh "$id" 'ln -s /etc /work/out/link'
"$FCCTL" get "$id" /work/out "$RESULTS/get-link" 2>"$RESULTS/link.err"
rc=$?
expect "guest symlink is refused" test "$rc" = 1
expect "refusal names the link" grep -q "symbolic link is not allowed: './link'" "$RESULTS/link.err"
expect "refused get writes nothing" test ! -e "$RESULTS/get-link"

"$FCCTL" get "$id" /work/in/sample.bin "$RESULTS/get-dir" 2>/dev/null
expect "get into a non-empty folder fails" test "$?" != 0

"$FCCTL" stop "$id" 2>/dev/null
"$FCCTL" put "$id" "$host/sample.bin" 2>/dev/null
expect "put on a stopped VM exits 125" test "$?" = 125
"$FCCTL" get "$id" /work/out "$RESULTS/get-stopped" 2>/dev/null
expect "get on a stopped VM exits 125" test "$?" = 125
expect "nothing written for a stopped VM" test ! -e "$RESULTS/get-stopped"

expect "no airlock left" not bash -c "'$FCCTL' list | grep -q airlock:"
rm -rf "$host"
finish
