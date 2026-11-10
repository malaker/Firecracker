# Agent VMs and the LLM gateway (change: in-sandbox-agents).

FC_AGENTS="$FC_HOME/agents"
FC_AGENT_ROOTFS="$FC_HOME/images/agent-rootfs.ext4"
FC_GATEWAY_BIN="$FC_HOME/bin/fc-llm-gateway"
FC_GATEWAY_DIR="$FC_STATE/gw"
FC_KEYS="$FC_STATE/keys"
# Gateway uids: outside the jailer range (FC_UID_BASE + slot) and the airlock reader range.
FC_GATEWAY_UID_BASE=210000
FC_GATEWAY_VSOCK_PORT=8080

# URL of the Ollama server for the codex-ollama profile: FC_OLLAMA_URL from agents/local.env
# (fc.ps1 setup -OllamaUrl), else the Windows host as seen from WSL (its default gateway), port 11434.
agent_ollama_url() {
  local url=""
  if [ -f "$FC_AGENTS/local.env" ]; then
    # shellcheck source=/dev/null
    url="$(. "$FC_AGENTS/local.env"; echo "${FC_OLLAMA_URL:-}")"
  fi
  if [ -z "$url" ]; then
    local gw
    gw="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
    [ -n "$gw" ] && url="http://$gw:11434"
  fi
  echo "$url"
}

# profile_get <profile> <jq-path>: one value from profiles.json ("" when absent).
profile_get() {
  jq -r --arg p "$1" ".profiles[\$p]$2 // empty" "$FC_AGENTS/profiles.json" 2>/dev/null
}

profile_exists() { [ -n "$(profile_get "$1" .client)" ]; }

profile_names() { jq -r '.profiles | keys | join(", ")' "$FC_AGENTS/profiles.json" 2>/dev/null; }

# key_ref_path <nonce>: the stashed key file for a --key-ref (validated name, no path tricks).
key_ref_path() {
  [[ "$1" =~ ^[A-Za-z0-9]{16,64}$ ]] || return 1
  echo "$FC_KEYS/$1"
}

# _stash-key <nonce>: stores the key from stdin (first line, at most 4 KiB, without a UTF-8 BOM or
# surrounding whitespace) for one run.
cmd_stash_key() {
  local f
  f="$(key_ref_path "${POSITIONAL[0]:-}")" || die "invalid key reference"
  install -d -m 0700 "$FC_KEYS"
  ( umask 077; head -c 4096 | head -n 1 | LC_ALL=C sed -e '1s/^\xEF\xBB\xBF//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '\r\n' > "$f" )
  [ -s "$f" ] || { rm -f "$f"; die "no key on stdin"; }
}

# gateway_start <id> <slot> <profile> <key-file|""> [token-budget]
# Starts the per-VM gateway as an unprivileged uid whose primary group is the VM's jail gid, waits
# for its socket, and hard-links the socket into the jail as v.sock_8080 (design D2, spike 1.1).
# The key file is removed as soon as the gateway has it on stdin. Returns non-zero on failure.
gateway_start() {
  local id="$1" slot="$2" profile="$3" keyfile="$4" budget="${5:-}"
  local guid=$(( FC_GATEWAY_UID_BASE + slot )) juid=$(( FC_UID_BASE + slot ))
  local d="$FC_GATEWAY_DIR/$id" jailroot pid i args=() envs=(PATH=/usr/bin:/bin)
  jailroot="$(jail_dir "$id")/root"
  install -d -m 0711 "$FC_GATEWAY_DIR"
  install -d -m 0750 -o "$guid" -g "$juid" "$d"
  args=(--profiles "$FC_AGENTS/profiles.json" --profile "$profile" --socket "$d/llm.sock"
        --log "$d/llm.log" --totals "$d/totals.json")
  [ "$(profile_get "$profile" .upstream)" = ollama ] && args+=(--upstream-url "$(agent_ollama_url)")
  [ -n "$budget" ] && args+=(--token-budget "$budget")
  # Test-only override (smoke tests); the gateway itself accepts only http://127.0.0.1:<port>.
  [ -n "${FC_GATEWAY_TEST_UPSTREAM:-}" ] && envs+=(FC_GATEWAY_TEST_UPSTREAM="$FC_GATEWAY_TEST_UPSTREAM")
  # Open the key here, then delete the file: the gateway gets it only on stdin, and the redirection
  # in the background child cannot race the delete.
  local kfd
  if [ -n "$keyfile" ]; then exec {kfd}<"$keyfile"; rm -f "$keyfile"; else exec {kfd}</dev/null; fi
  setsid setpriv --reuid="$guid" --regid="$juid" --clear-groups --no-new-privs \
    env -i "${envs[@]}" "$FC_GATEWAY_BIN" "${args[@]}" <&"$kfd" > "$d/gateway.err" 2>&1 &
  pid=$!
  exec {kfd}<&-
  meta_set "$id" gateway_pid "$pid"
  for (( i = 0; i < 150; i++ )); do
    [ -S "$d/llm.sock" ] && break
    [ -d "/proc/$pid" ] || break
    sleep 0.1
  done
  if [ ! -S "$d/llm.sock" ]; then
    log "the LLM gateway did not start: $(tail -n 3 "$d/gateway.err" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  ln "$d/llm.sock" "$jailroot/v.sock_$FC_GATEWAY_VSOCK_PORT"
}

# gateway_stop <id>: stops the VM's gateway (no-op without one). Its folder (llm.log, totals)
# stays until gateway_discard, so a run can copy the log first.
gateway_stop() {
  local pid
  pid="$(meta_get "$1" gateway_pid)"
  [ -n "$pid" ] && kill_pid "$pid"
  return 0
}

gateway_discard() { [ -n "$1" ] && rm -rf "${FC_GATEWAY_DIR:?}/$1"; }

# --- agent runs (fcctl run/shell --agent) -------------------------------------------
# Set by agent_check_opts; read by cmd_run/cmd_shell.
AGENT_PROFILE="" AGENT_CLIENT="" AGENT_MODEL="" AGENT_MODE="" AGENT_KEYFILE="" AGENT_CLIENT_VERSION=""

# Validates the agent options before anything starts (exit 125 via die) and prepares the VM options:
# agent image, network mode, and the gateway settings vm_create picks up.
agent_check_opts() {
  local p="$OPT_AGENT"
  profile_exists "$p" || die "unknown agent profile '$p' (available: $(profile_names))"
  AGENT_PROFILE="$p"
  AGENT_CLIENT="$(profile_get "$p" .client)"
  AGENT_MODEL="${OPT_MODEL:-$(profile_get "$p" .default_model)}"
  [[ "$AGENT_MODEL" =~ ^[A-Za-z0-9._:/-]{1,100}$ ]] || die "invalid --model '$AGENT_MODEL'"
  if (( OPT_AGENT_DIRECT )); then
    [ "$(profile_get "$p" .direct)" = true ] \
      || die "direct mode is not available for profile '$p' (host protection blocks the host's Ollama server); use gateway mode"
    AGENT_MODE=direct
    OPT_NET=networked
    log "WARNING: direct mode - the API key is inside the VM; do not use it with untrusted payloads"
  else
    AGENT_MODE=gateway
    [ "$OPT_NET" = isolated ] || die "--net networked is only for direct mode (--agent-direct); gateway-mode agents have no network"
    VM_GATEWAY_PROFILE="$p"
    VM_GATEWAY_BUDGET="$OPT_TOKEN_BUDGET"
  fi
  if [ -n "$OPT_TOKEN_BUDGET" ]; then
    [[ "$OPT_TOKEN_BUDGET" =~ ^[1-9][0-9]{0,11}$ ]] || die "invalid --token-budget '$OPT_TOKEN_BUDGET'"
  fi
  if [ "$(profile_get "$p" .auth)" != none ]; then
    [ -n "$OPT_KEY_REF" ] && AGENT_KEYFILE="$(key_ref_path "$OPT_KEY_REF")" && [ -s "$AGENT_KEYFILE" ] \
      || die "no API key for profile '$p': set $(profile_get "$p" .key_env) or create the key file (see README, Agents)"
    [ "$AGENT_MODE" = gateway ] && VM_GATEWAY_KEYFILE="$AGENT_KEYFILE"
  fi
  OPT_IMAGE=agent
}

# Writes the agent settings, the prompt (if any) and, in direct mode, the key into the guest.
# Everything travels over SSH stdin, never on a command line.
agent_prepare_guest() {
  local id="$1" prompt="${2:-}"
  printf 'FC_AGENT_PROFILE=%q\nFC_AGENT_CLIENT=%q\nFC_AGENT_MODEL=%q\nFC_AGENT_MODE=%q\n' \
    "$AGENT_PROFILE" "$AGENT_CLIENT" "$AGENT_MODEL" "$AGENT_MODE" \
    | fc_ssh "$id" 'mkdir -p /work/.fc /work/out && cat > /work/.fc/agent.env' || return 1
  if [ -n "$prompt" ]; then
    fc_ssh "$id" 'cat > /work/.fc/prompt.md' < "$prompt" || return 1
  fi
  if [ "$AGENT_MODE" = direct ] && [ -n "$AGENT_KEYFILE" ]; then
    fc_ssh "$id" 'umask 077; mkdir -p /root/.fc-agent && cat > /root/.fc-agent/key' < "$AGENT_KEYFILE" || return 1
    rm -f "$AGENT_KEYFILE"
  fi
  AGENT_CLIENT_VERSION="$(fc_ssh "$id" "$AGENT_CLIENT --version" </dev/null 2>/dev/null | head -n 1 | tr -cd '[:print:]')"
}

# The meta.json "agent" object; in gateway mode with the gateway's totals.
agent_meta_json() {
  local totals="${1:-}"
  jq -n --arg p "$AGENT_PROFILE" --arg c "$AGENT_CLIENT" --arg v "$AGENT_CLIENT_VERSION" \
    --arg prov "$(profile_get "$AGENT_PROFILE" .provider)" --arg m "$AGENT_MODEL" --arg mode "$AGENT_MODE" \
    --argjson t "$( [ -n "$totals" ] && [ -s "$totals" ] && cat "$totals" || echo null)" \
    '{profile:$p, client:$c, client_version:$v, provider:$prov, model:$m, mode:$mode}
     + (if $t == null then {} else {requests:$t.requests, refused:$t.refused, tokens:$t.tokens} end)'
}

# _drop-key <nonce>: removes a stashed key that a failed run never used (fc.ps1 calls it at the end).
cmd_drop_key() {
  local f
  f="$(key_ref_path "${POSITIONAL[0]:-}")" || die "invalid key reference"
  rm -f "$f"
}
