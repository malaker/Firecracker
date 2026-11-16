#!/usr/bin/env bash
# Recipes (spec: sandbox-recipes). Part 1 tests the recipe command itself with fixture recipes
# (FC_RECIPES_DIR); the later parts run the installed recipes against benign samples.
. "$(dirname "$0")/lib.sh"
echo "== recipes"

HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/recipes-fixture"
TMP="$(mktemp -d /tmp/fc-recipes.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
vms_before() { ls -A /var/lib/fc-sandbox/vms 2>/dev/null | wc -l; }

# rrun <fcctl recipe args...>: runs a recipe; sets RC, RUN (run id) and ERR (stderr file).
rrun() {
  ERR="$TMP/err.$RANDOM"
  "$FCCTL" recipe "$@" --results-dir "$RESULTS" >"$TMP/out" 2>"$ERR"
  RC=$?
  RUN="$(sed -n 's/^\[fcctl\] results: .*\/\([^/ ]*\) (exit code.*/\1/p' "$ERR" | tail -1)"
}
# refused <description> <message-pattern> <fcctl recipe args...>: exit 125, the message, no VM.
refused() {
  local desc="$1" pat="$2"; shift 2
  "$FCCTL" recipe "$@" --results-dir "$RESULTS" >/dev/null 2>"$TMP/ref"
  local rc=$?
  if [ "$rc" = 125 ] && grep -qiE "$pat" "$TMP/ref" && ! grep -q "starting VM" "$TMP/ref"; then
    pass "$desc"
  else
    fail "$desc (exit $rc: $(tail -n 1 "$TMP/ref"))"
  fi
}

# --- 1. The recipe command, with fixtures ------------------------------------------------
export FC_RECIPES_DIR="$FIX"
list="$("$FCCTL" recipe list 2>/dev/null)"
expect "list shows a valid recipe with its inputs" grep -qE '^fx-echo +command +isolated +\[sample\], \[rules\]' <<<"$list"
expect "list names an invalid manifest" grep -qE '^fx-bad +INVALID: invalid field net' <<<"$list"
expect "list shows a one-of input" grep -qE '^fx-pkg .*sample\|package' <<<"$list"
expect "list does not show the shared folder" not grep -q '^_lib' <<<"$list"
json="$("$FCCTL" recipe list --json 2>/dev/null)"
expect "list --json is valid and marks the invalid recipe" test "$(jq -r '[.[] | select(.valid == false) | .name] | join(",")' <<<"$json")" = fx-bad
expect "list --json gives kind, net and inputs" test "$(jq -r '.[] | select(.name == "fx-need") | .kind + " " + .net + " " + .input.sample' <<<"$json")" = "command isolated required"
expect "doctor reports the invalid manifest" grep -qE 'FAIL.*recipes|invalid manifest in: fx-bad' <<<"$("$FCCTL" doctor 2>&1)"

mkdir -p "$TMP/sample dir/sub" "$TMP/rules"
echo data > "$TMP/sample dir/a file.bin"
echo x > "$TMP/sample dir/sub/run.sh"
echo 'rule r { condition: true }' > "$TMP/rules/r.yar"

rrun fx-echo --sample "$TMP/sample dir/a file.bin" --rules "$TMP/rules"
rep="$RESULTS/$RUN/out/report.md"
expect "a recipe run exits with the recipe's exit code (0)" test "$RC" = 0
expect "a file sample arrives under its own name" grep -q "kind=file sample=a file.bin rules=1" "$rep"
expect "the sample is the only file in /work/in" grep -q "^in: a file.bin $" "$rep"
expect "the rules folder arrives in /work/rules" grep -q "^rules: r.yar $" "$rep"
expect "shared recipe files arrive in /work/recipe/_lib" grep -q "^lib: shared file$" "$rep"
expect "the manifest's network mode applies (loopback only)" grep -q "^ifaces: lo $" "$rep"
expect "the manifest's vCPUs apply" grep -q "^cpus=1$" "$rep"
expect "meta.json records the recipe and the sample name" \
  test "$(jq -r '.recipe.name + "|" + .recipe.kind + "|" + .recipe.sample + "|" + .net + "|" + (.vcpu|tostring)' "$RESULTS/$RUN/meta.json")" = "fx-echo|command|a file.bin|isolated|1"
expect "report.json is collected" test -s "$RESULTS/$RUN/out/report.json"

rrun fx-echo --sample "$TMP/sample dir" --vcpu 2
expect "a folder sample's contents arrive in /work/in" grep -q "kind=dir sample= rules=0" "$RESULTS/$RUN/out/report.md"
expect "--vcpu overrides the manifest's default" grep -q "cpus=2" "$RESULTS/$RUN/out/report.md"
rrun fx-pkg --package "left-pad@1.3.0"
expect "a package spec reaches the guest unchanged" grep -qx "pkg=left-pad@1.3.0" "$RESULTS/$RUN/out/report.md"
expect "meta.json records the package" test "$(jq -r .recipe.package "$RESULTS/$RUN/meta.json")" = "left-pad@1.3.0"
rrun fx-entry --sample "$TMP/sample dir" --entry sub/run.sh
expect "an entry reaches the guest" grep -qx "entry=sub/run.sh" "$RESULTS/$RUN/out/report.md"

refused "unknown recipe is refused, naming the recipes" "unknown recipe 'nope' .*fx-echo" nope
refused "invalid manifest is refused, naming the field" "fx-bad.*invalid field net" fx-bad
refused "--net is refused" "recipe fixes" fx-echo --net networked
refused "--cmd is refused" "recipe fixes" fx-echo --cmd true
refused "--payload is refused" "recipe fixes" fx-echo --payload "$TMP"
refused "--agent-direct is refused" "recipe fixes" fx-agent --agent claude --agent-direct
refused "--image is refused" "recipe fixes" fx-echo --image agent
refused "missing required sample is refused" "needs a sample" fx-need
refused "sample that does not exist is refused" "not found" fx-need --sample "$TMP/nope"
refused "input the recipe does not take is refused" "takes no package" fx-echo --package x
refused "sample and package together are refused" "not both" fx-pkg --sample "$TMP/rules" --package x
refused "neither sample nor package is refused" "needs a sample .* or a package" fx-pkg
refused "shell characters in a package spec are refused" "invalid package spec" fx-pkg --package 'x; rm -rf /'
refused "a package spec starting with a dash is refused" "invalid package spec" fx-pkg --package '--registry=http://x'
refused "a folder sample without --entry is refused" "needs --entry" fx-entry --sample "$TMP/sample dir"
refused "--entry outside the sample is refused" "invalid --entry" fx-entry --sample "$TMP/sample dir" --entry ../x
refused "--entry that does not exist is refused" "not found in the sample" fx-entry --sample "$TMP/sample dir" --entry nope.sh
refused "an agent recipe without a profile is refused" "needs an agent profile" fx-agent
refused "--agent on a command recipe is refused" "not an agent recipe" fx-echo --agent claude
"$FCCTL" run --payload "$TMP/rules" --cmd true --sample "$TMP/rules" --results-dir "$RESULTS" >/dev/null 2>"$TMP/ref"
expect "--sample outside the recipe command is refused (125)" test "$?" = 125
unset FC_RECIPES_DIR

# --- 2. Sandbox self-tests ----------------------------------------------------------------
expect "the eight starter recipes are installed and valid" \
  test "$("$FCCTL" recipe list --json 2>/dev/null | jq -r '[.[] | select(.valid) | .name] | sort | join(" ")')" \
  = "agent-escape agent-triage detonate npm-check pip-check probe probe-net triage-static"
rrun probe
expect "probe passes on an isolated VM (exit 0)" test "$RC" = 0
expect "probe saw only the loopback interface" \
  test "$(jq -r '.checks[] | select(.target == "interfaces") | .found + "/" + .status' "$RESULTS/$RUN/out/report.json")" = "lo/pass"
expect "probe found nothing reachable" test "$(jq -r '.summary.fail' "$RESULTS/$RUN/out/report.json")" = 0
expect "probe tested the hosts it was told about" grep -q "Windows host (" "$RESULTS/$RUN/out/report.md"
expect "probe wrote report.md with its limits" grep -q "Limits of this evidence" "$RESULTS/$RUN/out/report.md"
rrun probe-net
expect "probe-net passes on a networked VM (exit 0)" test "$RC" = 0
expect "probe-net: hosts, private ranges and other VMs stay blocked" \
  test "$(jq -r '[.checks[] | select(.expect == "blocked" and .status != "pass")] | length' "$RESULTS/$RUN/out/report.json")" = 0
expect "probe-net: the internet is open" \
  test "$(jq -r '.checks[] | select(.target | startswith("internet by address")) | .status' "$RESULTS/$RUN/out/report.json")" = pass
expect "probe-net ran networked" test "$(jq -r .net "$RESULTS/$RUN/meta.json")" = networked

# A blocked destination that answers fails the run; an open one that does not only warns.
PX="$TMP/px"; mkdir -p "$PX/probe-fail" "$PX/probe-warn"
cp -r /opt/fc-sandbox/recipes/_lib "$PX/_lib"
cat > "$PX/probe-fail/recipe.json" <<'EOF'
{ "description": "probe with a reachable 'blocked' target", "kind": "command", "image": "base", "net": "isolated",
  "command": "python3 -m http.server 9999 --bind 127.0.0.1 </dev/null >/dev/null 2>&1 & srv=$!; sleep 2; FC_PROBE_EXTRA_BLOCKED=127.0.0.1:9999 python3 /work/recipe/_lib/probe.py isolated; rc=$?; kill $srv; exit $rc",
  "input": {} }
EOF
cat > "$PX/probe-warn/recipe.json" <<'EOF'
{ "description": "networked probe in a VM without network", "kind": "command", "image": "base", "net": "isolated",
  "command": "python3 /work/recipe/_lib/probe.py networked", "input": {} }
EOF
export FC_RECIPES_DIR="$PX"
rrun probe-fail
expect "a blocked destination that answers fails the run (exit 1)" test "$RC" = 1
expect "the report marks that check as failed" \
  test "$(jq -r '.checks[] | select(.target == "extra (127.0.0.1:9999)") | .status' "$RESULTS/$RUN/out/report.json")" = fail
rrun probe-warn
expect "an unreachable internet is a warning, not a failure (exit 0)" \
  test "$RC/$(jq -r '.checks[] | select(.target | startswith("internet by address")) | .status' "$RESULTS/$RUN/out/report.json")" = "0/warn"
unset FC_RECIPES_DIR

# --- 3. Static triage and detonation ------------------------------------------------------
S="$HERE/samples"
rj() { jq -r "$1" "$RESULTS/$RUN/out/report.json"; }

cp /bin/ls "$TMP/ls.elf"
rrun triage-static --sample "$TMP/ls.elf"
expect "triage-static exits 0 with both reports" test "$RC/$(ls "$RESULTS/$RUN/out" | grep -c '^report\.\(md\|json\)$')" = "0/2"
expect "triage of an ELF file: hash, format and libraries" \
  test "$(rj '.files[0].sha256 + " " + .files[0].format + " " + (.files[0].libraries | index("libc.so.6") | tostring)')" \
  = "$(sha256sum < "$TMP/ls.elf" | cut -d' ' -f1) ELF $(rj '.files[0].libraries | index("libc.so.6") | tostring')"
expect "triage of an ELF file: section table in the report" grep -q '\.text' "$RESULTS/$RUN/out/report.md"
expect "triage without rules says the YARA scan was skipped" grep -q "scan was skipped because no rules were given" "$RESULTS/$RUN/out/report.md"
expect "the full strings list is collected" test -s "$RESULTS/$RUN/out/strings/001.txt"
expect "meta.json records triage-static and the sample" test "$(jq -r '.recipe.name + "/" + .recipe.sample' "$RESULTS/$RUN/meta.json")" = "triage-static/ls.elf"

rrun triage-static --sample "$S/dropper.sh" --rules "$S/rules"
expect "triage with rules lists the matching rule" test "$(rj '.files[0].yara.matches[0].rule')" = fc_test_sample
expect "triage of a text file finds notable strings" test "$(rj '[.files[0].strings.interesting[] | select(. == "http://203.0.113.5/beacon")] | length')" = 1
expect "the sample was not executed (nothing dropped a trace)" not test -e "$RESULTS/$RUN/out/trace.log"

PE=/mnt/c/Windows/System32/whoami.exe
if [ -f "$PE" ]; then
  rrun triage-static --sample "$PE"
  expect "triage of a Windows executable: PE format with imported DLLs" \
    test "$(rj '.files[0].format + " " + ((.files[0].libraries | length) > 0 | tostring)')" = "PE true"
else
  echo "  skip triage of a Windows executable ($PE not found)"
fi

rrun detonate --sample "$S/dropper.sh"
expect "detonate exits 0 although the sample exited 7" test "$RC/$(rj .run.exit_code)" = "0/7"
expect "detonate lists the file the sample dropped" test "$(rj '.files.written | index("/tmp/dropped") != null')" = true
expect "detonate lists the process the sample started" test "$(rj '[.processes[] | select(.argv[0] == "id")] | length')" = 1
expect "detonate lists the failed connection attempt" \
  test "$(rj '.connections[] | select(.address == "203.0.113.5") | (.port | tostring) + " " + (.result != "connected" | tostring)')" = "443 true"
expect "the report states the limits of tracing" grep -q "can detect tracing" "$RESULTS/$RUN/out/report.md"
expect "the raw trace and the sample's output are collected" test -s "$RESULTS/$RUN/out/trace.log" -a -s "$RESULTS/$RUN/out/program-stdout.log"
expect "detonate ran isolated on the agent image" test "$(jq -r .net "$RESULTS/$RUN/meta.json")" = isolated

mkdir -p "$TMP/dir sample/sub"; cp "$S/dropper.sh" "$TMP/dir sample/sub/go.sh"; echo notes > "$TMP/dir sample/readme.txt"
rrun detonate --sample "$TMP/dir sample" --entry sub/go.sh
expect "detonate runs the --entry of a folder sample" test "$(rj '.sample + " " + (.run.exit_code | tostring)')" = "sub/go.sh 7"
echo "just text" > "$TMP/notes.txt"
rrun detonate --sample "$TMP/notes.txt"
expect "a file that cannot be run is reported, and the recipe exits 0" test "$RC/$(rj .runnable)" = "0/false"

# The time limit, with a 5-second copy of the recipe: the sample never ends and leaves a child behind.
DX="$TMP/dx"; mkdir -p "$DX"; cp -r /opt/fc-sandbox/recipes/_lib /opt/fc-sandbox/recipes/detonate "$DX/"
sed -i 's/detonate\.py 120/detonate.py 5/' "$DX/detonate/recipe.json"
export FC_RECIPES_DIR="$DX"
t0=$(date +%s)
rrun detonate --sample "$S/sleeper.sh" --timeout 3m
expect "a sample that does not end is stopped and still reported" test "$RC/$(rj .run.timed_out)" = "0/true"
expect "the report says the sample was stopped" grep -q "stopped after 5 s" "$RESULTS/$RUN/out/report.md"
expect "what it did before the limit is in the report" test "$(rj '.files.written | index("/tmp/sleeper-started") != null')" = true
expect "a leftover process does not keep the run open" test $(( $(date +%s) - t0 )) -lt 90
unset FC_RECIPES_DIR

# --- 4. Package install checks (networked: these need the npm registry and PyPI) ----------
rrun npm-check --sample "$S/npm-pkg"
expect "npm-check exits 0 and ran networked" test "$RC/$(jq -r .net "$RESULTS/$RUN/meta.json")" = "0/networked"
expect "npm-check names the install script and saw it run" \
  test "$(rj '.install_scripts[0] | .package + " " + .hook + " " + (.ran | tostring)')" = "fc-test-npm-pkg postinstall true"
expect "npm-check lists the process the script started" test "$(rj '[.processes[] | select(.argv[0] == "id")] | length')" = 1
expect "npm-check lists the file written outside the install folder" test "$(rj '.files_outside_install_folder | join(",")')" = /tmp/npm-marker
expect "npm-check states that the evidence is guest-side" grep -q "recorded inside the guest" "$RESULTS/$RUN/out/report.md"
rrun npm-check --package left-pad@1.3.0
expect "npm-check installs exactly the named package version" test "$RC/$(rj '.installed | join(",")')" = "0/left-pad@1.3.0"
expect "npm-check lists the registry connections" test "$(rj '[.connections[] | select(.port == 443)] | length > 0')" = true
expect "meta.json records the package" test "$(jq -r .recipe.package "$RESULTS/$RUN/meta.json")" = "left-pad@1.3.0"

rrun pip-check --sample "$S/pip-pkg"
expect "pip-check exits 0 and installed the project" test "$RC/$(rj '.installed | join(",")')" = "0/fc_test_pip_pkg==0.0.1"
expect "pip-check saw the build code run" test "$(rj '.install_scripts | length > 0')" = true
expect "pip-check lists the process the build code started" test "$(rj '[.processes[] | select(.argv[0] == "id")] | length > 0')" = true
expect "pip-check lists the file written outside the install folder" test "$(rj '.files_outside_install_folder | index("/tmp/pip-marker") != null')" = true
rrun pip-check --package six==1.16.0
expect "pip-check installs exactly the named package version" test "$RC/$(rj '.installed | join(",")')" = "0/six==1.16.0"
expect "a wheel install runs no build code" test "$(rj '.install_scripts | length')" = 0

# --- 5. Agent recipes, against the fake provider (no real API) -----------------------------
FP_PORT=18095
FP_LOG="$TMP/fp.jsonl"
FAKE_PROVIDER_DELAY=8 python3 "$HERE/fake-provider.py" "$FP_PORT" "$FP_LOG" &
fp=$!
trap 'kill $fp 2>/dev/null; rm -rf "$TMP"' EXIT
sleep 1
export FC_GATEWAY_TEST_UPSTREAM="http://127.0.0.1:$FP_PORT"
stash() { local r; r="smoke$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; echo "sk-smoke-recipe" | "$FCCTL" _stash-key "$r"; echo "$r"; }

# The provider answers after 8 s, so the VM can be inspected while the agent waits for it.
ERR="$TMP/err.agent"
"$FCCTL" recipe agent-triage --agent claude --key-ref "$(stash)" --sample "$S/dropper.sh" --rules "$S/rules" \
  --timeout 3m --results-dir "$RESULTS" >/dev/null 2>"$ERR" &
ctl=$!
seen=""
for _ in $(seq 240); do
  kill -0 $ctl 2>/dev/null || break
  vm="$(sed -n 's/^\[fcctl\] starting VM \([^ ]*\) .*/\1/p' "$ERR" 2>/dev/null | head -1)"
  if [ -n "$vm" ] && [ -s "$FP_LOG" ]; then
    seen="$("$FCCTL" ssh "$vm" 'ls /work/in /work/rules; head -n 1 /work/.fc/prompt.md' 2>/dev/null </dev/null)"
    break
  fi
  sleep 0.25
done
wait $ctl; RC=$?
RUN="$(sed -n 's/^\[fcctl\] results: .*\/\([^/ ]*\) (exit code.*/\1/p' "$ERR" | tail -1)"
expect "agent-triage runs to the client's exit code (0)" test "$RC" = 0
expect "agent-triage ran in gateway mode without network" \
  test "$(jq -r '.agent.mode + " " + .net + " " + .recipe.name + " " + .recipe.kind' "$RESULTS/$RUN/meta.json")" = "gateway isolated agent-triage agent"
expect "the transcript and llm.log are collected" test -s "$RESULTS/$RUN/out/agent-transcript.jsonl" -a -s "$RESULTS/$RUN/llm.log"
expect "the provider was called through the gateway" grep -q FAKE-PROVIDER-REPLY "$RESULTS/$RUN/out/agent-transcript.jsonl"
expect "the recipe's prompt arrived in the guest" grep -q "examine a suspicious sample without running it" <<<"$seen"
expect "the sample arrived in /work/in" grep -qx "dropper.sh" <<<"$seen"
expect "the rules arrived in /work/rules" grep -qx "test.yar" <<<"$seen"

rrun agent-escape --agent claude --key-ref "$(stash)" --timeout 3m
expect "agent-escape runs in gateway mode (exit 0)" test "$RC/$(jq -r '.agent.mode + " " + .recipe.name' "$RESULTS/$RUN/meta.json")" = "0/gateway agent-escape"
refused "an agent recipe without a profile is refused" "needs an agent profile" agent-escape
refused "direct mode is refused for an agent recipe" "recipe fixes" agent-escape --agent claude --agent-direct
refused "agent-triage without a sample is refused" "needs a sample" agent-triage --agent claude
refused "an agent recipe without a key is refused" "no API key" agent-escape --agent claude
expect "no stashed key is left" test -z "$(ls -A /var/lib/fc-sandbox/keys)"
unset FC_GATEWAY_TEST_UPSTREAM

expect "no leftovers" no_leftovers
finish
