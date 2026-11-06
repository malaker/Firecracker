# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

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
