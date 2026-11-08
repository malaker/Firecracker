# Spec Delta

## MODIFIED Requirements

### Requirement: Unique run identity and listing
Every VM SHALL get a unique run id, and the system SHALL list active VMs across the selected guest backend with their id, guest OS/flavour, network mode, resources, start time and state. Airlock VMs SHALL be listed with their role shown as `airlock` and the run id of the VM whose files they are transferring.

#### Scenario: List running VMs
- **WHEN** two VMs are running and the user runs the list command
- **THEN** both are shown with distinct ids and their attributes

#### Scenario: List Windows microVMs
- **WHEN** a Windows microVM is running and the user runs `list -Guest windows`
- **THEN** the Windows microVM is listed with its run id, state, flavour, network mode, vCPU, memory, and start time

#### Scenario: List during a collection
- **WHEN** the user runs the list command while a run's output is being collected
- **THEN** the airlock VM is listed with role `airlock` and the source run's id

### Requirement: Stop and cleanup
The user SHALL be able to stop a VM by id, and a cleanup command SHALL remove every leftover VM process, Hyper-V Utility VM or container, jail directory, disk copy or scratch layer, and network device or firewall rule from previous runs, including airlock VMs, their leftover host-side reader processes and transfer staging folders.

#### Scenario: Stop by id
- **WHEN** the user stops a running VM
- **THEN** the VM process, its jail or Utility VM, its disk copy or scratch layer, and its network device no longer exist

#### Scenario: Recover after crash
- **WHEN** the controller was killed mid-run and the user runs cleanup
- **THEN** all orphaned VM resources are removed and listing shows no VMs

#### Scenario: Recover after a crash during collection
- **WHEN** the controller was killed while an airlock was running and the user runs cleanup
- **THEN** the airlock VM, any reader process and the staging folder are removed, and listing shows no VMs
