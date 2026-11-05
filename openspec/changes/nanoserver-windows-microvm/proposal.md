# Proposal

## Why

Security testing and untrusted payload detonation on Windows 11 often target Windows-native executables (32-bit `x86` and 64-bit `x64` PE binaries, legacy COM/STA DLLs, .NET Framework 4.8.1 and .NET 10 workloads) that cannot run inside Linux Firecracker microVMs. By combining Windows Hyper-V Utility VMs (`--isolation=hyperv`) with the ultra-thin Nano Server 2025 images (`malaker/nanoserver`, forked from `adaskothebeast/nanoserver` with WoW64, STA/Win32 message-queue shims, IIS and .NET runtimes), `fc.ps1` can spin up disposable, hardware-isolated Windows microVMs alongside Linux Firecracker microVMs under one unified CLI.

## What Changes

- Extend `fc.ps1` with `-Guest linux|windows` (defaulting to `linux` for full backwards compatibility) and `-Flavour <tag>` (`aspnet-x86`, `aspnet-x64`, `iis-aspnet-x86`, `iis-aspnet-x64`, `iis-netfx-x86`, `iis-netfx-x64`, defaulting to `aspnet-x86`) across `setup`, `doctor`, `run`, `shell`, `start`, `ssh`, `list`, `stop`, and `cleanup`.
- Add configurable Windows microVM host setup (`windows/setup-nanoserver.ps1`) supporting a user-selectable runtime backend (`-WinRuntime docker|containerd`, choosing between standalone Windows Docker Engine `dockerd.exe`/`docker.exe` or Windows `containerd` + `nerdctl` + `containerd-shim-runhcs-v1.exe`), verifying/enabling Windows `Containers` and `Microsoft-Hyper-V` features with user confirmation.
- Support pulling prebuilt Nano Server guest images from a customizable image repository (`-ImageRepo`, defaulting to `malaker/nanoserver` and supporting `adaskothebeast/nanoserver` or custom registries) or building them locally from `./externalimages` when `-BuildFromSource` is specified.
- Implement a Windows microVM controller (`windows/fcctl-win.ps1`) that launches each Windows guest inside a dedicated Hyper-V Utility VM (`--isolation=hyperv`) with configurable vCPU and memory limits, a disposable Copy-on-Write scratch layer, and a detached PowerShell timeout watchdog.
- Implement `isolated` (zero network adapters inside the Utility VM; control and `tar.exe` file streaming over Hyper-V `HVSocket`) and `networked` (HNS NAT endpoint with outbound host/RFC1918 blocking and optional `-Allow` CIDR allowlist rules) modes for Windows microVMs.
- Unify payload execution and result collection for Windows guests: stage `-Payload` to `C:\work\in`, execute `-Cmd` in `C:\work`, and collect `C:\work\out`, `stdout.log`, `stderr.log`, `exit_code`, and `meta.json` into `runs\<run-id>\`.

## Capabilities

### New Capabilities
- `windows-microvm-host-setup`: Bootstrapping and verifying the Windows Hyper-V microVM host, selectable container/uVM runtime (`docker` or `containerd`+`nerdctl`+`runhcs`), and Nano Server base images (pulling from a configurable repo such as `malaker/nanoserver` or building from `./externalimages`).

### Modified Capabilities
- `microvm-lifecycle`: Extending microVM creation, hardware isolation (`--isolation=hyperv` Utility VM on Windows alongside Firecracker+jailer on Linux), resource limits, detached watchdog timeouts, `--keep`, `list`, `stop`, and `cleanup` to manage both Linux and Windows microVMs.
- `microvm-network-modes`: Extending `isolated` and `networked` (with host/private subnet protection and `-Allow` CIDR allowlists) to Windows Hyper-V Utility VMs via HNS and Windows Firewall/ACL policies.
- `sandbox-test-runs`: Extending `fc.ps1` (`run`, `shell`, `start`, `ssh`) to select `-Guest linux|windows` and `-Flavour`, map payloads into `C:\work\in` for Windows guests, collect `C:\work\out` and logs into `runs\<run-id>\`, and record guest/runtime/image metadata in `meta.json`.

## Impact

- Modified files: `fc.ps1`, `README.md`.
- New files in `windows/`: `windows/setup-nanoserver.ps1`, `windows/fcctl-win.ps1`, `windows/lib/*.ps1` (runtime abstraction for `docker` vs `containerd`/`nerdctl`/`runhcs`, network/firewall rules, state & watchdog, doctor checks).
- New sample & tests: `samples/hello-win/` sample payload and `tests/smoke-win/` end-to-end Windows microVM smoke test suite.
- Optional local image source directory: `./externalimages/` (gitignored or used when `-BuildFromSource` is passed, with fallback/link support for `C:\sources\nanoserver`).
- Windows host impact (when `-Guest windows` setup is run): requires Windows `Containers` and `Microsoft-Hyper-V` features (prompts before enabling/rebooting), installs standalone Windows Docker Engine or `containerd`+`nerdctl`+`runhcs` into a dedicated runtime directory, and pulls or builds the selected `malaker/nanoserver` base image.
