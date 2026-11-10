#!/usr/bin/env bash
# Agent VMs and the LLM gateway (spec: llm-gateway, sandbox-agents). Uses a local fake provider
# (fake-provider.py) through FC_GATEWAY_TEST_UPSTREAM; only the direct-mode check talks to the real
# Anthropic API, with an invalid key, to show the VM reaches the provider itself.
. "$(dirname "$0")/lib.sh"
echo "== agents"

HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=18090
FP_LOG="$(mktemp)"
python3 "$HERE/fake-provider.py" "$PORT" "$FP_LOG" &
fp=$!
trap 'kill $fp 2>/dev/null' EXIT
sleep 1
export FC_GATEWAY_TEST_UPSTREAM="http://127.0.0.1:$PORT"
SECRET="sk-smoke-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export FC_SCAN_SECRET="$SECRET"
PROMPT="$(mktemp)"; printf 'Say hello; it'"'"'s a "test" & more\n' > "$PROMPT"

stash() { local r; r="smoke$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; echo "$SECRET" | "$FCCTL" _stash-key "$r"; echo "$r"; }
gw_procs() { ps -eo uid= | awk '$1 >= 210000 && $1 < 226384' | wc -l; }

# 1. Headless run (Claude Code against the fake provider), scanning command lines meanwhile.
ref="$(stash)"
"$FCCTL" run --agent claude --prompt-file "$PROMPT" --key-ref "$ref" --results-dir "$RESULTS" --timeout 3m >/dev/null 2>"$RESULTS/run.err" &
ctl=$!
leaks=0
while kill -0 $ctl 2>/dev/null; do
  (( $(bash "$HERE/scan-cmdlines.sh") == 0 )) || leaks=$((leaks + 1))
  sleep 0.5
done
wait $ctl; rc=$?
run="$(sed -n 's/^\[fcctl\] results: .*\/\([^/ ]*\) (exit code.*/\1/p' "$RESULTS/run.err" | tail -1)"
expect "agent run exits with the client's exit code (0)" test "$rc" = 0
expect "key never on a process command line" test "$leaks" = 0
expect "transcript collected through the airlock" test -s "$RESULTS/$run/out/agent-transcript.jsonl"
expect "transcript has the provider's reply" grep -q FAKE-PROVIDER-REPLY "$RESULTS/$run/out/agent-transcript.jsonl"
expect "llm.log has a forwarded call" grep -q "decision=forwarded" "$RESULTS/$run/llm.log"
expect "meta.json records the agent" test "$(jq -r '.agent.profile + " " + .agent.mode + " " + (.agent.requests|tostring)' "$RESULTS/$run/meta.json")" = "claude gateway 1"
expect "the provider got the real key" grep -qF "\"x-api-key\": \"$SECRET\"" "$FP_LOG"
expect "the key is not in the results" not grep -rqF "$SECRET" "$RESULTS/$run"
expect "the gateway is gone after the run" test "$(gw_procs)" = 0
expect "no stashed key is left" test -z "$(ls -A /var/lib/fc-sandbox/keys)"

# 2. Probes from inside an agent VM (shell --agent, commands on stdin).
ref="$(stash)"
probe="$(printf '%s\n' \
  'echo "ok=$(curl -s -o /dev/null -w %{http_code} -X POST http://127.0.0.1:8080/v1/messages -H content-type:application/json -d "{\"model\":\"claude-x\"}")"' \
  'echo "endpoint=$(curl -s -o /dev/null -w %{http_code} -X DELETE http://127.0.0.1:8080/v1/files/1)"' \
  'echo "model=$(curl -s -o /dev/null -w %{http_code} -X POST http://127.0.0.1:8080/v1/messages -H content-type:application/json -d "{\"model\":\"gpt-5\"}")"' \
  'head -c 17000000 /dev/zero | tr "\0" a > /tmp/big; echo "size=$(curl -s -o /dev/null -w %{http_code} -X POST http://127.0.0.1:8080/v1/messages -H content-type:application/json --data-binary @/tmp/big)"' \
  'echo "internet=$(curl -s -m 5 -o /dev/null -w %{http_code} https://example.com || true)"' \
  'echo "keyinguest=$(grep -rlsF -- "'"$SECRET"'" /root /work /etc /tmp 2>/dev/null | wc -l) envkey=$(env | grep -cF -- "'"$SECRET"'")"' \
  'for i in 1 2 3; do curl -s -o /dev/null -X POST http://127.0.0.1:8080/v1/messages -H content-type:application/json -d "{\"model\":\"claude-x\"}"; done; echo "budget=$(curl -s -o /dev/null -w %{http_code} -X POST http://127.0.0.1:8080/v1/messages -H content-type:application/json -d "{\"model\":\"claude-x\"}")"' \
  'exit' \
  | "$FCCTL" shell --agent claude --key-ref "$ref" --token-budget 40 --timeout 5m 2>/dev/null)"
val() { sed -n "s/.*$1=\([0-9a-z]*\).*/\1/p" <<<"$probe" | head -1; }
expect "guest reaches the gateway at 127.0.0.1:8080" test "$(val ok)" = 200
expect "unlisted endpoint is refused (403)" test "$(val endpoint)" = 403
expect "unlisted model is refused (403)" test "$(val model)" = 403
expect "oversized request is refused (413)" test "$(val size)" = 413
expect "no internet from a gateway-mode VM" test "$(val internet)" = 000
expect "no real key in the guest's files or environment" test "$(val keyinguest)/$(val envkey)" = "0/0"
expect "token budget is enforced (429)" test "$(val budget)" = 429
expect "the gateway is gone after the shell" test "$(gw_procs)" = 0

# 3. Cleanup after a killed controller.
ref="$(stash)"
"$FCCTL" run --agent claude --prompt-file "$PROMPT" --key-ref "$ref" --results-dir "$RESULTS" --timeout 5m >/dev/null 2>&1 &
ctl=$!
for _ in $(seq 120); do (( $(gw_procs) > 0 )) && break; sleep 0.25; done
kill -9 $ctl 2>/dev/null; sleep 1
"$FCCTL" cleanup 2>/dev/null
expect "cleanup removes gateways, sockets and keys" \
  test "$(gw_procs)/$(ls -A /var/lib/fc-sandbox/gw | wc -l)/$(ls -A /var/lib/fc-sandbox/keys | wc -l)" = "0/0/0"

# 4. Refusals and direct mode.
"$FCCTL" run --agent nope --prompt-file "$PROMPT" --results-dir "$RESULTS" >/dev/null 2>&1
expect "unknown profile exits 125" test "$?" = 125
"$FCCTL" run --agent claude --prompt-file "$PROMPT" --results-dir "$RESULTS" >/dev/null 2>&1
expect "missing key exits 125" test "$?" = 125
"$FCCTL" run --agent codex-ollama --agent-direct --prompt-file "$PROMPT" --results-dir "$RESULTS" >/dev/null 2>&1
expect "no direct mode for codex-ollama (125)" test "$?" = 125
echo "sk-ant-invalid-smoke-direct" | "$FCCTL" _stash-key smokedirect0123456789ab
"$FCCTL" run --agent claude --agent-direct --prompt-file "$PROMPT" --key-ref smokedirect0123456789ab --results-dir "$RESULTS" --timeout 3m >/dev/null 2>"$RESULTS/direct.err"
drun="$(sed -n 's/^\[fcctl\] results: .*\/\([^/ ]*\) (exit code.*/\1/p' "$RESULTS/direct.err" | tail -1)"
expect "direct mode warns that the key is in the VM" grep -q "API key is inside the VM" "$RESULTS/direct.err"
expect "direct mode runs networked without a gateway" test "$(jq -r '.net + " " + .agent.mode' "$RESULTS/$drun/meta.json")/$([ -e "$RESULTS/$drun/llm.log" ] && echo log)" = "networked direct/"
expect "direct mode reached the provider itself" grep -qiE "invalid api key|authentication" "$RESULTS/$drun/out/agent-transcript.jsonl"

# 5. A key piped with a UTF-8 BOM and CRLF (Windows PowerShell 5.1) is stored bare.
printf '\xef\xbb\xbf sk-bom-check \r\n' | "$FCCTL" _stash-key smokebom0123456789abcd
expect "_stash-key strips a BOM, spaces and CRLF" test "$(cat /var/lib/fc-sandbox/keys/smokebom0123456789abcd)" = "sk-bom-check"
"$FCCTL" _drop-key smokebom0123456789abcd

expect "no leftovers" no_leftovers
rm -f "$PROMPT" "$FP_LOG"
finish
