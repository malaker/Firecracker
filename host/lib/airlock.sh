# Guest output airlock (change: guest-output-airlock, design D4/D6/D8/D9).
# Guest files reach the host only through a fresh airlock VM: the host copies the guest's
# tar stream as opaque bytes, fc-airlock validates and re-encodes it inside the airlock as
# 'nobody', and fc-airlock unpacks it again on the host as a throwaway unprivileged uid.
# The host never runs tar on guest data.

FC_AIRLOCK_BIN="$FC_HOME/bin/fc-airlock"
FC_STAGING="$FC_STATE/staging"
# Per-transfer reader uids: outside the jailer's range (FC_UID_BASE + slot) and without
# passwd entries; claimed atomically with mkdir under $FC_STAGING.
FC_UNPACK_UID_BASE=200000
FC_UNPACK_UID_COUNT=1024
AIRLOCK_VCPU=1
AIRLOCK_MEM_MIB=256
AIRLOCK_LIFETIME=300
AIRLOCK_PULL_TIMEOUT=180
AIRLOCK_VALIDATE_TIMEOUT=240
AIRLOCK_UNPACK_TIMEOUT=180
AIRLOCK_GUEST_DIR=/opt/fc-airlock

# Byte cap for the guest's tar stream and for the airlock output. Must match
# FcAirlock.Core.Limits: total + 1536 * max entries + 1 MiB. FC_AIRLOCK_TEST_MAX_BYTES
# can only lower the total (tests); anything else is ignored.
airlock_max_bytes() {
  local def=$(( 1024 * 1024 * 1024 )) v="${FC_AIRLOCK_TEST_MAX_BYTES:-}"
  if [[ "$v" =~ ^[0-9]+$ ]] && (( 10#$v > 0 && 10#$v < def )); then echo $(( 10#$v )); else echo "$def"; fi
}
airlock_stream_cap() { echo $(( $(airlock_max_bytes) + 1536 * 10000 + 1024 * 1024 )); }

# Environment for fc-airlock: only the test override, and only when it lowers the limit.
airlock_tool_env() {
  local max; max="$(airlock_max_bytes)"
  (( max < 1024 * 1024 * 1024 )) && echo "FC_AIRLOCK_TEST_MAX_BYTES=$max"
  return 0
}

_airlock_result() { AIRLOCK_STATUS="$1" AIRLOCK_REASON="$2" AIRLOCK_FILES="${3:-0}" AIRLOCK_BYTES="${4:-0}"; }

# Reason from fc-airlock's one-line stderr ("refused: ...", "malformed: ...", "error: ...").
_airlock_reason() {
  local line
  line="$(grep -m1 -E '^(refused|malformed|error): ' "$1" 2>/dev/null || true)"
  line="${line#refused: }"
  printf '%s' "${line:-$2}" | tr -d '\000-\010\013-\037' | head -c 500
}

_airlock_claim_uid() {
  local i
  for (( i = 0; i < FC_UNPACK_UID_COUNT; i++ )); do
    if mkdir "$FC_STAGING/.uid-$(( FC_UNPACK_UID_BASE + i ))" 2>/dev/null; then
      echo $(( FC_UNPACK_UID_BASE + i ))
      return 0
    fi
  done
  return 1
}

# airlock_transfer <src-id> <guest-dir> <dest-dir> [after-pull-command]
# Copies <guest-dir> of running VM <src-id> into <dest-dir>, which must not exist or be empty.
# after-pull-command runs once the guest's bytes are on the host (cmd_run destroys the
# source VM there). Sets AIRLOCK_STATUS (ok|refused|failed), AIRLOCK_REASON, AIRLOCK_FILES,
# AIRLOCK_BYTES; returns 0 only for ok. Never exits the controller.
airlock_transfer() {
  local -
  set +e
  local src="$1" gdir="$2" dest="$3" after="${4:-}"
  local cap work qdir rc aid="" uid="" env_kv size first

  _airlock_result failed "" 0 0
  cap="$(airlock_stream_cap)"
  printf -v qdir '%q' "$gdir"
  env_kv="$(airlock_tool_env)"

  if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    _airlock_result failed "destination $dest is not empty"
    [ -n "$after" ] && $after
    return 1
  fi

  # 1. Empty or missing folder: nothing to transfer, no airlock (the guest only hurts itself by lying).
  first="$(fc_ssh "$src" "[ -d $qdir ] && find $qdir -mindepth 1 -print -quit" </dev/null 2>/dev/null)"
  rc=$?
  if (( rc == 255 )); then
    _airlock_result failed "could not reach VM $src to read its output"
    [ -n "$after" ] && $after
    return 1
  fi
  if [ -z "$first" ]; then
    [ -n "$after" ] && $after
    mkdir -p "$dest"
    _airlock_result ok "" 0 0
    return 0
  fi

  mkdir -p "$FC_STAGING"
  work="$(mktemp -d "$FC_STAGING/$src.XXXXXX")" || { _airlock_result failed "cannot create staging folder"; [ -n "$after" ] && $after; return 1; }
  chmod 0711 "$work"

  # 2. Pull the guest's archive as opaque bytes, capped.
  timeout -k 5 "$AIRLOCK_PULL_TIMEOUT" bash -c 'fc_ssh "$@"' _ "$src" "tar -C $qdir -cf - ." </dev/null 2>"$work/pull.err" \
    | head -c $(( cap + 1 )) > "$work/S"
  rc=("${PIPESTATUS[@]}")
  [ -n "$after" ] && $after
  size="$(stat -c %s "$work/S")"
  if (( size > cap )); then
    _airlock_result refused "guest output is larger than the ${cap}-byte cap"
  elif (( rc[0] == 124 || rc[0] == 137 )); then
    _airlock_result refused "timed out reading the guest output after ${AIRLOCK_PULL_TIMEOUT}s"
  elif (( rc[0] != 0 )); then
    _airlock_result failed "could not read the guest output (exit ${rc[0]})"
  else
    _airlock_run "$src" "$work" "$cap" "$env_kv" "$dest"
  fi
  rm -rf "${work:?}"
  [ "$AIRLOCK_STATUS" = ok ] || log "collection $AIRLOCK_STATUS: $AIRLOCK_REASON"
  [ "$AIRLOCK_STATUS" = ok ]
}

# Steps 3-8 of design D4, with S already in $work.
_airlock_run() {
  local src="$1" work="$2" cap="$3" env_kv="$4" dest="$5" aid uid rc json files bytes odd

  # 3. Fresh airlock VM. boot_vm_with exits on failure, so it runs in a subshell.
  aid="$( boot_vm_with "$AIRLOCK_VCPU" "$AIRLOCK_MEM_MIB" isolated "" "$AIRLOCK_LIFETIME" 0 airlock "$src" && echo "$VM_ID" )"
  if [ -z "$aid" ]; then
    _airlock_result failed "the airlock VM did not start"
    return
  fi

  # 4./5. Push the validator (folder mode set explicitly so 'nobody' can reach it), then validate.
  if ! fc_ssh "$aid" "mkdir -p $AIRLOCK_GUEST_DIR && chmod 0755 $AIRLOCK_GUEST_DIR && cat > $AIRLOCK_GUEST_DIR/fc-airlock && chmod 0755 $AIRLOCK_GUEST_DIR/fc-airlock" \
      < "$FC_AIRLOCK_BIN" 2>"$work/push.err"; then
    vm_destroy "$aid" 1
    _airlock_result failed "could not copy fc-airlock into the airlock"
    return
  fi
  timeout -k 5 "$AIRLOCK_VALIDATE_TIMEOUT" bash -c 'fc_ssh "$@"' _ "$aid" \
    "$env_kv setpriv --reuid=65534 --regid=65534 --clear-groups $AIRLOCK_GUEST_DIR/fc-airlock validate" \
    < "$work/S" 2>"$work/validate.err" | head -c $(( cap + 1 )) > "$work/O"
  rc=("${PIPESTATUS[@]}")
  # 6. The airlock is used once, whatever happened.
  vm_destroy "$aid" 1
  rm -f "$work/S"

  if (( $(stat -c %s "$work/O") > cap )); then _airlock_result refused "airlock output is larger than the ${cap}-byte cap"; return; fi
  case "${rc[0]}" in
    0) ;;
    3|4) _airlock_result refused "$(_airlock_reason "$work/validate.err" "refused by the airlock")"; return ;;
    124|137) _airlock_result refused "the airlock did not finish within ${AIRLOCK_VALIDATE_TIMEOUT}s"; return ;;
    *) _airlock_result failed "$(_airlock_reason "$work/validate.err" "the airlock failed (exit ${rc[0]})")"; return ;;
  esac

  # 7. Unpack as a throwaway uid that owns only the staging folder.
  uid="$(_airlock_claim_uid)" || { _airlock_result failed "no free reader uid"; return; }
  mkdir "$work/st"
  chown "$uid:$uid" "$work/st" "$work/O"
  chmod 0700 "$work/st"
  chmod 0400 "$work/O"
  # shellcheck disable=SC2086
  timeout -k 5 "$AIRLOCK_UNPACK_TIMEOUT" setpriv --reuid="$uid" --regid="$uid" --clear-groups --no-new-privs \
    env -i PATH=/usr/bin:/bin $env_kv "$FC_AIRLOCK_BIN" unpack --in "$work/O" --staging "$work/st" \
    > "$work/unpack.json" 2>"$work/unpack.err"
  rc=$?
  # Nothing the reader started may outlive it; then take the tree back before trusting it.
  pkill -KILL -U "$uid" 2>/dev/null
  sleep 0.2
  chown -R 0:0 "$work/st"
  rmdir "$FC_STAGING/.uid-$uid" 2>/dev/null

  case "$rc" in
    0) ;;
    3|4) _airlock_result refused "$(_airlock_reason "$work/unpack.err" "refused by the host check")"; return ;;
    124|137) _airlock_result failed "the host check did not finish within ${AIRLOCK_UNPACK_TIMEOUT}s"; return ;;
    *) _airlock_result failed "$(_airlock_reason "$work/unpack.err" "the host check failed (exit $rc)")"; return ;;
  esac

  # 8. Only directories and singly-linked regular files may be moved into place.
  odd="$(find "$work/st" -mindepth 1 \( \( ! -type f ! -type d \) -o \( -type f -links +1 \) \) -print -quit)"
  if [ -n "$odd" ]; then
    _airlock_result failed "unexpected entry in staging: ${odd#"$work/st/"}"
    return
  fi
  json="$(cat "$work/unpack.json")"
  files="$(jq -r '.files' <<<"$json" 2>/dev/null)"
  bytes="$(jq -r '.bytes' <<<"$json" 2>/dev/null)"
  [[ "$files" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || { _airlock_result failed "the host check returned no summary"; return; }

  rm -rf "${dest:?}.tmp"
  mkdir -p "$dest.tmp"
  if ! cp -R --no-preserve=all "$work/st/." "$dest.tmp/"; then
    rm -rf "${dest:?}.tmp"
    _airlock_result failed "could not copy the files into $dest"
    return
  fi
  if [ -d "$dest" ]; then rmdir "$dest" || { rm -rf "${dest:?}.tmp"; _airlock_result failed "destination $dest is not empty"; return; }; fi
  mv "$dest.tmp" "$dest"
  _airlock_result ok "" "$files" "$bytes"
}
