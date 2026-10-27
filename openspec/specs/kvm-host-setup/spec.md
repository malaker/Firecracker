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
