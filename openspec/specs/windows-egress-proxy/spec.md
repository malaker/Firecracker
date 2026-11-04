# windows-egress-proxy Specification

## Purpose

Gives Windows `networked` microVMs controlled outbound TCP access through a host-side egress proxy, while the guest itself has no network adapter, so host and LAN protection never depends on host network policy that may not be enforced.

## Requirements

### Requirement: No guest network adapter
A Windows microVM in `networked` mode SHALL start without any network adapter other than loopback, the same as `isolated` mode. Its only path to the network SHALL be the egress proxy.

#### Scenario: Networked guest has only loopback
- **WHEN** a Windows microVM runs in `networked` mode
- **THEN** the guest lists only the loopback interface, and a direct connection that bypasses the proxy (for example `curl.exe --noproxy "*" https://example.com`) fails

#### Scenario: ICMP is unavailable
- **WHEN** the guest in `networked` mode pings a public address
- **THEN** the ping fails

### Requirement: Proxied TCP egress
A Windows microVM in `networked` mode SHALL reach permitted destinations through an HTTP proxy at a loopback address inside the guest, announced through the `HTTP_PROXY` and `HTTPS_PROXY` environment variables. The proxy SHALL support HTTP `CONNECT` tunnels and absolute-URI HTTP requests.

#### Scenario: HTTPS through the proxy
- **WHEN** a payload in a `networked` Windows guest runs `curl.exe https://example.com` with the announced proxy settings
- **THEN** the request succeeds

#### Scenario: Plain HTTP through the proxy
- **WHEN** a payload requests `http://example.com/` through the proxy
- **THEN** the request succeeds

#### Scenario: Proxy available before any workload
- **WHEN** a `networked` Windows guest's image entrypoint or payload starts
- **THEN** the proxy is already accepting connections inside the guest

### Requirement: Host-side name resolution
The proxy SHALL resolve destination host names on the host and SHALL apply the destination policy to every resolved address before connecting. The guest SHALL NOT need any DNS server.

#### Scenario: Name that resolves to a blocked address
- **WHEN** the guest requests `CONNECT` to a host name that resolves to a private or host address
- **THEN** the proxy refuses the connection and logs the resolved address and the reason

#### Scenario: Name with mixed public and blocked addresses
- **WHEN** a host name resolves to both permitted and blocked addresses
- **THEN** the proxy connects only to a permitted address and never to a blocked one

### Requirement: Always-blocked destinations
The proxy MUST refuse connections to the Windows host's own addresses (every local interface address and loopback), to private, link-local, CGNAT, loopback, multicast and reserved IPv4 ranges, and to all IPv6 destinations, unless an address in a private range is explicitly allowlisted. Host addresses SHALL stay blocked even when allowlisted.

#### Scenario: Host LAN address and listening port
- **WHEN** the guest requests a connection to the host's LAN IP on a port where a host service listens (for example 2179)
- **THEN** the proxy refuses it and the host service receives no connection

#### Scenario: LAN gateway
- **WHEN** the guest requests a connection to the host's default gateway
- **THEN** the proxy refuses it

#### Scenario: IPv6 literal
- **WHEN** the guest requests `CONNECT [2606:4700:4700::1111]:443`
- **THEN** the proxy refuses it

#### Scenario: Allowlisted host address
- **WHEN** the run's allowlist contains the host's own LAN IP and the guest requests a connection to it
- **THEN** the proxy refuses it

### Requirement: Allowlist enforcement
When the run has an allowlist, the proxy SHALL connect only to resolved addresses inside a listed CIDR and SHALL refuse every other destination. Without an allowlist, the proxy SHALL permit public IPv4 destinations that are not always blocked.

#### Scenario: Destination outside the allowlist
- **WHEN** the allowlist is `1.1.1.1/32` and the guest requests `CONNECT 8.8.8.8:443`
- **THEN** the proxy refuses it

#### Scenario: Destination inside the allowlist
- **WHEN** the allowlist is `1.1.1.1/32` and the guest requests `CONNECT 1.1.1.1:443`
- **THEN** the tunnel is established

### Requirement: Unprivileged proxy process
The proxy SHALL run as a separate host process with a restricted token that has no administrator rights, even though the controller runs elevated. If the proxy cannot start that way, the microVM MUST NOT start in `networked` mode.

#### Scenario: Proxy token
- **WHEN** a `networked` Windows microVM is running
- **THEN** its proxy process runs at Medium (or lower) integrity, with the Administrators group deny-only, and without any privilege beyond those of a standard user

#### Scenario: Proxy started with administrator rights
- **WHEN** the proxy process finds its own token has the Administrators group enabled, High or System integrity, or a privilege beyond those of a standard user
- **THEN** it refuses to run, and the microVM does not start in `networked` mode

#### Scenario: Proxy fails to start
- **WHEN** the proxy process cannot be started or does not become ready
- **THEN** the run fails with exit code 125 and the microVM is destroyed before any image entrypoint or payload runs

### Requirement: Relay resource limits
The relay channel between guest and host SHALL enforce fixed limits on frame size, concurrent streams, request-line length, connection setup time and idle time. A guest that violates the framing protocol SHALL have its relay channel closed, while the microVM keeps running.

#### Scenario: Oversized frame
- **WHEN** the guest side sends a frame larger than the maximum frame size
- **THEN** the host closes the relay channel and records a protocol error in the connection log, and the run's other output is still collected

#### Scenario: Too many streams
- **WHEN** the guest opens more concurrent streams than the limit
- **THEN** the extra streams are refused and the existing ones keep working

### Requirement: Connection log
For every `networked` Windows run, the system SHALL write `runs/<run-id>/net.log` with one line per connection attempt: timestamp, requested host and port, resolved address, decision (allowed, denied, or failed when a permitted connection could not be made), reason and bytes transferred.

#### Scenario: Allowed and denied connections logged
- **WHEN** a run makes one allowed and one denied connection
- **THEN** `net.log` contains a line for each with its decision and reason

#### Scenario: Log survives a timeout
- **WHEN** a `networked` run hits its timeout
- **THEN** `net.log` contains the connections made up to that point
