# Run state: one directory per VM under $FC_VMS/<run-id>/ holding meta.json.
# meta.json is the source of truth for list/stop/cleanup.

new_run_id() {
  printf '%s-%04x\n' "$(date +%Y%m%d-%H%M%S)" $(( RANDOM % 65536 ))
}

# Allocate the lowest free slot (drives uid, tap name and /30 subnet) and
# create the VM's state dir, atomically under a lock. Prints the slot.
alloc_slot() {
  local id="$1" slot used
  mkdir -p "$FC_VMS"
  exec 9>"$FC_LOCK"
  flock 9
  used=" $(cat "$FC_VMS"/*/slot 2>/dev/null | tr '\n' ' ') "
  for (( slot = 0; slot < FC_MAX_SLOTS; slot++ )); do
    case "$used" in *" $slot "*) continue ;; esac
    mkdir -p "$FC_VMS/$id"
    echo "$slot" > "$FC_VMS/$id/slot"
    echo '{}' > "$FC_VMS/$id/meta.json"
    flock -u 9
    echo "$slot"
    return 0
  done
  flock -u 9
  return 1
}

vm_dir() { echo "$FC_VMS/$1"; }

vm_exists() { [ -f "$FC_VMS/$1/meta.json" ]; }

# meta_set <id> <key> <json-value>
meta_set() {
  local f="$FC_VMS/$1/meta.json" tmp
  tmp="$(mktemp "$f.XXXX")"
  jq --arg k "$2" --argjson v "$3" '.[$k] = $v' "$f" > "$tmp" && mv "$tmp" "$f"
}

# meta_set_str <id> <key> <string>
meta_set_str() { meta_set "$1" "$2" "$(jq -Rn --arg s "$3" '$s')"; }

meta_get() { jq -r --arg k "$2" '.[$k] // empty' "$FC_VMS/$1/meta.json" 2>/dev/null; }

# True if the VM's firecracker process is alive.
vm_alive() {
  local pid
  pid="$(meta_get "$1" pid)"
  [ -n "$pid" ] && [ -d "/proc/$pid" ] && grep -q firecracker "/proc/$pid/cmdline" 2>/dev/null
}

list_vm_ids() {
  local d
  for d in "$FC_VMS"/*/; do
    [ -f "$d/meta.json" ] && basename "$d"
  done
  return 0
}
