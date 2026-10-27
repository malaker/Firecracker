# Shared paths, constants and helpers for fcctl. Sourced, not executed.

FC_HOME="${FC_HOME:-/opt/fc-sandbox}"
FC_STATE="/var/lib/fc-sandbox"
FC_VMS="$FC_STATE/vms"
FC_LOCK="$FC_STATE/lock"
FC_JAIL_BASE="/srv/jailer"
FC_CGROUP_PARENT="firecracker"
FC_RESULTS_DEFAULT="$FC_STATE/results"
FC_SSH_KEY="$FC_STATE/ssh/id_ed25519"
FC_KERNEL="$FC_HOME/images/vmlinux"
FC_ROOTFS="$FC_HOME/images/rootfs.ext4"

FC_UID_BASE=64000
FC_MAX_SLOTS=16384
FC_NET_CIDR="172.30.0.0/16"
FC_GUEST_DNS="1.1.1.1 8.8.8.8"

DEFAULT_VCPU=2
DEFAULT_MEM_MIB=1024
DEFAULT_TIMEOUT=1800
# Extra time the watchdog gives a `run` to collect results after the command timeout.
COLLECT_GRACE=30

EXIT_TIMEOUT=124
EXIT_INFRA=125

# shellcheck source=/dev/null
[ -f "$FC_HOME/versions.env" ] && . "$FC_HOME/versions.env"

log() { printf '[fcctl] %s\n' "$*" >&2; }
die() { log "error: $1"; exit "${2:-$EXIT_INFRA}"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (the fc.ps1 wrapper does this)"; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Parse 90, 90s, 30m, 1h into seconds.
parse_duration() {
  local v="$1"
  case "$v" in
    *[!0-9smh]* | "" ) return 1 ;;
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *)  echo "$v" ;;
  esac
}
