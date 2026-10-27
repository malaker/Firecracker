# microvm-network-modes Specification

## Purpose

Lets each run choose between a microVM with no network at all and one with controlled outbound access, while always protecting the host.

## Requirements

### Requirement: Network mode selection
Each run SHALL use exactly one network mode, `isolated` or `networked`; the default SHALL be `isolated`.

#### Scenario: No mode given
- **WHEN** the user starts a run without choosing a mode
- **THEN** the VM runs in `isolated` mode

### Requirement: Isolated mode has no network
In `isolated` mode the VM SHALL have no network interface other than loopback, while control and file transfer with the host keep working.

#### Scenario: No interfaces
- **WHEN** a VM runs in `isolated` mode
- **THEN** the guest lists only the loopback interface and any outbound connection attempt fails

#### Scenario: Control still works
- **WHEN** a test is run in `isolated` mode
- **THEN** its payload is uploaded and its results are collected successfully

### Requirement: Networked mode outbound access
In `networked` mode the VM SHALL get a private address and NAT-ed outbound access through the host.

#### Scenario: Outbound reachability
- **WHEN** a VM in `networked` mode connects to a public address
- **THEN** the connection succeeds

### Requirement: Host protection
In `networked` mode the VM MUST NOT reach the WSL host, the Windows host, other VMs, or the host's private networks unless they are explicitly allowlisted.

#### Scenario: Attempt to reach host
- **WHEN** the guest connects to the WSL host address, the Windows host address or another VM's address
- **THEN** the connection is dropped

### Requirement: Egress allowlist
The user SHALL be able to restrict `networked` mode egress to a list of destination CIDRs; when an allowlist is given, all other destinations MUST be blocked.

#### Scenario: Allowlisted target
- **WHEN** a run uses an allowlist containing 203.0.113.0/24
- **THEN** connections to 203.0.113.10 succeed and connections to any other address fail

### Requirement: Network teardown
All network devices and firewall rules created for a VM SHALL be removed when the VM is destroyed.

#### Scenario: Rules removed
- **WHEN** a networked VM is stopped
- **THEN** its tap device and its firewall rules no longer exist on the host
