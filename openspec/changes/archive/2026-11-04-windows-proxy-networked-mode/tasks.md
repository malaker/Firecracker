# Tasks

## 1. Egress projects and frame protocol

- [x] 1.1 Create `windows/egress/` with `FcEgress` (host, net10.0-windows), `FcRelay` (guest, self-contained trimmed single-file `win-x64`, `InvariantGlobalization`) and `FcEgress.Tests` (xunit), plus a shared frame source file. Verify that `dotnet build windows/egress` succeeds.
- [x] 1.2 Implement the frame codec from design D2 (types `OPEN`/`OPEN_OK`/`OPEN_FAIL`/`DATA`/`WINDOW`/`CLOSE`; 64 KiB payload cap; host-name length 1–253; stream-ID limit) with a reader that treats unknown types, oversize lengths, a duplicate `OPEN` and an out-of-range stream as protocol errors. Verify with `FcEgress.Tests` cases for each valid type, each error case, and a truncated frame at EOF.
- [x] 1.3 Implement per-stream credit windows (256 KiB, `WINDOW` updates) shared by both sides. Verify with a unit test where one stream stops reading and another keeps flowing, with buffered bytes never exceeding the window.

## 2. Host destination policy

- [x] 2.1 Implement the strict dotted-quad parser and host-name character check from design D4. Verify that unit tests reject `0x7f.0.0.1`, `2130706433`, `127.1`, `01.2.3.4`, names containing `_` or spaces, and empty or 254-character names, and accept `1.1.1.1` and `example.com`.
- [x] 2.2 Implement CIDR matching, the always-blocked list (`0/8`, `10/8`, `100.64/10`, `127/8`, `169.254/16`, `172.16/12`, `192.0.0/24`, `192.168/16`, `198.18/15`, `224/4`, `240/4`, all IPv6), per-connection enumeration of host interface addresses, allowlist overrides for private ranges, and "host addresses are never allowed". Verify with unit tests for each `windows-egress-proxy` "Always-blocked destinations" and "Allowlist enforcement" scenario, using an injected host-address list.
- [x] 2.3 Implement resolution and selection: resolve on the host, keep IPv4, pick the first permitted address, connect to that IP only, and deny when nothing is permitted. Verify with unit tests using a fake resolver for the "mixed public and blocked addresses" and "resolves to a blocked address" scenarios.

## 3. Host egress process (`fc-egress`)

- [x] 3.1 Implement `serve` mode: read the policy JSON (`run_id`, `allow`, `log_path`), run the frame loop over stdin/stdout, handle `OPEN` through the policy and a 10 s connect timeout, enforce the 300 s idle timeout and 64 concurrent streams, and append one `net.log` line per attempt (timestamp, host, port, resolved IP, decision, reason, bytes). Exit cleanly on EOF. Verify with an integration test in `FcEgress.Tests` that drives `serve` over in-memory pipes against a local test listener: allowed, denied, oversize-frame (channel closed, protocol error logged) and too-many-streams cases.
- [x] 3.2 Implement `launch` mode from design D3: two anonymous pipe pairs; start `docker exec -i -u ContainerAdministrator <container> C:\fc\fc-relay.exe`; start `serve` with inherited handles under a `SaferComputeTokenFromLevel(NORMALUSER)` token at Medium integrity, inside a job object with no child processes and a memory cap; print both PIDs as JSON and exit. Verify manually on an elevated host that `serve` runs non-elevated and outside Administrators (`Get-Process -IncludeUserName`, plus a token check from `whoami /groups` run as `serve`'s user, or the equivalent self-check `fc-egress serve --print-token`).

## 4. Guest relay (`fc-relay`)

- [x] 4.1 Implement the relay: listen on `127.0.0.1:3128`; parse `CONNECT host:port` and absolute-URI HTTP requests (rewrite to origin form, drop `Proxy-*` headers); send `OPEN`; map `OPEN_FAIL` to `403` (denied) or `502` (connect failed) with a short reason body; pump `DATA`/`WINDOW`/`CLOSE`. Verify with `FcEgress.Tests` tests that run the relay and `serve` back to back in-process and push `curl`-style CONNECT and GET requests through both.
- [x] 4.2 Publish the relay as a self-contained single file and check it runs on Nano Server: upload it into an isolated `aspnet-x86` guest and an `iis-netfx-x86` guest, and verify that `fc-relay.exe --version` exits 0 in both.

## 5. Setup and doctor

- [x] 5.1 In `windows/setup-nanoserver.ps1`, detect a .NET 10 SDK and `dotnet publish` `FcEgress` and `FcRelay` into `C:\ProgramData\fc-sandbox-win\bin\egress\`. Skip when the outputs are newer than the sources. Warn without failing when no SDK is found. Verify that a setup rerun is idempotent and that the binaries exist afterwards.
- [x] 5.2 In `windows/lib/doctor.ps1`, replace the `computenetwork.dll` check with "egress proxy and relay binaries present (needed for -Net networked)", with a hint to install the .NET 10 SDK and rerun setup. Verify that `.\fc.ps1 doctor -Guest windows` shows PASS with the binaries and FAIL with the hint after they're temporarily renamed.
- [x] 5.3 Document the .NET 10 SDK prerequisite for Windows networked mode in the README Windows setup section, and verify that the documented commands match the script behaviour.

## 6. Controller integration

- [x] 6.1 In `Start-FcWinMicroVm` (`windows/lib/runtime.ps1`), always use `--network=none`, and remove `--dns` and `Get-FcContainerIp`. Verify that `docker inspect` of a networked VM shows no networks besides `none`, and that `ipconfig` in the guest lists only loopback.
- [x] 6.2 Add `Start-FcWinEgress` in `windows/lib/net.ps1`, implementing design D7 steps 2–4:
  - upload `fc-relay.exe` to `C:\fc\`;
  - write the policy JSON to the VM directory;
  - run `fc-egress launch`;
  - store `egress_pid` and `relay_exec_pid` in VM `meta.json` (replacing `guest_ip`);
  - wait for the sentinel 403 probe from the guest.

  Call it from `fcctl-win.ps1` before `Start-FcWinImageEntrypoint`, and fail with exit 125 on error. Verify that a networked `start` succeeds, that `meta.json` has both PIDs, and that killing `fc-egress.exe` before the probe completes makes the start fail with 125 and leaves no container behind.
- [x] 6.3 Add `Stop-FcWinEgress` (kill by PID after checking the process name, then remove the policy file) and call it from `Remove-FcWinVmInstance`, so `stop`, `cleanup`, the watchdog `_expire` and the start-failure path all stop the proxy. Verify that after each of the four paths no `fc-egress.exe` and no `docker exec` for that VM remain. Run the lifecycle smoke test's 3-second-timeout case with `-Net networked`.
- [x] 6.4 Pass the proxy environment variables (design D6) on every exec into a networked guest: payload, `ssh`/`shell`, and the image entrypoint. Write `<defaultProxy>` into both `machine.config` files on `iis-netfx-*` flavours before the entrypoint. Verify with `curl.exe https://example.com` in a networked `aspnet-x86` run, and a .NET Framework `WebClient` download in a networked `iis-netfx-x86` guest via `ssh`.
- [x] 6.5 Copy `net.log` into `runs\<run-id>\` during result collection, so it's kept on timeout and after errors. Verify that a networked run with one allowed and one denied request leaves both lines in `runs\<run-id>\net.log`, including when the run times out.

## 7. Remove the HNS design

- [x] 7.1 Delete the HNS code from `windows/lib/net.ps1`: the `FcHcn` P/Invoke, `Ensure-FcWinNatNetwork`, `Set-FcHcnEndpointAclPolicy`, `New-FcHcnAclPolicyPayload`, the firewall-rule creation, `Assert-FcWinNetPolicyEnforced` and `Get-FcWinNetProbeTargets`. Also remove the `HNS_*` and `GUEST_DNS` constants from `common.ps1`. Verify that `git grep -n "HNS_\|FcHcn\|NetFirewallRule\|computenetwork" windows/` only finds the legacy-cleanup code from 7.2.
- [x] 7.2 Keep the legacy cleanup in `cleanup -Guest windows`: remove `fc-win-*` firewall rules and `docker network rm fc-win-nat` when present. Verify on this host, where both exist from earlier runs, that `cleanup` removes them.
- [x] 7.3 Update the README network-modes section: Windows `networked` is proxy-only TCP, the guest has no adapter, `net.log` records connections, and the limitations (no ICMP/UDP, proxy-unaware programs). Replace the fail-closed warning with this, and correct the earlier threat-model claims that Windows Firewall or HNS ACLs enforce isolation. Verify by reading it against the `windows-egress-proxy` spec.

## 8. Smoke tests

- [x] 8.1 Rewrite `tests/smoke-win/net-protect.ps1` with real-address probes and positive controls:
  - the guest lists only loopback;
  - `curl --noproxy "*" https://example.com` fails;
  - `curl https://example.com` through the proxy succeeds (positive control);
  - for every host IPv4 address (from `Get-NetIPAddress`) and every host TCP port listening on all interfaces (from `Get-NetTCPConnection -State Listen`), a proxied `CONNECT` gets 403 and appears as denied in `net.log`;
  - the host's default gateway gets 403;
  - `CONNECT [2606:4700:4700::1111]:443` gets 403;
  - `-Allow 1.1.1.1/32`: `1.1.1.1:443` connects and `8.8.8.8:443` gets 403;
  - the allowlisted host LAN IP still gets 403.

  Verify that the test passes on this host, and that it fails if the always-blocked check is temporarily disabled in a local build.
- [x] 8.2 Update `tests/smoke-win/all.ps1` and `lifecycle.ps1` so nothing depends on `fc-win-nat` or a guest IP, and add a networked teardown check (no `fc-egress.exe` left after cleanup). Verify that `.\tests\smoke-win\all.ps1` passes end to end.

## Workflow follow-up

- Mark the HNS NAT and ACL network tasks in `openspec/changes/nanoserver-windows-microvm/tasks.md` as superseded by this change.
- Archive this change after review, then confirm that `openspec/specs/microvm-network-modes/spec.md` no longer mentions HNS ACLs, and that `windows-egress-proxy` has its Purpose.
