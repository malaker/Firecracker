# windows-microvm-host-setup Specification

## Purpose

Provides a repeatable way to bootstrap and verify this Windows 11 workstation to run disposable Hyper-V isolated Windows Nano Server microVMs with a configurable runtime backend and customizable image source.

## Requirements

### Requirement: Selectable Windows microVM runtime backend
Setup for Windows guests SHALL allow the user to choose between standalone Windows Docker Engine (`docker`) and Windows `containerd` with `nerdctl` and `runhcs` (`containerd`), defaulting to `docker`.

#### Scenario: Setup with Docker runtime
- **WHEN** the user runs setup with `-Guest windows` and the default or `docker` runtime option
- **THEN** standalone Windows Docker Engine is installed and configured to run Windows containers with Hyper-V isolation

#### Scenario: Setup with containerd and runhcs runtime
- **WHEN** the user runs setup with `-Guest windows -WinRuntime containerd`
- **THEN** Windows `containerd`, `nerdctl`, and `containerd-shim-runhcs-v1` are installed and configured for Hyper-V isolated execution

#### Scenario: Both runtimes installed side by side
- **WHEN** setup is run with `-WinRuntime containerd` on a host that already has the `docker` runtime
- **THEN** both runtimes stay installed and usable, and a command given an explicit `-WinRuntime` uses that runtime regardless of the configured default

#### Scenario: containerd microVM runs a payload
- **WHEN** the user runs `run -Guest windows -WinRuntime containerd` with an isolated payload
- **THEN** the guest runs in a Hyper-V Utility VM and the run produces the same `runs\<run-id>\` results and exit codes as on `docker`

### Requirement: Windows hypervisor and container feature enablement
Setup for Windows guests SHALL check that Windows `Microsoft-Hyper-V` and `Containers` features are enabled, and MUST ask for confirmation before enabling them or scheduling a reboot.

#### Scenario: Missing Windows features
- **WHEN** `Containers` or `Microsoft-Hyper-V` is disabled and the user runs setup with `-Guest windows`
- **THEN** setup explains which Windows features are required and enables them only after user confirmation (or when `-Yes` is passed)

#### Scenario: User declines feature enablement
- **WHEN** required Windows features are disabled and the user declines the confirmation prompt
- **THEN** setup makes no feature changes and exits non-zero with manual remediation instructions

### Requirement: Customizable prebuilt Nano Server image pull
By default, Windows setup SHALL pull the requested Nano Server flavour image from a configurable image repository defaulting to `malaker/nanoserver`.

#### Scenario: Default image repository pull
- **WHEN** the user runs setup with `-Guest windows` without overriding the repository or source build flag
- **THEN** setup pulls the requested flavour tag from `malaker/nanoserver`

#### Scenario: Custom image repository pull
- **WHEN** the user runs setup with `-Guest windows -ImageRepo adaskothebeast/nanoserver -Flavour aspnet-x86`
- **THEN** setup pulls `adaskothebeast/nanoserver:aspnet-x86` and registers it for Windows microVM runs

### Requirement: Local Nano Server image build from source
When `-BuildFromSource` is specified, Windows setup SHALL build the requested Nano Server flavour image locally from `./externalimages` (or a configured source path) instead of pulling a prebuilt image.

#### Scenario: Build from externalimages folder
- **WHEN** the user runs setup with `-Guest windows -BuildFromSource -Flavour aspnet-x86` and `./externalimages` contains the Nano Server source tree
- **THEN** setup builds the `nanoserver-aspnet-x86` base image locally and tags it under the configured image repository

#### Scenario: Missing source directory
- **WHEN** the user runs setup with `-Guest windows -BuildFromSource` and the source directory does not exist
- **THEN** setup exits non-zero with a clear message indicating where to clone or link the Nano Server repository

### Requirement: Idempotent Windows host setup
Re-running setup for Windows guests on an already-configured host SHALL skip completed runtime installations and image pulls or builds unless repair is needed.

#### Scenario: Re-run on configured Windows host
- **WHEN** Windows setup is run a second time with the same runtime and flavour
- **THEN** setup verifies existing binaries, service state, and image presence without re-downloading or rebuilding

### Requirement: Windows microVM preflight diagnostics
Running `doctor -Guest windows` SHALL verify Windows feature status, HCS availability, the configured runtime daemon (`docker` or `containerd`+`runhcs`), the configured Nano Server base image, and optionally boot a test Windows microVM when `-Boot` is given.

#### Scenario: All Windows checks pass
- **WHEN** the Windows host, runtime, and Nano Server image are ready and the user runs `doctor -Guest windows -Boot`
- **THEN** every precondition check and the test microVM boot report PASS and the command exits with code 0

#### Scenario: Runtime service stopped
- **WHEN** the configured Windows runtime service is stopped and the user runs `doctor -Guest windows`
- **THEN** `doctor` reports the runtime check as FAIL with a remediation hint and exits non-zero

### Requirement: Unsupported containerd features are refused up front
When a requested feature is declared unsupported on the `containerd` runtime, the controller SHALL refuse the command with exit code 125 and a message naming the feature and `-WinRuntime docker`, before starting a microVM or changing host state.

#### Scenario: Unsupported feature requested
- **WHEN** the user requests a feature declared unsupported on `containerd` (for example `-BuildFromSource`)
- **THEN** the command exits 125, names the unsupported feature and suggests `-WinRuntime docker`, and no microVM, container or proxy process is left behind

#### Scenario: Supported feature requested
- **WHEN** the user requests a feature that is supported on `containerd`
- **THEN** the command runs without a limitation warning

### Requirement: Doctor reports containerd limitations
When the active runtime is `containerd`, `doctor -Guest windows` SHALL list every feature declared unsupported on that runtime, and the README MUST document the same list.

#### Scenario: Doctor on containerd
- **WHEN** the user runs `doctor -Guest windows -WinRuntime containerd`
- **THEN** the output includes a note listing each unsupported feature, matching the README

#### Scenario: Doctor on docker
- **WHEN** the user runs `doctor -Guest windows` with the `docker` runtime
- **THEN** no containerd limitation note is shown

### Requirement: Airlock tooling for Windows guests
Windows setup SHALL build the airlock tool for `win-x64` with the .NET 10 SDK into a folder that only administrators can modify. When no .NET 10 SDK is found, setup MUST fail with a message naming the SDK and how to install it. Re-running setup SHALL rebuild the tool only when its sources changed. `doctor -Guest windows` SHALL report the tool's presence as a check.

#### Scenario: SDK missing
- **WHEN** the user runs `fc.ps1 setup -Guest windows` on a machine without a .NET 10 SDK
- **THEN** setup exits non-zero with a message naming the .NET 10 SDK

#### Scenario: Doctor check
- **WHEN** the airlock tool is missing
- **THEN** `doctor -Guest windows` reports the airlock check as failed with a hint to re-run setup, and exits non-zero
