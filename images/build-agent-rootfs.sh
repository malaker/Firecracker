#!/usr/bin/env bash
# Build the agent image: the base image plus pinned Node.js, the agent CLIs and the gateway shim
# (change: in-sandbox-agents, design D4).
# Usage (as root): build-agent-rootfs.sh <base.ext4> <node.tar.gz> <agent-dir> <output.ext4> <size>
#   agent-dir holds package.json and the committed package-lock.json.
# Packages are installed with 'npm ci --ignore-scripts', so no package code runs on this host.
set -euo pipefail

BASE="$1" NODE_TGZ="$2" AGENT_DIR="$3" OUT="$4" SIZE="$5"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /var/tmp/fc-agent-rootfs.XXXXXX)"
MNT="$WORK/mnt"
cleanup() {
  mountpoint -q "$MNT" && umount "$MNT"
  rm -rf "${WORK:?}"
}
trap cleanup EXIT

# 1. A larger copy of the base image.
cp --sparse=always "$BASE" "$WORK/img"
chmod 0644 "$WORK/img"
truncate -s "$SIZE" "$WORK/img"
e2fsck -fy "$WORK/img" >/dev/null 2>&1 || true
resize2fs -f "$WORK/img" >/dev/null

# 2. Node.js, for npm here and for the Codex launcher in the guest.
mkdir -p "$WORK/node" "$MNT"
tar -xzf "$NODE_TGZ" -C "$WORK/node" --strip-components=1

# 3. Agent CLIs from the lockfile, integrity-checked, without install scripts.
mkdir -p "$WORK/agent"
cp "$AGENT_DIR/package.json" "$AGENT_DIR/package-lock.json" "$WORK/agent/"
( cd "$WORK/agent" && \
  PATH="$WORK/node/bin:$PATH" HOME="$WORK/home" npm_config_cache="$WORK/npm-cache" \
  npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false \
  npm_config_fetch_retries=5 npm_config_fetch_timeout=600000 \
  npm ci --ignore-scripts --omit=dev --loglevel=error )
# npm skips a failed optional download silently, and the native binaries are optional packages.
CLAUDE_BIN=node_modules/@anthropic-ai/claude-code-linux-x64/claude
CODEX_BIN=node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex
for b in "$CLAUDE_BIN" "$CODEX_BIN"; do
  [ -x "$WORK/agent/$b" ] || { echo "build-agent-rootfs: $b is missing after npm ci" >&2; exit 1; }
done

# 4. Install into the image.
mount -o loop "$WORK/img" "$MNT"
mkdir -p "$MNT/opt" "$MNT/usr/local/bin"
rm -rf "$MNT/opt/node" "$MNT/opt/agent"
cp -a "$WORK/node" "$MNT/opt/node"
cp -a "$WORK/agent" "$MNT/opt/agent"
ln -sf /opt/node/bin/node "$MNT/usr/local/bin/node"
# What Claude Code's install script would do: run the native binary directly.
ln -sf "/opt/agent/$CLAUDE_BIN" "$MNT/usr/local/bin/claude"
cat > "$MNT/usr/local/bin/codex" <<'EOF'
#!/bin/sh
exec /opt/node/bin/node /opt/agent/node_modules/@openai/codex/bin/codex.js "$@"
EOF
chmod 0755 "$MNT/usr/local/bin/codex"
install -m 0755 "$HERE/agent/fc-agent" "$MNT/usr/local/bin/fc-agent"

# 5. The guest end of the gateway channel: 127.0.0.1:8080 -> vsock CID 2 (host) port 8080.
cat > "$MNT/etc/systemd/system/fc-llm-shim.service" <<'EOF'
[Unit]
Description=Relay 127.0.0.1:8080 to the fc-sandbox LLM gateway over vsock
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:8080,bind=127.0.0.1,fork,reuseaddr VSOCK-CONNECT:2:8080
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/fc-llm-shim.service "$MNT/etc/systemd/system/multi-user.target.wants/fc-llm-shim.service"
echo fc-agent > "$MNT/etc/hostname"

umount "$MNT"
e2fsck -fy "$WORK/img" >/dev/null 2>&1 || true
chmod 0444 "$WORK/img"
# Only now replace the previous image: a failed build above keeps it.
mv -f "$WORK/img" "$OUT"
