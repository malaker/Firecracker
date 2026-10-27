# Preflight diagnostics (spec: kvm-host-setup / Preflight diagnostics).

DOCTOR_FAILED=0

check() {
  local name="$1" hint="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    printf '  [PASS] %s\n' "$name"
  else
    printf '  [FAIL] %s\n         hint: %s\n' "$name" "$hint"
    DOCTOR_FAILED=1
  fi
}

_kvm_rw()        { [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; }
_fc_version()    { "$FC_HOME/bin/firecracker" --version | grep -q "Firecracker ${FC_VERSION}"; }
_jailer_version(){ "$FC_HOME/bin/jailer" --version | grep -q "${FC_VERSION#v}"; }
_kernel_sum()    { echo "$KERNEL_SHA256  $FC_KERNEL" | sha256sum -c --status; }
_rootfs_ok()     { [ -f "$FC_ROOTFS" ] && [ -f "$FC_ROOTFS.stamp" ] && grep -q "$ROOTFS_SHA256" "$FC_ROOTFS.stamp"; }
_tun()           { [ -c /dev/net/tun ]; }
_nft()           { nft list tables; }
_cgroup2()       { grep -qw cpu /sys/fs/cgroup/cgroup.controllers && grep -qw memory /sys/fs/cgroup/cgroup.controllers; }
_ssh_key()       { [ -f "$FC_SSH_KEY" ] && [ -f "$FC_SSH_KEY.pub" ]; }
_tools()         { command -v jq && command -v socat && command -v ssh && command -v nft && command -v ip; }
_disk()          { mkdir -p "$FC_JAIL_BASE"; (( $(df -Pk "$FC_JAIL_BASE" | awk 'NR==2 {print $4}') >= 4 * 1024 * 1024 )); }
_mem()           { (( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) >= 1536 * 1024 )); }

_boot() {
  local id slot rc=0
  id="$(new_run_id)"
  slot="$(alloc_slot "$id")" || return 1
  vm_create "$id" "$slot" 1 256 isolated "" 120 0 && fc_ssh "$id" true || rc=1
  vm_destroy "$id" 1
  return $rc
}

doctor() {
  local boot="$1"
  echo "fc-sandbox preflight (Firecracker ${FC_VERSION:-unknown})"
  check "running as root"                 "run through fc.ps1, which uses 'wsl -u root'" test "$(id -u)" -eq 0
  check "/dev/kvm present and read/write" "enable nested virtualization: rerun 'fc.ps1 setup' (sets nestedVirtualization=true in .wslconfig, then 'wsl --shutdown')" _kvm_rw
  check "host tools installed"            "rerun 'fc.ps1 setup'" _tools
  check "firecracker ${FC_VERSION:-}"     "rerun 'fc.ps1 setup' to install the pinned release" _fc_version
  check "jailer ${FC_VERSION:-}"          "rerun 'fc.ps1 setup' to install the pinned release" _jailer_version
  check "guest kernel checksum"           "rerun 'fc.ps1 setup' to re-download the kernel" _kernel_sum
  check "base rootfs built from pinned image" "rerun 'fc.ps1 setup' to rebuild the base image" _rootfs_ok
  check "controller SSH key"              "rerun 'fc.ps1 setup'" _ssh_key
  check "/dev/net/tun (networked mode)"   "the WSL kernel lacks TUN support; networked mode needs a custom WSL kernel" _tun
  check "nftables usable (networked mode)" "the WSL kernel lacks nf_tables; networked mode needs a custom WSL kernel" _nft
  check "cgroup v2 cpu+memory controllers" "enable systemd/cgroup v2 in the fc-host distro (/etc/wsl.conf [boot] systemd=true), then 'wsl --shutdown'" _cgroup2
  check ">= 4 GiB free disk in $FC_JAIL_BASE" "free disk space inside the fc-host distro, or run 'fc.ps1 cleanup'" _disk
  check ">= 1.5 GiB free memory"          "stop other workloads or raise 'memory=' in .wslconfig" _mem
  if [ "$boot" = 1 ]; then
    if (( DOCTOR_FAILED )); then
      printf '  [SKIP] boot a test microVM (fix the failures above first)\n'
    else
      check "boot a test microVM and run a command over vsock SSH" "see 'fc.ps1 doctor' output above and the console log in $FC_VMS" _boot
    fi
  fi
  if (( DOCTOR_FAILED )); then
    echo "Some checks failed."
    return 1
  fi
  echo "All checks passed."
}
