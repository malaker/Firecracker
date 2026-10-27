# Helpers for smoke tests. Run inside fc-host as root, after `fc.ps1 setup`.
set -uo pipefail

FCCTL="${FCCTL:-/opt/fc-sandbox/bin/fcctl}"
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
