# Spec Delta

## MODIFIED Requirements

### Requirement: Agent image
Agent VMs SHALL boot from a separate agent image that contains the base image plus pinned versions of Node.js and the agent clients, the analysis tools used by recipes (`file`, `strings`, `readelf`, `objdump`, `yara`, `pip` and `npm`), and a guest-side shim from `127.0.0.1:8080` to the gateway's vsock port. VMs without `-Agent` SHALL keep booting from the unchanged base image, except recipe runs whose recipe selects the agent image. Agent runs SHALL need no network access to install anything at run time.

#### Scenario: Clients present
- **WHEN** an agent VM boots
- **THEN** `claude --version` and `codex --version` report the pinned versions

#### Scenario: Ordinary runs unchanged
- **WHEN** the user runs `fc.ps1 run` without `-Agent`
- **THEN** the VM boots from the base image as before

#### Scenario: Analysis tools present
- **WHEN** an agent VM boots
- **THEN** `file`, `strings`, `readelf`, `objdump`, `yara`, `pip` and `npm` each run and report a version

#### Scenario: Recipe without an agent
- **WHEN** the user runs a `command` recipe that selects the agent image
- **THEN** the VM boots from the agent image with no gateway and no API key involved
