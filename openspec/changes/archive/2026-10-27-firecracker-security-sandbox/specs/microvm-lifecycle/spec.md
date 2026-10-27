# Spec Delta

## Purpose

Defines how disposable, jailed Firecracker microVMs are created, tracked, bounded in time and resources, and destroyed.

## ADDED Requirements

### Requirement: Disposable root filesystem
Each microVM SHALL boot from its own copy of the base root filesystem, and changes made inside a VM MUST never reach the base image or any other VM.

#### Scenario: Guest modifies its disk
- **WHEN** a test writes or deletes files in the guest and the VM is destroyed
- **THEN** the next VM boots from an unmodified base image

### Requirement: Jailed execution
Every Firecracker process SHALL run under the jailer, in its own chroot, as an unprivileged user and in its own cgroup.

#### Scenario: Process isolation check
- **WHEN** a microVM is running
- **THEN** its Firecracker process runs as a non-root uid, with its root directory set to a per-VM chroot

### Requirement: Configurable resources
The user SHALL be able to set the vCPU count and memory size per VM; defaults SHALL be 2 vCPUs and 1024 MiB.

#### Scenario: Custom resources
- **WHEN** the user starts a VM with 4 vCPUs and 2048 MiB
- **THEN** the guest reports 4 CPUs and about 2048 MiB of memory

#### Scenario: Invalid resources
- **WHEN** the user requests 0 vCPUs or more memory than the host has free
- **THEN** the VM is not started and the command exits non-zero with a clear message

### Requirement: Unique run identity and listing
Every VM SHALL get a unique run id, and the system SHALL list active VMs with their id, network mode, resources, start time and state.

#### Scenario: List running VMs
- **WHEN** two VMs are running and the user runs the list command
- **THEN** both are shown with distinct ids and their attributes

### Requirement: Hard timeout
Every VM SHALL have a maximum lifetime (default 30 minutes, configurable), after which it is forcibly terminated and cleaned up.

#### Scenario: Timeout reached
- **WHEN** a VM exceeds its timeout
- **THEN** its process is killed, its resources are released, and the run is recorded as timed out

### Requirement: Stop and cleanup
The user SHALL be able to stop a VM by id, and a cleanup command SHALL remove every leftover VM process, jail directory, disk copy and network device from previous runs.

#### Scenario: Stop by id
- **WHEN** the user stops a running VM
- **THEN** the VM process, its jail, its disk copy and its network device no longer exist

#### Scenario: Recover after crash
- **WHEN** the controller was killed mid-run and the user runs cleanup
- **THEN** all orphaned VM resources are removed and listing shows no VMs

### Requirement: Keep for inspection
The user SHALL be able to opt out of automatic destruction so a finished VM's disk is kept for inspection until explicit cleanup.

#### Scenario: Kept run
- **WHEN** a run is started with the keep option and finishes
- **THEN** its disk copy is preserved and the path is printed
