# Networked mode (design D7): one tap + /30 per VM, nftables table
# `inet fc_sandbox` with a per-VM chain selected through the vm_fwd verdict map.
# Isolated mode never calls into this file.

FC_NFT_TABLE="inet fc_sandbox"
FC_TAP_PREFIX="fc-tap-"

# Idempotent: (re)create the base table. WSL restarts wipe nftables state,
# so this runs before every networked VM, not only at provisioning.
net_init() {
  sysctl -qw net.ipv4.ip_forward=1
  nft list table $FC_NFT_TABLE >/dev/null 2>&1 && return 0
  nft -f - <<EOF
table $FC_NFT_TABLE {
  map vm_fwd { type ifname : verdict; }

  # Guests may never talk to the WSL host itself.
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "${FC_TAP_PREFIX}*" drop
  }

  chain forward {
    type filter hook forward priority -10; policy accept;
    oifname "${FC_TAP_PREFIX}*" ct state established,related accept
    oifname "${FC_TAP_PREFIX}*" drop
    iifname "${FC_TAP_PREFIX}*" iifname vmap @vm_fwd
    iifname "${FC_TAP_PREFIX}*" drop
  }

  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    ip saddr $FC_NET_CIDR oifname != "${FC_TAP_PREFIX}*" masquerade
  }
}
EOF
}

tap_name() { echo "${FC_TAP_PREFIX}$1"; }

# slot -> "<host-ip> <guest-ip>" inside 172.30.0.0/16, one /30 per slot.
slot_ips() {
  local base=$(( $1 * 4 ))
  local o3=$(( base / 256 )) o4=$(( base % 256 ))
  echo "172.30.$o3.$(( o4 + 1 )) 172.30.$o3.$(( o4 + 2 ))"
}

slot_mac() {
  local base=$(( $1 * 4 + 2 ))
  printf '06:00:ac:1e:%02x:%02x\n' $(( base / 256 )) $(( base % 256 ))
}

# net_up <slot> <uid> <allow-csv>
net_up() {
  local slot="$1" uid="$2" allow="$3" tap host guest gw chain cidr rules
  tap="$(tap_name "$slot")"
  read -r host guest < <(slot_ips "$slot")
  gw="$(ip -4 route show default | awk '{print $3; exit}')"
  chain="vm-$slot"

  net_init
  ip tuntap add dev "$tap" mode tap user "$uid" group "$uid"
  ip addr add "$host/30" dev "$tap"
  ip link set "$tap" up

  rules=("meta nfproto ipv6 drop")
  if [ -n "$allow" ]; then
    for cidr in ${allow//,/ }; do
      rules+=("ip daddr $cidr accept")
    done
    rules+=("drop")
  else
    rules+=("ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 127.0.0.0/8, 224.0.0.0/4, 240.0.0.0/4${gw:+, $gw} } drop")
    rules+=("accept")
  fi
  {
    echo "add chain $FC_NFT_TABLE $chain"
    echo "flush chain $FC_NFT_TABLE $chain"
    printf "add rule $FC_NFT_TABLE $chain %s\n" "${rules[@]}"
    echo "add element $FC_NFT_TABLE vm_fwd { \"$tap\" : jump $chain }"
  } | nft -f -
}

# Configure the guest side over SSH once it is up.
net_configure_guest() {
  local id="$1" slot="$2" host guest ns resolv=""
  read -r host guest < <(slot_ips "$slot")
  for ns in $FC_GUEST_DNS; do resolv+="nameserver $ns\n"; done
  # `replace`: the CI image's own boot script may already have derived the
  # same address from the MAC.
  fc_ssh "$id" "ip addr replace $guest/30 dev eth0 && ip link set eth0 up && ip route replace default via $host \
    && rm -f /etc/resolv.conf && printf '$resolv' > /etc/resolv.conf"
}

# net_down <slot>: safe to call repeatedly and for slots that never had a network.
net_down() {
  local slot="$1" tap
  tap="$(tap_name "$slot")"
  nft delete element $FC_NFT_TABLE vm_fwd "{ \"$tap\" }" 2>/dev/null || true
  nft delete chain $FC_NFT_TABLE "vm-$slot" 2>/dev/null || true
  ip link del "$tap" 2>/dev/null || true
}
