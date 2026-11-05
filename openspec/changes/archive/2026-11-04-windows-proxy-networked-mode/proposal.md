# Proposal

## Why

Windows `networked` mode relies on HNS endpoint ACLs and Windows Firewall rules. Windows 11 accepts the ACLs but never enforces them. On 2026-11-04, a guest on the `fc-win-nat` network reached the LAN router (`192.168.51.1`, HTTP 200), public addresses outside `-Allow`, and these host ports, through both `172.31.0.1` and the host's Wi-Fi IP:

| Port | Service |
|---|---|
| 2179 | `vmms` |
| 7680 | Delivery Optimization |
| 27036 | Steam |
| 49679, 57100 | GlideX |

A host firewall rule blocking inbound traffic from `172.31.0.0/16` stopped only the traffic addressed to `172.31.0.1`. Networked mode currently refuses to start on such hosts, so Windows guests have no usable network. We need an enforcement point that works on Windows 11 and blocks everything by default.

## What Changes

- **BREAKING**: Windows `networked` guests no longer get a network adapter. They start with `--network none`, exactly like `isolated` guests. Egress becomes **proxy-only**: a relay inside the guest listens on `127.0.0.1` and tunnels TCP streams over the existing exec channel (HVSocket) to a host-side egress proxy.
- **BREAKING**: on Windows, only TCP through an HTTP proxy works (`HTTP_PROXY`/`HTTPS_PROXY`, HTTP `CONNECT`). ICMP, raw UDP and programs that ignore proxy settings get no network. Name resolution happens on the host.
- A new host-side egress proxy:
  - **Privileges**: runs as a separate process with a restricted, non-admin token.
  - **Allowlist**: resolves names and checks every resolved address against the `-Allow` allowlist.
  - **Always blocked**: the host's own addresses, private, link-local, CGNAT, loopback and multicast ranges, and IPv6.
  - **Logging**: records every allowed or denied connection in `runs\<run-id>\net.log`.
- The relay protocol is deliberately trivial: fixed-size headers, bounded frame and stream counts, and idle and lifetime timeouts.
- **Removed**:
  - The `fc-win-nat` HNS NAT network and the HNS endpoint ACL code (`computenetwork.dll` P/Invoke).
  - The per-VM Windows Firewall rules.
  - The fail-closed reachability probe added on 2026-11-04 (with no adapter in the guest, nothing is left to probe).
- The Windows smoke tests probe the host's real addresses and its listening ports through the proxy, with positive controls, instead of fixed addresses that may not exist on the test network.
- Linux networked mode (tap + nftables) is unchanged.

## Capabilities

### New Capabilities
- `windows-egress-proxy`: the host-side egress proxy and in-guest relay used by Windows `networked` microVMs. Covers the relay channel, proxy privileges, destination policy (allowlist and always-blocked ranges), resource limits and the per-run connection log.

### Modified Capabilities
- `microvm-network-modes`:
  - `networked` mode no longer means "private address with NAT" for Windows guests; it means proxied TCP egress.
  - The host-protection scenarios for Windows move from HNS and firewall rules to proxy enforcement.
  - The "host does not enforce the network policy" scenario is removed.
  - Allowlist matching on Windows applies to resolved destination addresses.
  - Teardown now covers the proxy and relay instead of HNS endpoints and firewall rules.

## Impact

- **Code**:
  - `windows/lib/net.ps1`: the HNS, ACL and firewall code is removed; proxy lifecycle code is added.
  - `windows/lib/runtime.ps1`: `Start-FcWinMicroVm` uses `--network none` for both modes; the relay starts over `docker exec -i`.
  - `windows/fcctl-win.ps1`: start and teardown, `cleanup`, and `meta.json` (`guest_ip` replaced by proxy details).
  - `windows/lib/common.ps1`: the `HNS_*` and `GUEST_DNS` constants are removed.
  - `windows/lib/doctor.ps1`: the `computenetwork.dll` check becomes a check that the proxy and relay binaries are present.
- **New code**: a C#/.NET 10 host proxy and guest relay under `windows/egress/`, built during setup with the installed .NET SDK. The relay is a single-file `win-x64` executable that runs on every Nano Server flavour, including the .NET Framework ones.
- **Setup**: `windows/setup-nanoserver.ps1` builds or verifies the proxy and relay binaries. No HNS NAT network is created any more.
- **Tests**: `tests/smoke-win/net-protect.ps1` is rewritten. `lifecycle.ps1` and `all.ps1` are adjusted where they assume a NAT adapter.
- **Docs**: the README network-modes section and its Windows warning, and the threat-model notes about which control enforces isolation.
- **Unchanged**: the Linux guests, the isolated mode, the Nano Server images and the `C:\sources\nanoserver` repo.
