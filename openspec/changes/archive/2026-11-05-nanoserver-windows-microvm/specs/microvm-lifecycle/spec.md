# Spec Delta

## ADDED Requirements

### Requirement: Guest OS and Nano Server flavour selection
The system SHALL allow each lifecycle command to target `-Guest linux` or `-Guest windows` (defaulting to `linux`), and for Windows guests to select a `-Flavour` tag (`aspnet-x86`, `aspnet-x64`, `iis-aspnet-x86`, `iis-aspnet-x64`, `iis-netfx-x86`, `iis-netfx-x64`, defaulting to `aspnet-x86`).

#### Scenario: Default guest is Linux
- **WHEN** the user starts a microVM without specifying `-Guest`
- **THEN** the system boots a Linux Firecracker microVM

#### Scenario: Windows guest with explicit flavour
- **WHEN** the user starts a microVM with `-Guest windows -Flavour iis-netfx-x86`
- **THEN** the system boots a Windows Nano Server microVM from the `iis-netfx-x86` image

### Requirement: Hardware-isolated Windows Utility VM execution
Every Windows Nano Server microVM SHALL run with Hyper-V isolation (`--isolation=hyperv`) inside its own dedicated Utility VM with an ephemeral Copy-on-Write scratch layer.

#### Scenario: Separate kernel boundary on Windows
- **WHEN** a Windows microVM is running
- **THEN** the guest runs inside a dedicated Hyper-V Utility VM rather than sharing the host kernel in process-isolation mode

## MODIFIED Requirements

### Requirement: Unique run identity and listing
Every VM SHALL get a unique run id, and the system SHALL list active VMs across the selected guest backend with their id, guest OS/flavour, network mode, resources, start time and state.

#### Scenario: List running VMs
- **WHEN** two VMs are running and the user runs the list command
- **THEN** both are shown with distinct ids and their attributes

#### Scenario: List Windows microVMs
- **WHEN** a Windows microVM is running and the user runs `list -Guest windows`
- **THEN** the Windows microVM is listed with its run id, state, flavour, network mode, vCPU, memory, and start time

### Requirement: Stop and cleanup
The user SHALL be able to stop a VM by id, and a cleanup command SHALL remove every leftover VM process, Hyper-V Utility VM or container, jail directory, disk copy or scratch layer, and network device or firewall rule from previous runs.

#### Scenario: Stop by id
- **WHEN** the user stops a running VM
- **THEN** the VM process, its jail or Utility VM, its disk copy or scratch layer, and its network device no longer exist

#### Scenario: Recover after crash
- **WHEN** the controller was killed mid-run and the user runs cleanup
- **THEN** all orphaned VM resources are removed and listing shows no VMs
