# Tasks

## 1. Repository scaffolding and runtime configuration

- [x] 1.1 Create the Windows controller directory layout from design D8 (`windows/lib/`, `samples/hello-win/`, `tests/smoke-win/`) and add `/externalimages/` to `.gitignore`; verify the directories exist and `git check-ignore externalimages/` succeeds
- [x] 1.2 Create `windows/versions.psd1` with pinned release URLs and SHA-256 checksums for standalone Windows Docker Engine (`dockerd.exe`, `docker.exe`) and Windows `containerd`, `nerdctl`, and `containerd-shim-runhcs-v1` (`microsoft/hcsshim`), plus default `ImageRepo = 'malaker/nanoserver'` and `DefaultFlavour = 'aspnet-x86'`; verify `Import-PowerShellDataFile .\windows\versions.psd1` loads all keys cleanly
- [x] 1.3 Implement `windows/lib/common.ps1` (run-id generation, duration parsing, exit codes `124`/`125`, config persistence in `C:\ProgramData\fc-sandbox-win\config.json`, flavour validation against the 6 Nano Server tags); verify with a PowerShell unit check that `ConvertFrom-Duration '10m'` returns `600` and invalid flavours are rejected

## 2. Windows microVM host setup and doctor (`windows-microvm-host-setup`)

- [x] 2.1 Implement `windows/setup-nanoserver.ps1`: check `Microsoft-Hyper-V` and `Containers` Windows optional features, prompt for confirmation before enabling (unless `-Yes` is passed), and install/configure the selected `-WinRuntime docker|containerd` service with checksum verification; verify declining feature enablement exits non-zero without modifying the host and re-running on a configured host skips downloads
- [x] 2.2 Add image provisioning to `windows/setup-nanoserver.ps1`: pull `<ImageRepo>:<Flavour>` (default `malaker/nanoserver:aspnet-x86`, customizable via `-ImageRepo`) by default, or build locally from `./externalimages` (supporting `./externalimages` or a link to `C:\sources\nanoserver`) when `-BuildFromSource` is passed; verify both pull mode and `-BuildFromSource` error handling when `./externalimages` is absent
- [x] 2.3 Implement `windows/lib/doctor.ps1` (`Invoke-WinDoctor`): verify `Microsoft-Hyper-V` and `Containers` features, `vmcompute` (HCS) service, active runtime daemon (`docker` or `containerd`+`runhcs`), base image presence, free memory/disk, and optional `-Boot` Hyper-V Utility VM smoke boot; verify `.\fc.ps1 doctor -Guest windows` prints PASS/FAIL per check with remediation hints
- [x] 2.4 Document Windows host setup (`-Guest windows`, `-WinRuntime`, `-ImageRepo`, `-Flavour`, `-BuildFromSource`) and uninstall steps in `README.md`; verify the documented setup and doctor commands match the script parameter sets

## 3. Pluggable runtime adapter and Windows microVM lifecycle (`microvm-lifecycle`)

- [x] 3.1 Implement `windows/lib/runtime.ps1`: abstract `docker` (`--isolation=hyperv`) and `containerd` (`nerdctl` / `io.containerd.runhcs.v1`) operations for creating, starting, executing commands in, inspecting, and removing Hyper-V Utility VMs with `--cpus` and `--memory` limits; verify a test Utility VM runs in Hyper-V isolation (`hcsdiag list` shows the active Utility VM)
- [x] 3.2 Implement `windows/lib/state.ps1` and detached timeout watchdog (`_expire` handler in `windows/fcctl-win.ps1`): manage `C:\ProgramData\fc-sandbox-win\vms\<run-id>\meta.json`, spawn a hidden PowerShell watchdog process enforcing hard lifetime, and support `-Keep`; verify `tests/smoke-win/lifecycle.ps1` confirms a 15-second timeout terminates the Utility VM and records `timed_out: true` and `exit_code: 124`
- [x] 3.3 Implement `start`, `list`, `stop`, and `cleanup` in `windows/fcctl-win.ps1`; verify `tests/smoke-win/lifecycle.ps1` starts a Windows microVM, lists its run-id, flavour, and resources, stops it, and confirms `cleanup -Guest windows` removes all leftover Utility VMs, containers, and state directories
- [x] 3.4 Document Windows lifecycle options (`-Guest windows`, `-Flavour`, `-Vcpu`, `-MemMib`, `-Timeout`, `-Keep`) in `README.md`; verify `.\fc.ps1 help` and `README.md` list identical options

## 4. Windows microVM network modes (`microvm-network-modes`)

- [x] 4.1 Implement `isolated` network mode in `windows/lib/net.ps1` and `windows/lib/runtime.ps1` (`--network none`); verify `tests/smoke-win/net-isolated.ps1` confirms `ipconfig` in the guest shows no external network adapter and outbound connections fail while host control and file staging still succeed
- [x] 4.2 Implement `networked` mode in `windows/lib/net.ps1`: create/manage the `fc-win-nat` HNS NAT network (`172.31.0.0/16`), attach the microVM endpoint, and apply outbound HNS ACL / Windows Firewall rules blocking the host gateway, Windows host IPs, other microVMs, RFC1918, link-local, and CGNAT while allowing public egress or restricting strictly to `-Allow <cidr>[,<cidr>...]`; verify `tests/smoke-win/net-protect.ps1` confirms host/RFC1918 connections are dropped and `-Allow` restricts egress to listed CIDRs
- [x] 4.3 Implement deterministic network teardown on `stop`, `cleanup`, and watchdog timeout; verify no per-VM HNS endpoint or firewall rule remains after a networked Windows microVM stops
  - Superseded: 4.2 and 4.3 are replaced by the `windows-proxy-networked-mode` change (Windows 11 does not enforce HNS endpoint ACLs; networked mode now uses the fc-egress proxy with no guest adapter, and its teardown is covered there).
- [x] 4.4 Document Windows network modes and HNS/firewall behavior in `README.md`; verify the documented `-Net networked -Allow ... -Guest windows` example runs as written

## 5. Unified CLI, payload test runs, and interactive shell (`sandbox-test-runs`)

- [x] 5.1 Extend `fc.ps1` with `-Guest linux|windows` (default `linux`), `-Flavour`, `-WinRuntime`, `-ImageRepo`, and `-BuildFromSource`, dispatching `linux` to WSL `fcctl` and `windows` to `windows/setup-nanoserver.ps1` / `windows/fcctl-win.ps1`; verify existing `.\fc.ps1` Linux commands work unchanged without `-Guest`
- [x] 5.2 Implement `run`, `shell`, and `ssh` in `windows/fcctl-win.ps1`: stream `-Payload` into `C:\work\in` inside the Utility VM over `HVSocket` via `tar.exe`, execute `-Cmd` in `C:\work` as `ContainerAdministrator` (handling both Kestrel and IIS flavours cleanly), stream `stdout.log`/`stderr.log` in real time, stream `C:\work\out` and write `meta.json` (with `guest`, `flavour`, `image_repo`, `win_runtime`) to `runs\<run-id>\`, and propagate exit codes (`124` timeout, `125` infra error); verify with `samples/hello-win/hello.cmd` that `runs\<run-id>\` contains `exit_code`, `stdout.log`, `stderr.log`, `meta.json`, and `out\whoami.txt`
- [x] 5.3 Add `samples/hello-win/hello.cmd` (exercising 64-bit/32-bit execution and writing to `C:\work\out\whoami.txt`) and update quick-start documentation in `README.md`; verify `.\fc.ps1 run -Guest windows -Payload .\samples\hello-win -Cmd '.\in\hello.cmd'` succeeds end-to-end

## 6. End-to-end integration verification

- [x] 6.1 Create `tests/smoke-win/all.ps1` running all Windows microVM smoke tests (doctor, isolated run, 32-bit WoW64 & STA shim execution, networked egress + host blocking + allowlist, timeout watchdog, start/ssh/list/stop/cleanup) and verify both `tests/smoke/all.sh` (Linux) and `tests/smoke-win/all.ps1` (Windows) pass

## Workflow follow-up

- Scripts are unsigned (code-signing certificate expired 2026-11-05); no re-signing step.
- Archive the change with `openspec archive` after implementation and smoke test verification are complete.
