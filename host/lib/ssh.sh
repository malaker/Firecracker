# Control channel: SSH to the guest over Firecracker's vsock (design D6).
# Host keys are not checked: the channel is a local Unix socket owned by root
# and every guest is freshly booted from the same base image.

vsock_path() { echo "$FC_JAIL_BASE/firecracker/$1/root/v.sock"; }

# fc_ssh <id> [-t] [remote command...]   (-t: interactive, allocate a tty)
fc_ssh() {
  local id="$1" tty=-T; shift
  if [ "${1:-}" = -t ]; then tty=-t; shift; fi
  ssh -F /dev/null -i "$FC_SSH_KEY" "$tty" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
    -o ProxyCommand="$FC_HOME/bin/fc-vsock-proxy $(vsock_path "$id") 22" \
    root@fc-guest "$@"
}

# Wait until SSH answers in the guest; returns non-zero after $2 seconds.
wait_ssh() {
  local id="$1" limit="${2:-60}" start=$SECONDS
  while (( SECONDS - start < limit )); do
    vm_alive "$id" || return 1
    if [ -S "$(vsock_path "$id")" ] && fc_ssh "$id" true </dev/null 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# upload_dir <id> <local-dir> <guest-dir>
upload_dir() {
  tar -C "$2" -cf - . | fc_ssh "$1" "mkdir -p '$3' && tar -C '$3' -xf -"
}

# download_dir <id> <guest-dir> <local-dir>
download_dir() {
  mkdir -p "$3"
  fc_ssh "$1" "[ -d '$2' ] && tar -C '$2' -cf - . || true" | tar -C "$3" -xf - 2>/dev/null || true
}
