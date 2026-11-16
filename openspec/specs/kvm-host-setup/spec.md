# kvm-host-setup Specification

## Purpose

Provides a repeatable way to turn this Windows 11 workstation into a host that can run Firecracker microVMs, and to diagnose why it cannot.

## Requirements

### Requirement: One-command host bootstrap
The system SHALL provide a single command, run from Windows, that creates a dedicated WSL2 distro for microVMs and installs the Firecracker and jailer binaries, a guest kernel and a base guest root filesystem into it.

#### Scenario: Fresh machine
- **WHEN** the user runs the setup command on a machine without the dedicated distro
- **THEN** the distro is created, all components are installed, and the command ends by running the preflight check and reporting success

#### Scenario: Existing distros untouched
- **WHEN** setup runs on a machine that already has other WSL distros
- **THEN** no other distro's files or configuration are modified

### Requirement: Idempotent setup
Running setup again SHALL leave an already-correct host unchanged and repair only missing or mismatched components.

#### Scenario: Re-run on configured host
- **WHEN** setup is run twice in a row
- **THEN** the second run downloads nothing and reports that all components are up to date

### Requirement: Pinned and verified artifacts
All downloaded binaries and images SHALL be pinned to explicit versions recorded in the repository and verified against recorded checksums before use.

#### Scenario: Checksum mismatch
- **WHEN** a downloaded artifact does not match its recorded checksum
- **THEN** setup deletes it, stops with a non-zero exit code, and names the artifact that failed

### Requirement: Nested virtualization enablement
Setup SHALL ensure WSL2 nested virtualization is enabled, and MUST ask for confirmation before changing `.wslconfig` or restarting WSL.

#### Scenario: Nested virtualization disabled
- **WHEN** `/dev/kvm` is missing in the dedicated distro
- **THEN** setup explains that `.wslconfig` must be updated and WSL restarted, and does so only after the user confirms

#### Scenario: User declines
- **WHEN** the user declines the `.wslconfig` change
- **THEN** setup stops without modifying `.wslconfig` and exits non-zero with instructions

### Requirement: Preflight diagnostics
The system SHALL provide a `doctor` command that checks every precondition for running a microVM and reports each as pass or fail with a remediation hint.

#### Scenario: All checks pass
- **WHEN** the host is fully configured
- **THEN** `doctor` lists each check as passed and exits with code 0

#### Scenario: KVM not accessible
- **WHEN** `/dev/kvm` is missing or not readable and writable by the controller user
- **THEN** `doctor` reports the KVM check as failed with a hint and exits non-zero

### Requirement: Airlock tooling for Linux guests
Linux setup SHALL build the airlock tool for `linux-x64` with the .NET 10 SDK and install it into the controller. When no .NET 10 SDK is found, setup MUST fail with a message naming the SDK and how to install it. Re-running setup SHALL rebuild the tool only when its sources changed. `doctor` SHALL report the tool's presence as a check.

#### Scenario: SDK missing
- **WHEN** the user runs `fc.ps1 setup` on a machine without a .NET 10 SDK
- **THEN** setup exits non-zero with a message naming the .NET 10 SDK

#### Scenario: Doctor check
- **WHEN** the airlock tool is missing from the controller
- **THEN** `doctor` reports the airlock check as failed with a hint to re-run setup, and exits non-zero

### Requirement: Agent image and gateway build
Linux setup SHALL build the agent image (from the base image, a pinned and checksum-verified Node.js release, agent clients installed from a committed lockfile with integrity hashes, and analysis tool packages listed in a committed lock file with their checksums) and install the LLM gateway into the controller. Re-running setup SHALL rebuild the agent image only when its inputs changed. `doctor` SHALL report the agent image and the gateway as checks.

#### Scenario: Pinned inputs
- **WHEN** the downloaded Node.js release, an agent package or an analysis tool package does not match its recorded checksum or integrity hash
- **THEN** setup stops with an error naming the file, and the previous agent image is kept

#### Scenario: Re-run without changes
- **WHEN** setup runs again and the agent image inputs did not change
- **THEN** the agent image is not rebuilt

#### Scenario: Doctor checks
- **WHEN** the agent image or the gateway is missing
- **THEN** `doctor` reports that check as failed with a hint to re-run setup, and exits non-zero

#### Scenario: Tool lock file changed
- **WHEN** the analysis tool lock file changes and setup runs again
- **THEN** the agent image is rebuilt with the newly listed packages

### Requirement: Recipes installed with the controller
Linux setup SHALL install the repository's recipes into the controller and update them when they change. `doctor` SHALL report whether the recipes are installed and whether every manifest is valid. Setup with `-NoAgentImage` SHALL still install the recipes, and running a recipe that needs the missing agent image MUST fail with exit code 125 and a hint to re-run setup.

#### Scenario: Recipe changed in the repository
- **WHEN** a recipe's script is edited and setup runs again
- **THEN** the next run of that recipe uses the edited script

#### Scenario: Invalid manifest reported
- **WHEN** an installed recipe has an invalid manifest
- **THEN** `doctor` reports the recipes check as failed, naming the recipe

#### Scenario: Agent image skipped
- **WHEN** setup ran with `-NoAgentImage` and the user runs `fc.ps1 recipe triage-static -Sample .\x.bin`
- **THEN** the command exits 125 saying the agent image is missing and to re-run setup
