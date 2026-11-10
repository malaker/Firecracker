#!/usr/bin/env bash
# Provision the fc-host WSL distro (run as root, idempotent).
# Usage: provision.sh <repo-dir> [airlock-build-dir] [gateway-build-dir] [--no-agent-image] [--ollama-url URL]
#   airlock-build-dir holds the linux-x64 fc-airlock published by airlock/install-airlock.ps1,
#   gateway-build-dir the linux-x64 fc-llm-gateway published by gateway/install-gateway.ps1.
set -euo pipefail

REPO="$(cd "$1" && pwd)"
AIRLOCK_BUILD="${2:-}"
GATEWAY_BUILD="${3:-}"
NO_AGENT_IMAGE=0 OLLAMA_URL=""
shift $(( $# < 3 ? $# : 3 ))
while (( $# )); do
  case "$1" in
    --no-agent-image) NO_AGENT_IMAGE=1 ;;
    --ollama-url) OLLAMA_URL="${2:-}"; shift ;;
    *) echo "provision.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done
FC_HOME=/opt/fc-sandbox
CACHE=/var/cache/fc-sandbox
STATE=/var/lib/fc-sandbox
CHANGED=0

# shellcheck source=/dev/null
. "$REPO/host/versions.env"

say()     { printf '[provision] %s\n' "$*"; }
changed() { CHANGED=1; say "$*"; }

# --- packages ---------------------------------------------------------------
PKGS=(ca-certificates curl jq nftables socat openssh-client e2fsprogs squashfs-tools iproute2)
missing=()
for p in "${PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
done
if (( ${#missing[@]} )); then
  changed "installing packages: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
fi

mkdir -p "$FC_HOME/bin" "$FC_HOME/lib" "$FC_HOME/images" "$CACHE" "$STATE/vms" "$STATE/ssh" /srv/jailer

# --- verified downloads -----------------------------------------------------
# fetch <url> <sha256> -> prints the cached path; never re-downloads a good file.
fetch() {
  local url="$1" sum="$2" dest="$CACHE/$(basename "$1")"
  if [ -f "$dest" ] && echo "$sum  $dest" | sha256sum -c --status; then
    echo "$dest"; return 0
  fi
  changed "downloading $url" >&2
  curl -fsSL --retry 3 -o "$dest.part" "$url"
  if ! echo "$sum  $dest.part" | sha256sum -c --status; then
    rm -f "$dest.part"
    say "checksum mismatch for $(basename "$url") (expected $sum)" >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
  echo "$dest"
}

# --- firecracker + jailer ---------------------------------------------------
if ! "$FC_HOME/bin/firecracker" --version 2>/dev/null | grep -q "Firecracker $FC_VERSION"; then
  tgz="$(fetch "$FC_URL" "$FC_SHA256")"
  tmp="$(mktemp -d)"
  tar -xzf "$tgz" -C "$tmp"
  rel="$tmp/release-$FC_VERSION-x86_64"
  install -m 0755 "$rel/firecracker-$FC_VERSION-x86_64" "$FC_HOME/bin/firecracker"
  install -m 0755 "$rel/jailer-$FC_VERSION-x86_64" "$FC_HOME/bin/jailer"
  rm -rf "$tmp"
  changed "installed firecracker and jailer $FC_VERSION"
fi

# --- guest kernel -----------------------------------------------------------
if ! echo "$KERNEL_SHA256  $FC_HOME/images/vmlinux" | sha256sum -c --status 2>/dev/null; then
  install -m 0644 "$(fetch "$KERNEL_URL" "$KERNEL_SHA256")" "$FC_HOME/images/vmlinux"
  changed "installed guest kernel $KERNEL_VERSION"
fi

# --- controller SSH key -----------------------------------------------------
if [ ! -f "$STATE/ssh/id_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N '' -C fc-sandbox -f "$STATE/ssh/id_ed25519"
  changed "generated controller SSH key"
fi

# --- base rootfs ------------------------------------------------------------
# The stamp ties the image to the pinned squashfs, the key and the build script.
stamp="$ROOTFS_SHA256 $(sha256sum < "$STATE/ssh/id_ed25519.pub" | cut -c1-16) $(sha256sum < "$REPO/images/build-rootfs.sh" | cut -c1-16) $ROOTFS_SIZE"
if [ ! -f "$FC_HOME/images/rootfs.ext4" ] || [ "$(cat "$FC_HOME/images/rootfs.ext4.stamp" 2>/dev/null)" != "$stamp" ]; then
  sq="$(fetch "$ROOTFS_URL" "$ROOTFS_SHA256")"
  bash "$REPO/images/build-rootfs.sh" "$sq" "$STATE/ssh/id_ed25519.pub" "$FC_HOME/images/rootfs.ext4" "$ROOTFS_SIZE"
  echo "$stamp" > "$FC_HOME/images/rootfs.ext4.stamp"
  changed "built base rootfs from $ROOTFS_NAME"
fi

# --- agent image (in-sandbox-agents) ----------------------------------------
# Rebuilt when the base image, Node.js, the agent lockfile, the build script, the guest wrapper or
# the size changes. A failed build (bad checksum, missing package) keeps the previous image.
if (( NO_AGENT_IMAGE )); then
  say "skipping the agent image (--no-agent-image); -Agent runs are unavailable"
else
  agent_stamp="$(cat "$FC_HOME/images/rootfs.ext4.stamp") $NODE_SHA256"
  for f in images/agent/package-lock.json images/build-agent-rootfs.sh images/agent/fc-agent; do
    agent_stamp+=" $(sha256sum < "$REPO/$f" | cut -c1-16)"
  done
  agent_stamp+=" $AGENT_ROOTFS_SIZE"
  if [ ! -f "$FC_HOME/images/agent-rootfs.ext4" ] || [ "$(cat "$FC_HOME/images/agent-rootfs.ext4.stamp" 2>/dev/null)" != "$agent_stamp" ]; then
    node="$(fetch "$NODE_URL" "$NODE_SHA256")"
    changed "building the agent image (Node.js $NODE_VERSION + agent clients; downloads several hundred MB)"
    bash "$REPO/images/build-agent-rootfs.sh" "$FC_HOME/images/rootfs.ext4" "$node" "$REPO/images/agent" \
      "$FC_HOME/images/agent-rootfs.ext4" "$AGENT_ROOTFS_SIZE"
    echo "$agent_stamp" > "$FC_HOME/images/agent-rootfs.ext4.stamp"
    changed "built agent image"
  fi
fi

# --- controller -------------------------------------------------------------
sync_file() {
  local src="$1" dst="$2" mode="$3"
  if ! cmp -s "$src" "$dst"; then
    install -m "$mode" "$src" "$dst"
    changed "updated $dst"
  fi
}
sync_file "$REPO/host/versions.env" "$FC_HOME/versions.env" 0644
for f in "$REPO"/host/lib/*.sh; do sync_file "$f" "$FC_HOME/lib/$(basename "$f")" 0644; done
for f in "$REPO"/host/bin/*; do sync_file "$f" "$FC_HOME/bin/$(basename "$f")" 0755; done
# Guest output airlock tool (spec: kvm-host-setup / Airlock tooling for Linux guests).
if [ -n "$AIRLOCK_BUILD" ]; then
  [ -f "$AIRLOCK_BUILD/fc-airlock" ] || { say "error: $AIRLOCK_BUILD/fc-airlock not found"; exit 1; }
  sync_file "$AIRLOCK_BUILD/fc-airlock" "$FC_HOME/bin/fc-airlock" 0755
else
  say "warning: no airlock build given; run 'fc.ps1 setup' to install fc-airlock"
fi
mkdir -p "$STATE/staging"
chmod 0711 "$STATE/staging"

# LLM gateway and agent profiles (spec: kvm-host-setup / Agent image and gateway build).
mkdir -p "$FC_HOME/agents"
sync_file "$REPO/host/agents/profiles.json" "$FC_HOME/agents/profiles.json" 0644
if [ -n "$GATEWAY_BUILD" ]; then
  [ -f "$GATEWAY_BUILD/fc-llm-gateway" ] || { say "error: $GATEWAY_BUILD/fc-llm-gateway not found"; exit 1; }
  sync_file "$GATEWAY_BUILD/fc-llm-gateway" "$FC_HOME/bin/fc-llm-gateway" 0755
else
  say "warning: no gateway build given; run 'fc.ps1 setup' to install fc-llm-gateway"
fi
if [ -n "$OLLAMA_URL" ]; then
  { printf 'FC_OLLAMA_URL=%q' "$OLLAMA_URL"; echo; } > "$FC_HOME/agents/local.env.tmp"
  if ! cmp -s "$FC_HOME/agents/local.env.tmp" "$FC_HOME/agents/local.env"; then
    mv "$FC_HOME/agents/local.env.tmp" "$FC_HOME/agents/local.env"; changed "set the Ollama URL to $OLLAMA_URL"
  else
    rm -f "$FC_HOME/agents/local.env.tmp"
  fi
fi
# Stashed provider keys and per-VM gateway sockets (design D2/D5).
install -d -m 0700 "$STATE/keys"
install -d -m 0711 "$STATE/gw"

# --- host settings ----------------------------------------------------------
if [ ! -f /etc/sysctl.d/90-fc-sandbox.conf ]; then
  echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/90-fc-sandbox.conf
  changed "enabled IPv4 forwarding"
fi
sysctl -qw net.ipv4.ip_forward=1
# Keep /dev/kvm group-accessible after every WSL boot (fcctl itself runs as root).
KVM_BOOT_CMD='command = "chgrp kvm /dev/kvm; chmod 0660 /dev/kvm"'
touch /etc/wsl.conf
if ! grep -q '^# fc-sandbox' /etc/wsl.conf; then
  if grep -qE '^\s*command\s*=' /etc/wsl.conf; then
    say "warning: /etc/wsl.conf already has a [boot] command; not adding the /dev/kvm permission command"
  elif grep -q '^\[boot\]' /etc/wsl.conf; then
    awk -v cmd="$KVM_BOOT_CMD" '{print} /^\[boot\]/ {print "# fc-sandbox"; print cmd}' /etc/wsl.conf > /etc/wsl.conf.tmp
    mv /etc/wsl.conf.tmp /etc/wsl.conf
    changed "added /dev/kvm permissions to /etc/wsl.conf"
  else
    printf '\n[boot]\n# fc-sandbox\n%s\n' "$KVM_BOOT_CMD" >> /etc/wsl.conf
    changed "added /dev/kvm permissions to /etc/wsl.conf"
  fi
fi
getent group kvm >/dev/null || groupadd -r kvm
[ -c /dev/kvm ] && { chgrp kvm /dev/kvm; chmod 0660 /dev/kvm; }

# Base nftables table (fcctl recreates it after WSL restarts).
FC_HOME="$FC_HOME" bash -c '. "$FC_HOME/lib/common.sh"; . "$FC_HOME/lib/net.sh"; net_init' \
  || say "warning: could not create the nftables table (networked mode unavailable)"

if (( CHANGED )); then
  say "provisioning complete"
else
  say "all components are up to date"
fi
