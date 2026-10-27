#!/usr/bin/env bash
# Network modes, host protection, allowlist and teardown (spec: microvm-network-modes).
. "$(dirname "$0")/lib.sh"
echo "== network"

# Guest-side probe: succeeds only if a TCP connection opens within 4s.
probe() { gssh "$1" "timeout 4 bash -c '</dev/tcp/$2/$3'" 2>/dev/null; }

# --- isolated ---------------------------------------------------------------
id="$(start_vm --vcpu 1 --mem 256)"
expect "isolated: guest has only the loopback interface" \
  test "$(gssh "$id" "ip -o link | awk -F': ' '{print \$2}'")" = lo
expect "isolated: outbound connection fails" not probe "$id" "1.1.1.1" 443
"$FCCTL" stop "$id" 2>/dev/null

# --- networked --------------------------------------------------------------
host_ip="$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
gw="$(ip -4 route show default | awk '{print $3; exit}')"
socat TCP-LISTEN:8099,fork,reuseaddr SYSTEM:'echo hi' &
listener=$!

a="$(start_vm --vcpu 1 --mem 256 --net networked)"
b="$(start_vm --vcpu 1 --mem 256 --net networked)"
b_ip="$(gssh "$b" "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1")"
a_gw="$(gssh "$a" "ip route | awk '/default/ {print \$3}'")"
gssh "$b" "nohup socat TCP-LISTEN:8099,fork,reuseaddr SYSTEM:'echo hi' >/dev/null 2>&1 &"
sleep 1

expect "networked: guest reaches the internet (https://example.com)" \
  gssh "$a" "curl -fsS --max-time 10 -o /dev/null https://example.com"
expect "networked: guest cannot reach the WSL host ($host_ip:8099)" not probe "$a" "$host_ip" 8099
expect "networked: guest cannot reach its tap gateway ($a_gw:8099)" not probe "$a" "$a_gw" 8099
expect "networked: guest cannot reach the Windows host ($gw:445)" not probe "$a" "$gw" 445
expect "networked: guest cannot reach another VM ($b_ip:8099)" not probe "$a" "$b_ip" 8099
expect "networked: VM's own listener works (sanity)" gssh "$b" "timeout 4 bash -c '</dev/tcp/127.0.0.1/8099'"

slot_a="$(cat "/var/lib/fc-sandbox/vms/$a/slot")"
"$FCCTL" stop "$a" 2>/dev/null
"$FCCTL" stop "$b" 2>/dev/null
kill "$listener" 2>/dev/null
expect "teardown: tap device removed" bash -c "! ip link show fc-tap-$slot_a >/dev/null 2>&1"
expect "teardown: nft chain removed" bash -c "! nft list table inet fc_sandbox | grep -q 'chain vm-$slot_a '"

# --- allowlist --------------------------------------------------------------
id="$(start_vm --vcpu 1 --mem 256 --net networked --allow 1.1.1.1/32)"
expect "allowlist: allowed destination 1.1.1.1 is reachable" \
  gssh "$id" "curl -fsS --max-time 10 -o /dev/null https://1.1.1.1"
expect "allowlist: other destinations (example.com) are blocked" \
  gssh "$id" "! curl -fsS --max-time 8 -o /dev/null https://example.com"
expect "allowlist: 8.8.8.8 is blocked" not probe "$id" "8.8.8.8" 53
"$FCCTL" stop "$id" 2>/dev/null

expect "rejects --allow without networked mode" bash -c "! '$FCCTL' start --allow 1.1.1.1/32 2>/dev/null"
expect "no leftovers after network tests" no_leftovers

finish
