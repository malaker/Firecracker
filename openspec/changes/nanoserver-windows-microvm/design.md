# Design

## Context

- `fc.ps1` currently dispatches all commands to a WSL2 distro (`fc-host`) running Linux Firecracker microVMs (`host/bin/fcctl`).
- Firecracker is a Linux-only VMM (direct `vmlinux` boot, no UEFI/ACPI/Hyper-V enlightenments), and Nano Server 2025 (`ltsc2025`) is distributed strictly as a Windows container OS image whose base layer already embeds Microsoft's pre-built **Hyper-V Utility VM (`UtilityVM`)** kernel and `HVSocket` guest agent.
- The user maintains a fork of the enhanced Nano Server 2025 images (`malaker/nanoserver`, forked from `adaskothebeast/nanoserver` and cloned locally at `C:\sources\nanoserver`) featuring 32-bit `SysWOW64`, the native `nanoserver_sta_shim.dll` (COM STA, Win32 message queue, GDI/Shell32/OLE/Delphi/VB6/MFC10 shims), IIS 10, .NET 10, and .NET Framework 4.8.1.
- On this Windows 11 host (build 26200), `hcsdiag.exe` is present in `System32`, while no Windows-side `docker` or `containerd` binary is installed yet.
- See `proposal.md` for motivation and `specs/` for behavioral requirements.

```
Windows 11 (PowerShell)
 |  .\fc.ps1 <cmd> [-Guest linux|windows] [-Flavour aspnet-x86|...]
 |
 +-- [-Guest linux (default)]
 |     +--> wsl.exe -d fc-host -u root -e /opt/fc-sandbox/bin/fcctl ...
 |            +--> jailer --> firecracker --> Linux microVM (Ubuntu 24.04)
 |
 +-- [-Guest windows]
       +--> windows\fcctl-win.ps1 (Elevated PowerShell controller)
              +-- Runtime adapter: Docker Engine (docker.exe) OR containerd (nerdctl.exe + runhcs-v1)
              +-- Windows Host Compute Service (HCS / vmcompute.dll)
                    +--> vmwp.exe (Hyper-V Utility VM, --isolation=hyperv)
                           |  HVSocket (exec, stdout/stderr, exit code)
                           |  sandbox.vhdx (ephemeral CoW scratch disk with C:\work\in, C:\work\out)
                           |  HNS Endpoint + ACLs (networked mode only; none in isolated mode)
                           v
                     Windows Nano Server 2025 Guest (<ImageRepo>:<Flavour>)
```

## Goals / Non-Goals

**Goals:**
- Keep `.\fc.ps1` 100% backwards-compatible when `-Guest` is omitted (`linux` remains default).
- Provide hardware-level hypervisor isolation for every Windows run (`--isolation=hyperv` Utility VM with its own Windows kernel, never shared-kernel process isolation).
- Allow choosing the Windows runtime (`docker` vs `containerd`+`nerdctl`+`runhcs`) and image source (pulling from `malaker/nanoserver` or any custom `-ImageRepo`, or building from `./externalimages` via `-BuildFromSource`).
- Match the Linux sandbox contract for network isolation, CIDR allowlists, hard timeouts, exit codes (`124` timeout, `125` infra error), and `runs\<run-id>\` artifacts.

**Non-Goals:**
- Booting Nano Server inside AWS Firecracker or hacking a raw Gen-2 UEFI VHDX with transplanted Server Core boot drivers (HCS `UtilityVM` already provides the supported microVM kernel).
- Full interactive RDP/GUI desktop virtualization (headless Win32/GDI/COM STA is handled by `nanoserver_sta_shim.dll`; full desktop GUI belongs to Windows Sandbox).

## Decisions

**D1: Unified `fc.ps1` dispatcher with `-Guest linux|windows` and `-Flavour <tag>`.**
`fc.ps1` gains `-Guest` (`linux` default, `windows`), `-Flavour` (`aspnet-x86` default, `aspnet-x64`, `iis-aspnet-x86`, `iis-aspnet-x64`, `iis-netfx-x86`, `iis-netfx-x64`), `-WinRuntime` (`docker`|`containerd`), `-ImageRepo` (default `malaker/nanoserver`), and `-BuildFromSource`. When `-Guest linux` is active, `fc.ps1` executes the existing WSL2 path unchanged. When `-Guest windows` is active, `fc.ps1` invokes `windows\setup-nanoserver.ps1` (for `setup`) or `windows\fcctl-win.ps1` (for `doctor`, `run`, `shell`, `start`, `ssh`, `list`, `stop`, `cleanup`).

**D2: Hyper-V Utility VM (`--isolation=hyperv`) as the microVM boundary.**
Every Windows container/microVM is launched with `--isolation=hyperv`, which instructs Windows HCS (`vmcompute.dll`) to spawn an isolated `vmwp.exe` Hyper-V microVM booting Microsoft's `UtilityVM` kernel and mounting the Nano Server layers plus a disposable `sandbox.vhdx` scratch disk. Alternative: Process isolation (`--isolation=process`). Rejected because untrusted payloads would share the Windows 11 host kernel.

**D3: Pluggable Windows Runtime Adapter (`docker` vs `containerd` + `nerdctl` + `runhcs`).**
A thin runtime abstraction module (`windows/lib/runtime.ps1`) normalizes lifecycle commands (`Start-WinMicroVm`, `Exec-WinMicroVm`, `Stop-WinMicroVm`, `Copy-FromWinMicroVm`, `Test-WinRuntime`) across two supported backends:
1. `docker` (default): Standalone Windows Moby/Docker Engine (`dockerd.exe` registered as a Windows service with `"exec-opts": ["isolation=hyperv"]` + `docker.exe` CLI, installed into `C:\ProgramData\fc-sandbox-win\bin` without Docker Desktop).
2. `containerd`: Standalone Windows `containerd.exe`, `containerd-shim-runhcs-v1.exe` (`microsoft/hcsshim`), `ctr.exe`, and `nerdctl.exe` configured with the `io.containerd.runhcs.v1` Hyper-V isolated runtime.
Pinned versions and SHA-256 checksums for both backends are stored in `windows/versions.psd1`. The selected runtime and default image repo are persisted in `C:\ProgramData\fc-sandbox-win\config.json`.

**D4: Customizable Image Repository (`malaker/nanoserver` default) and `./externalimages` Source Build.**
- By default, `fc.ps1 setup -Guest windows` pulls `<ImageRepo>:<Flavour>` (default `malaker/nanoserver:aspnet-x86`, overridable via `-ImageRepo adaskothebeast/nanoserver` or any registry).
- When `-BuildFromSource` is passed, `setup-nanoserver.ps1` looks for `./externalimages` (supporting either a direct clone of the nanoserver repo in `./externalimages` or `./externalimages/nanoserver`, or a junction to `C:\sources\nanoserver`), builds `sta-shim\build_shim.ps1` if needed, and runs the `<flavour>\Dockerfile` build locally, tagging the resulting image as `<ImageRepo>:<Flavour>`.
- Default flavour is `aspnet-x86` because it includes both 64-bit OS binaries and the 32-bit `SysWOW64` subsystem, `nanoserver_sta_shim.dll` (32-bit & 64-bit), VB6/MFC10/GDI+ runtimes, and .NET 10.

**D5: Payload staging (`C:\work\in`, `C:\work\out`) and execution over HVSocket (`tar.exe` streaming).**
- Inside the Hyper-V Utility VM's ephemeral `sandbox.vhdx` scratch layer, `Start-FcWinMicroVm` creates `C:\work\in`, `C:\work\out`, and `C:\work\.fc`.
- Instead of mounting a live writable host `vSMB` share (`-v`), `Send-FcWinGuestFiles` and `Receive-FcWinGuestFiles` stream `tar.exe` archives over the runtime's `HVSocket` exec channel (`tar.exe -xf -` in the guest before execution, and `tar.exe -cf -` from `C:\work\out` after execution, extracted on the host by `bsdtar` which rejects `..` and absolute paths).
- Commands are uploaded as a batch file into `C:\work\.fc` and executed as `USER ContainerAdministrator` with working directory `C:\work` via `cmd.exe /S /C` while `FcProc` streams `stdout.log` and `stderr.log` to disk in real time (and `ssh` / `shell` opens an interactive `cmd.exe` session over `HVSocket`), so isolated mode requires zero network interfaces and zero host filesystem shares inside the guest.

**D6: Network modes (`isolated` vs `networked`) and Host/Allowlist Protection on Windows.**
- `isolated` (default): MicroVM starts with `--network none`. Only loopback exists inside the Utility VM; `ipconfig` / `route print` shows no external adapter.
- `networked`: MicroVM attaches to a dedicated HNS NAT network (`fc-win-nat`, subnet `172.31.0.0/16`) and receives outbound HNS Endpoint ACL policies (via `hns.psm1` / `Invoke-HnsRequest` or per-endpoint `New-NetFirewallRule`) applied before payload execution:
  - Always block outbound traffic to the HNS gateway (host), Windows host IPs, other microVMs in `172.31.0.0/16`, RFC1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), link-local (`169.254.0.0/16`), CGNAT (`100.64.0.0/10`), and loopback/multicast.
  - When `-Allow <cidr>[,<cidr>...]` is specified, add explicit higher-priority Allow rules only for the listed CIDRs and a catch-all Block rule for `0.0.0.0/0` and `::/0`.

**D7: Run state, detached watchdog, and `--keep`.**
- State for Windows microVMs lives in `C:\ProgramData\fc-sandbox-win\vms\<run-id>\meta.json`.
- A detached background PowerShell watchdog process (`Start-Process powershell.exe -WindowStyle Hidden`) sleeps for the VM lifetime (`Timeout + 30s` grace) and invokes `fcctl-win.ps1 _expire <run-id>`, forcefully terminating the Utility VM (`hcsdiag kill` + runtime `rm -f`), removing firewall/ACL rules, and marking `timed_out: true` and `exit_code: 124` in `runs\<run-id>\meta.json` if the main controller died.
- When `-Keep` is passed, the stopped container/scratch layer and staging directory are preserved in `kept` state until `stop <run-id> -Guest windows` or `cleanup -Guest windows`.

**D8: Repository layout additions.**
```
fc.ps1                          Unified entry point (-Guest linux|windows)
windows/
  setup-host.ps1                Existing WSL2/Firecracker host setup
  setup-nanoserver.ps1          Windows Hyper-V + runtime + Nano Server image setup
  versions.psd1                 Pinned URLs and SHA-256 checksums for Windows docker/containerd/nerdctl/runhcs
  fcctl-win.ps1                 Windows microVM controller
  lib/
    common.ps1                  Logging, run-id, duration parser, exit codes
    runtime.ps1                 Docker & containerd+nerdctl+runhcs abstraction
    net.ps1                     HNS NAT network and per-VM outbound ACL/firewall rules
    state.ps1                   VM state dir, meta.json, detached watchdog
    doctor.ps1                  Windows feature, HCS, runtime, image, and boot checks
samples/
  hello/                        Existing Linux sample
  hello-win/                    Windows Nano Server sample payload (hello.cmd)
tests/
  smoke/                        Existing Linux smoke tests
  smoke-win/                    End-to-end Windows microVM smoke tests (all.ps1)
externalimages/                 Gitignored optional folder for -BuildFromSource
```

## Risks / Trade-offs

- [Enabling `Microsoft-Hyper-V` or `Containers` on a fresh Windows host requires a reboot.] → `setup-nanoserver.ps1` detects whether a reboot is pending, asks for confirmation before enabling features, and instructs the user to reboot and re-run `setup` if Windows reports `RestartNeeded`.
- [IIS flavours (`iis-aspnet-*`, `iis-netfx-*`) have a default `ENTRYPOINT` (`iis_service_monitor.exe`) that stays running.] → For `start` mode, running the default entrypoint keeps IIS alive in the background while `ssh`/`exec` runs commands inside it; for one-shot `run` mode, the controller overrides entrypoint or runs the payload command alongside the started Utility VM so `run` exits cleanly when `-Cmd` finishes.
- [PowerShell scripts in this repo are not Authenticode-signed (the code-signing certificate expired on 2026-11-05 and is not being renewed).] → Clones run under the default `RemoteSigned` policy; ZIP downloads must be unblocked (`Unblock-File`) or run with `-ExecutionPolicy Bypass`, and `AllSigned` hosts must sign the scripts themselves.
- [Building Nano Server images from source (`-BuildFromSource`) takes several minutes on first build due to DISM capabilities and `mcr.microsoft.com/dotnet/sdk:10.0-windowsservercore-ltsc2025` installer stages.] → Defaulting to pulling prebuilt images from `malaker/nanoserver` keeps standard setup fast, while `-BuildFromSource` is available whenever custom image changes in `./externalimages` need testing.

## Migration Plan

1. Existing `.\fc.ps1` invocations without `-Guest` continue to target `linux` with zero changes to `fc-host` or existing workflows.
2. Users opting into Windows microVMs run `.\fc.ps1 setup -Guest windows [-WinRuntime docker|containerd] [-ImageRepo malaker/nanoserver] [-Flavour aspnet-x86] [-BuildFromSource]`.
3. Rollback for the Windows backend: run `.\fc.ps1 cleanup -Guest windows`, stop and unregister the standalone `dockerd` or `containerd` service, remove `C:\ProgramData\fc-sandbox-win`, and remove the `fc-win-nat` HNS network.
