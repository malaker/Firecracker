# MicroVM lifecycle: jailed start, watchdog, destroy (design D5, D8, D9).

jail_dir() { echo "$FC_JAIL_BASE/firecracker/$1"; }

validate_resources() {
  local vcpu="$1" mem="$2" avail_mib
  [[ "$vcpu" =~ ^[0-9]+$ ]] && (( vcpu >= 1 && vcpu <= 32 )) \
    || die "vCPU count must be between 1 and 32 (got '$vcpu')"
  (( vcpu <= $(nproc) )) || die "vCPU count $vcpu exceeds the host's $(nproc) CPUs"
  [[ "$mem" =~ ^[0-9]+$ ]] && (( mem >= 128 )) || die "memory must be at least 128 MiB (got '$mem')"
  avail_mib=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 ))
  (( mem + 256 <= avail_mib )) \
    || die "requested ${mem} MiB but only ${avail_mib} MiB is free on the host (256 MiB is reserved for overhead)"
}

# vm_create <id> <slot> <vcpu> <mem-mib> <net-mode> <allow-csv> <lifetime-sec> <keep 0|1>
# Starts the VM and waits for SSH. On failure the caller should vm_destroy.
vm_create() {
  local id="$1" slot="$2" vcpu="$3" mem="$4" net="$5" allow="$6" lifetime="$7" keep="$8"
  local uid=$(( FC_UID_BASE + slot )) jail root dir netjson="" pid
  jail="$(jail_dir "$id")"; root="$jail/root"; dir="$(vm_dir "$id")"

  jq -n --arg id "$id" --argjson slot "$slot" --argjson vcpu "$vcpu" \
    --argjson mem "$mem" --arg net "$net" --arg allow "$allow" --argjson lifetime "$lifetime" \
    --argjson keep "$keep" --arg started "$(now_iso)" --arg fc "${FC_VERSION:-}" \
    '{id:$id, state:"starting", slot:$slot, vcpu:$vcpu, mem_mib:$mem, net:$net, allow:$allow,
      lifetime_sec:$lifetime, keep:($keep==1), started_at:$started, firecracker:$fc}' \
    > "$dir/meta.json"

  mkdir -p "$root"
  ln "$FC_KERNEL" "$root/vmlinux" 2>/dev/null || cp "$FC_KERNEL" "$root/vmlinux"
  cp --sparse=always --reflink=auto "$FC_ROOTFS" "$root/rootfs.ext4"
  chmod 0600 "$root/rootfs.ext4"
  chown "$uid:$uid" "$root/rootfs.ext4"

  if [ "$net" = networked ]; then
    net_up "$slot" "$uid" "$allow"
    netjson="$(jq -n --arg mac "$(slot_mac "$slot")" --arg tap "$(tap_name "$slot")" \
      '[{iface_id:"eth0", guest_mac:$mac, host_dev_name:$tap}]')"
  fi

  jq -n --argjson vcpu "$vcpu" --argjson mem "$mem" --argjson net "${netjson:-[]}" '{
    "boot-source": {kernel_image_path: "/vmlinux",
                    boot_args: "console=ttyS0 reboot=k panic=1 pci=off quiet"},
    drives: [{drive_id: "rootfs", path_on_host: "/rootfs.ext4",
              is_root_device: true, is_read_only: false}],
    "machine-config": {vcpu_count: $vcpu, mem_size_mib: $mem},
    "network-interfaces": $net,
    vsock: {guest_cid: 3, uds_path: "/v.sock"}
  }' > "$root/config.json"
  chown "$uid:$uid" "$root/config.json"

  # No --daemonize: the jailer execs firecracker, so $! is the VMM's pid.
  setsid "$FC_HOME/bin/jailer" --id "$id" \
    --exec-file "$FC_HOME/bin/firecracker" --uid "$uid" --gid "$uid" \
    --chroot-base-dir "$FC_JAIL_BASE" \
    --cgroup-version 2 --parent-cgroup "$FC_CGROUP_PARENT" \
    --cgroup "cpu.max=$(( vcpu * 100000 )) 100000" \
    --cgroup "memory.max=$(( (mem + 256) * 1024 * 1024 ))" \
    -- --api-sock /api.sock --config-file /config.json \
    </dev/null >"$dir/console.log" 2>&1 &
  pid=$!
  meta_set "$id" pid "$pid"

  start_watchdog "$id" "$lifetime"

  if ! wait_ssh "$id" 60; then
    log "VM $id did not become reachable; last console lines:"
    tail -n 20 "$dir/console.log" >&2 || true
    return 1
  fi
  if [ "$net" = networked ]; then
    net_configure_guest "$id" "$slot" </dev/null || return 1
  fi
  meta_set_str "$id" state running
}

# The watchdog is a detached process, so the VM is killed on time even if
# this controller dies (design D9).
start_watchdog() {
  local id="$1" secs="$2" wpid
  setsid bash -c "sleep $secs; exec '$FC_HOME/bin/fcctl' _expire '$id'" </dev/null >/dev/null 2>&1 &
  wpid=$!
  meta_set "$id" watchdog_pid "$wpid"
}

kill_pid() {
  local pid="$1" i
  [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -d "/proc/$pid" ] || return 0
    sleep 0.2
  done
  kill -KILL "$pid" 2>/dev/null || true
  sleep 0.2
}

# vm_destroy <id> [force-remove-disk 0|1]
# Kills the VMM and watchdog, removes network, cgroup and jail. With keep set
# (and not forced) the disk copy is moved to the state dir and the state is
# kept as "kept"; otherwise the state dir is removed too.
vm_destroy() {
  local id="$1" force="${2:-0}" dir slot keep wpid jail
  dir="$(vm_dir "$id")"; jail="$(jail_dir "$id")"
  [ -d "$dir" ] || [ -d "$jail" ] || return 0
  slot="$(cat "$dir/slot" 2>/dev/null || true)"
  keep="$(meta_get "$id" keep)"

  kill_pid "$(meta_get "$id" pid)"
  wpid="$(meta_get "$id" watchdog_pid)"
  # Don't kill ourselves when the watchdog is the one destroying the VM.
  if [ -n "$wpid" ] && [ "$wpid" != "$$" ]; then
    kill_pid "$wpid"
  fi

  [ -n "$slot" ] && net_down "$slot"
  rmdir "/sys/fs/cgroup/$FC_CGROUP_PARENT/$id" 2>/dev/null || true

  if [ "$keep" = true ] && [ "$force" != 1 ] && [ -f "$jail/root/rootfs.ext4" ]; then
    mv "$jail/root/rootfs.ext4" "$dir/rootfs.ext4"
    rm -rf "$jail"
    meta_set_str "$id" state kept
    meta_set_str "$id" ended_at "$(now_iso)"
    rm -f "$dir/slot"   # the slot (uid, tap, subnet) can be reused
    log "kept disk for $id at $dir/rootfs.ext4"
    return 0
  fi
  rm -rf "$jail" "$dir"
}
