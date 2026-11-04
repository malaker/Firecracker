# Spec Delta

## MODIFIED Requirements

### Requirement: Networked mode outbound access
In `networked` mode a Linux VM SHALL get a private address and NAT-ed outbound access through the host. A Windows VM SHALL get no network adapter and SHALL reach the network only through the host-side egress proxy (TCP over an HTTP proxy, see `windows-egress-proxy`).

#### Scenario: Outbound reachability
- **WHEN** a VM in `networked` mode connects to a public address (for Windows, through the announced HTTP proxy)
- **THEN** the connection succeeds

#### Scenario: Windows networked guest has no adapter
- **WHEN** a Windows VM runs in `networked` mode
- **THEN** the guest lists only the loopback interface

### Requirement: Host protection
In `networked` mode the VM MUST NOT reach the WSL host, the Windows host, other VMs, or the host's private networks unless they are explicitly allowlisted.

#### Scenario: Attempt to reach host
- **WHEN** the guest connects to the WSL host address, the Windows host address or another VM's address
- **THEN** the connection is dropped

#### Scenario: Windows guest attempt to reach Windows host or RFC1918 subnet
- **WHEN** a Windows microVM in `networked` mode requests a connection through the proxy to the Windows host's LAN IP, any of its listening ports, the host's default gateway, or a private RFC1918 address not on the allowlist
- **THEN** the egress proxy refuses the connection and logs it as denied

#### Scenario: Windows host does not enforce the network policy
- **WHEN** a Windows microVM runs in `networked` mode on a host whose HNS NAT networks do not enforce endpoint ACLs (for example Windows 11)
- **THEN** host and LAN protection still holds, because the guest has no network adapter and every connection goes through the egress proxy

#### Scenario: Windows guest bypasses the proxy
- **WHEN** a Windows microVM in `networked` mode tries to connect to any address without using the proxy
- **THEN** the connection fails because the guest has no network adapter

### Requirement: Egress allowlist
The user SHALL be able to restrict `networked` mode egress to a list of destination CIDRs; when an allowlist is given, all other destinations MUST be blocked. On Windows the allowlist SHALL apply to the addresses the proxy resolves for each destination.

#### Scenario: Allowlisted target
- **WHEN** a run uses an allowlist containing 203.0.113.0/24
- **THEN** connections to 203.0.113.10 succeed and connections to any other address fail

#### Scenario: Windows allowlist with a host name
- **WHEN** a Windows run uses an allowlist containing 1.1.1.1/32 and the guest requests `CONNECT one.one.one.one:443`
- **THEN** the proxy resolves the name on the host and connects only if a resolved address is 1.1.1.1

### Requirement: Network teardown
All network devices, firewall rules and egress proxy processes created for a VM SHALL be removed when the VM is destroyed.

#### Scenario: Rules removed
- **WHEN** a networked VM is stopped
- **THEN** its tap device and firewall rules (Linux) or its egress proxy process and relay (Windows) no longer exist on the host

#### Scenario: Watchdog teardown
- **WHEN** a Windows `networked` VM is destroyed by its lifetime watchdog after the controller has exited
- **THEN** its egress proxy process is stopped as well
