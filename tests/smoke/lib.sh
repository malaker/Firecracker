# Helpers for smoke tests. Run inside fc-host as root, after `fc.ps1 setup`.
set -uo pipefail

FCCTL="${FCCTL:-/opt/fc-sandbox/bin/fcctl}"
FC_BASE_IMAGE=/opt/fc-sandbox/images/rootfs.ext4
FC_SMOKE_HOST_TOOLS="jq ip nft pgrep socat sha256sum timeout awk"

# Refuses to run anywhere the checks cannot actually test something. Negative checks
# ("guest cannot reach X", "no leftovers") pass trivially when there is no VM or tool,
# so a wrong environment must produce no results at all, not a mix of ok and FAIL.
smoke_preflight() {
  local missing=()
  if [ "$(uname -s 2>/dev/null)" != Linux ]; then
    missing+=("Linux (this is $(uname -s 2>/dev/null || echo 'not Linux'))")
  else
    [ "$(id -u)" = 0 ] || missing+=("root (run with 'wsl ... -u root')")
    [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] || missing+=("read/write /dev/kvm")
    [ -x "$FCCTL" ] || missing+=("controller $FCCTL")
    [ -f "$FC_BASE_IMAGE" ] || missing+=("base image $FC_BASE_IMAGE")
    local t
    for t in $FC_SMOKE_HOST_TOOLS; do
      command -v "$t" >/dev/null 2>&1 || missing+=("host tool '$t'")
    done
  fi
  (( ${#missing[@]} )) || return 0
  {
    echo "smoke tests cannot run here; missing:"
    printf '  - %s\n' "${missing[@]}"
    echo "Run them inside the provisioned fc-host distro as root, from PowerShell:"
    echo "  wsl -d fc-host -u root -e bash /mnt/c/sources/Firecracker/tests/smoke/all.sh"
    echo "If fc-host or the controller is missing, run '.\\fc.ps1 setup' first."
  } >&2
  exit 125
}
smoke_preflight

RESULTS="$(mktemp -d /tmp/fc-smoke.XXXXXX)"
FAILS=0

pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAILS=$(( FAILS + 1 )); }

# expect <description> <command...>: passes when the command succeeds.
expect() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

not() { ! "$@"; }

# start_vm [fcctl start options...] -> prints run id
start_vm() { "$FCCTL" start "$@" 2>/dev/null; }

gssh() { local id="$1"; shift; "$FCCTL" ssh "$id" "$@"; }

# vm_pid <id>
vm_pid() { jq -r .pid "/var/lib/fc-sandbox/vms/$1/meta.json"; }

no_leftovers() {
  ! pgrep -x firecracker >/dev/null \
    && [ -z "$(ls -A /srv/jailer/firecracker 2>/dev/null)" ] \
    && ! ip -o link show | grep -q 'fc-tap-' \
    && ! nft list table inet fc_sandbox 2>/dev/null | grep -q 'chain vm-' \
    && [ -z "$(ls -A /var/lib/fc-sandbox/vms 2>/dev/null)" ]
}

finish() {
  rm -rf "$RESULTS"
  if (( FAILS )); then echo "$(basename "$0"): $FAILS check(s) failed"; exit 1; fi
  echo "$(basename "$0"): all checks passed"
}
