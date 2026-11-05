# Design

## Context

See proposal.md (Why) for the motivation. Here is the current state that shapes the approach:

- **Exec channel:** every Windows microVM is a Hyper-V isolated container. The controller already moves binary data in both directions over `docker exec -i` stdin/stdout: payload upload, result collection and command output, all through `FcProc` in `windows/lib/runtime.ps1`. `docker exec` is carried by the HCS guest-compute channel over HVSocket. It works with `--network none`, which is how `isolated` mode runs today.
- **Privilege:** the Docker engine pipe requires an elevated client; a non-elevated `docker version` was refused on 2026-11-04. `vmcompute` and `dockerd` run as SYSTEM, and `vmwp`/`vmmem` run under per-VM `NT VIRTUAL MACHINE\<GUID>` accounts (checked on the dev host). The controller runs elevated.
- **Lifecycle:** `fc start` returns while the VM keeps running. A detached watchdog later calls `_expire`, which runs the normal teardown (`Remove-FcWinVmInstance`). Anything this change adds must outlive the controller process and be torn down by that same path.
- **Guest runtimes:** `aspnet-*` flavours ship .NET 10, and `iis-netfx-*` flavours ship .NET Framework 4.8.1. All guests run an x64 Nano Server OS. The dev host has the .NET 10 SDK (10.0.303, 10.0.402).
- **Overlap with the in-progress change:** `nanoserver-windows-microvm` still has open tasks that assume the HNS NAT design. This change supersedes those network parts.

## Goals / Non-Goals

**Goals:**
- No guest network adapter in any mode, so the guest's only network path is one we control.
- Host-side code that reads guest-controlled data parses only fixed-size binary headers and a length-bounded host name, and runs without admin rights.
- The proxy dies with the VM, through every teardown path: stop, cleanup, watchdog, controller crash.

**Non-Goals:**
- UDP, ICMP, raw sockets, or programs that ignore proxy settings.
- Inspecting or filtering traffic inside TLS (no MITM).
- Changing Linux networked mode.
- Supporting the old HNS NAT mode as a fallback, even on hosts that might enforce ACLs.

## Decisions

### D1. Transport: one long-lived `docker exec -i` per VM, multiplexed
The relay (`fc-relay.exe`) runs inside the guest under one `docker exec -i` session. All TCP streams share its stdin/stdout as framed, multiplexed traffic.

*Alternatives:*
- **One `docker exec` per connection:** much simpler framing, but it costs about 0.5–1 s and a new host process per connection.
- **A custom HVSocket service GUID:** needs host registry registration under `GuestCommunicationServices`, and AF_HYPERV access from inside a container. That's more new attack surface and less documented.
- **An internal-only network adapter to a proxy container:** brings back a guest adapter, which is exactly what we're removing.

### D2. The guest parses HTTP, the host parses only binary frames
The relay listens on `127.0.0.1:3128` inside the guest. It parses the HTTP proxy request (`CONNECT host:port`, or an absolute-URI request that it rewrites to origin form) and sends the host one `OPEN(host, port)` frame. Everything after that is opaque `DATA`.

The host never parses HTTP. A compromised relay can only send malformed frames, which D4 bounds.

*Alternative:* a dumb relay with HTTP parsing on the host. That's simpler in the guest, but it puts a text parser into host code fed by untrusted bytes.

**Frame format** (little-endian):

| Field | Size |
|---|---|
| `type` | u8 |
| `stream` | u32 |
| `length` | u32 |
| payload | `length` bytes |

**Types:**

| Type | Payload |
|---|---|
| `OPEN` | u16 port, then u8 name-length (1–253), then an ASCII host name or dotted IPv4 |
| `OPEN_OK` | none |
| `OPEN_FAIL` | u8 reason |
| `DATA` | stream bytes |
| `WINDOW` | u32 credit |
| `CLOSE` | none |

Unknown types, `length` above 64 KiB, `OPEN` on an existing stream, or a stream ID above the limit are protocol errors: the host closes the channel. Each stream has a 256 KiB credit window (`WINDOW` frames), so one stalled stream can't grow memory or block the others.

### D3. An elevated launcher hands pipes to an unprivileged proxy
`fc-egress.exe` has two modes:

- **`launch` (run elevated by the controller):**
  1. Creates two anonymous pipe pairs.
  2. Starts `docker exec -i -u ContainerAdministrator <container> C:\fc\fc-relay.exe` with its stdin/stdout on one end of each pipe.
  3. Starts itself in `serve` mode with the other ends inherited, using a restricted token: `SaferComputeTokenFromLevel(SAFER_LEVELID_NORMALUSER)`, integrity lowered to Medium, and a job object that forbids child processes and caps memory.
  4. Writes both PIDs to the VM's `meta.json`, closes its own handles, and exits.
- **`serve` (unprivileged):** enforces the policy, connects outbound, and writes `net.log`.

Neither child depends on the controller, so `fc start` can return. When the container stops, `docker exec` ends, the pipe closes, and `serve` exits on EOF. Teardown also kills both processes by PID after checking the process name, so the watchdog and `cleanup` paths don't rely on EOF alone.

*Alternatives:*
- **Keep the proxy inside the elevated controller:** this is the privilege risk the design exists to avoid.
- **A scheduled task or service account:** more host configuration and harder cleanup.
- **`runas /trustlevel`:** it can't hand over pipe handles.

### D4. Destination policy on the host, decided once per connection
For each `OPEN`:

1. **Parse.** A name that is a dotted quad is parsed strictly. Hex, octal and integer forms, and anything with characters outside `[A-Za-z0-9.-]`, are rejected.
2. **Resolve.** Other names are resolved with `Dns.GetHostAddresses`, and only IPv4 results are kept. IPv6 is always denied.
3. **Pick an address:** the first address that is not always-blocked and, when an allowlist exists, is inside a listed CIDR.
4. **Connect to that IP directly.** There's no second resolution, so there's no DNS-rebinding gap.

**Always-blocked ranges:**
- Every current host interface address, re-enumerated per connection (cheap, and covers DHCP changes). These stay blocked even when allowlisted.
- `0/8`, `10/8`, `100.64/10`, `127/8`, `169.254/16`, `172.16/12`, `192.0.0/24`, `192.168/16`, `198.18/15`, `224/4`, `240/4`. An explicitly allowlisted private CIDR overrides the range, except for host addresses.

**Limits:**

| Limit | Value |
|---|---|
| Connect timeout | 10 s |
| Idle timeout | 300 s |
| Concurrent streams | 64 |
| Total stream lifetime | VM lifetime |

The `serve` process gets the policy (allowlist, run ID, log path) in a JSON file written by the controller. It does not take policy from the guest.

### D5. Binaries built locally during setup, uploaded to the guest at start
- **Build:** `windows/egress/` holds two small projects, `FcEgress` (host) and `FcRelay` (guest), plus `FcEgress.Tests`. Setup runs `dotnet publish` for both into `C:\ProgramData\fc-sandbox-win\bin\egress\`.
- **Relay packaging:** the relay is a self-contained, trimmed, single-file `win-x64` executable with `InvariantGlobalization`. It doesn't depend on the image's runtime, so it works on `aspnet` and `iis-netfx` flavours alike.
- **Upload:** a networked start uploads it to `C:\fc\` in the guest with the existing tar-over-exec upload, before the relay session starts.
- **No SDK:** if setup finds no .NET 10 SDK, it warns and leaves the egress binaries absent. A `networked` start then fails with exit 125, and `doctor` reports why.

*Alternatives:*
- **Committed prebuilt binaries:** trust and signing problems in the repo.
- **NativeAOT** (about 3 MB instead of about 15 MB): needs the MSVC toolchain, which the host may not have. This can be revisited later.

### D6. Proxy settings for workloads
- **Environment variables:** every exec into a networked guest (payload, `ssh`/`shell`, image entrypoint) gets `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy` and `https_proxy` set to `http://127.0.0.1:3128`, plus `NO_PROXY=localhost,127.0.0.1`. That covers curl and .NET (Core) `HttpClient`.
- **.NET Framework flavours:** .NET Framework ignores those variables, so `iis-netfx-*` guests also get `<system.net><defaultProxy>` added to both `machine.config` files (Framework and Framework64) at start, before the entrypoint runs.

### D7. The relay starts before any workload; failures fail closed
- **Start order:**
  1. Container with `--network none` and the holding `cmd.exe`.
  2. Upload `fc-relay.exe`.
  3. `fc-egress launch`.
  4. Wait until a guest probe `curl -x http://127.0.0.1:3128` to a sentinel host gets the proxy's own 403 answer. This checks the whole guest–host path without any outbound connection.
  5. Image entrypoint (IIS), then the payload.
- **Failure:** if any step fails, teardown runs and the run exits with 125, the same as other infrastructure failures today.

### D8. Removal and migration
- **Code removed:** `computenetwork.dll` P/Invoke, `Ensure-FcWinNatNetwork`, the endpoint ACL and firewall code, the fail-closed probe from 2026-11-04, the `HNS_*` and `GUEST_DNS` constants, and `guest_ip` in `meta.json`.
- **Leftovers from older versions:** `cleanup` still removes `fc-win-*` firewall rules and the `fc-win-nat` network if they exist, so hosts set up earlier get cleaned.

## Risks / Trade-offs

- **[Head-of-line blocking:** all streams share one pipe, so a guest that stops reading can stall the channel.**]** → Per-stream credit windows mean only the stalled stream stops. The host never writes more than the granted credit.
- **[Proxy bugs are now the host's exposure.]** → The binary framing has fixed bounds, the process is unprivileged (Medium integrity, no admin, job object), the code is memory-safe C#, and the `FcEgress.Tests` unit tests cover framing, the strict IPv4 parser and the always-blocked list.
- **[Upload cost:** the self-contained relay is about 15 MB, uploaded on every networked start.**]** → Over HVSocket that's well under a second. NativeAOT can shrink it later (see Open Questions).
- **[Workloads that ignore proxy settings get no network** (some installers, raw sockets).**]** → Documented as a limitation; isolated-style failure is the safe default.
- **[Restricted token behaviour:** `SaferComputeTokenFromLevel` on an elevated token keeps the user SID, so the proxy can still read that user's files.**]** → It needs no file access beyond its policy file and `net.log`. Lowering integrity to Low was considered, but `net.log` lives under the repo's `runs\`. Medium plus the job object is the trade-off chosen.
- **[DNS through the host resolver** can reveal requested names to the host's DNS servers.**]** → Expected for a networked run. Each name is also logged in `net.log`.

## Migration Plan

1. Land the proxy and relay, the start-order change and the new tests, removing the HNS code in the same change.
2. `setup -Guest windows` builds the egress binaries. Existing hosts rerun setup once.
3. `cleanup -Guest windows` removes legacy `fc-win-nat` networks and `fc-win-*` firewall rules.
4. **Rollback:** revert the change. Networked mode then goes back to the fail-closed refusal on hosts that don't enforce ACLs, which is safe.

## Open Questions

- The exact values for idle timeout, stream count and window size can be tuned after the smoke tests without changing the specs.
- Whether to switch the relay to NativeAOT later, when the MSVC toolchain is available, to cut the upload size.
