# Spec Delta

## MODIFIED Requirements

### Requirement: Host protection
In `networked` mode the VM MUST NOT reach the WSL host, the Windows host, other VMs, or the host's private networks unless they are explicitly allowlisted.

#### Scenario: Attempt to reach host
- **WHEN** the guest connects to the WSL host address, the Windows host address or another VM's address
- **THEN** the connection is dropped

#### Scenario: Windows guest attempt to reach Windows host or RFC1918 subnet
- **WHEN** a Windows microVM in `networked` mode connects to the HNS gateway, the Windows host IP, or a private RFC1918 address not on the allowlist
- **THEN** the outbound connection is blocked by host firewall or HNS ACL policies

### Requirement: Network teardown
All network devices, HNS endpoints, and firewall or ACL rules created for a VM SHALL be removed when the VM is destroyed.

#### Scenario: Rules removed
- **WHEN** a networked VM is stopped
- **THEN** its tap device or HNS endpoint and its firewall rules no longer exist on the host
