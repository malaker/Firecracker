#!/usr/bin/env bash
# Build the read-only base ext4 image from Firecracker's CI Ubuntu squashfs.
# Usage (as root): build-rootfs.sh <squashfs> <ssh-pubkey> <output.ext4> <size>
set -euo pipefail

SQUASHFS="$1" PUBKEY="$2" OUT="$3" SIZE="$4"
WORK="$(mktemp -d /var/tmp/fc-rootfs.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"

unsquashfs -q -d "$ROOT" "$SQUASHFS" >/dev/null

# Controller key for root; the image ships openssh-server and socat.
install -d -m 0700 "$ROOT/root/.ssh"
install -m 0600 "$PUBKEY" "$ROOT/root/.ssh/authorized_keys"
rm -f "$ROOT"/etc/ssh/ssh_host_*
ssh-keygen -A -f "$ROOT" >/dev/null

# Make sure sshd starts at boot.
if [ -f "$ROOT/usr/lib/systemd/system/ssh.service" ]; then
  ln -sf /usr/lib/systemd/system/ssh.service "$ROOT/etc/systemd/system/multi-user.target.wants/ssh.service"
fi

# Relay vsock port 22 to the guest's sshd (design D6).
cat > "$ROOT/etc/systemd/system/fc-vsock-ssh.service" <<'EOF'
[Unit]
Description=Relay vsock port 22 to sshd for the fc-sandbox controller
After=network.target ssh.service

[Service]
ExecStart=/usr/bin/socat VSOCK-LISTEN:22,fork,reuseaddr TCP:127.0.0.1:22
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/fc-vsock-ssh.service \
  "$ROOT/etc/systemd/system/multi-user.target.wants/fc-vsock-ssh.service"

install -d -m 0755 "$ROOT/work" "$ROOT/work/in" "$ROOT/work/out"
echo fc-guest > "$ROOT/etc/hostname"

rm -f "$OUT.tmp"
mkfs.ext4 -q -F -d "$ROOT" "$OUT.tmp" "$SIZE"
chmod 0444 "$OUT.tmp"
mv -f "$OUT.tmp" "$OUT"
