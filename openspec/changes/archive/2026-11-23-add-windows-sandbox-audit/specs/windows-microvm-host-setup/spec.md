# Spec Delta

## ADDED Requirements

### Requirement: Audit tooling for Windows guests
Windows setup SHALL build the audit report tool for `win-x64` with the .NET 10 SDK into a folder that only administrators can modify, and SHALL rebuild it only when its sources changed. `doctor -Guest windows` SHALL report whether the tool is present. Running `audit` without the tool MUST exit 125 with a hint to re-run setup.

#### Scenario: Built by setup
- **WHEN** Windows setup runs on a host with the .NET 10 SDK
- **THEN** the audit report tool is installed under the administrator-only tools folder, and `doctor -Guest windows` reports it as passed

#### Scenario: Re-run without changes
- **WHEN** setup runs again and the tool's sources did not change
- **THEN** the tool is not rebuilt

#### Scenario: Tool missing
- **WHEN** the audit report tool is missing and the user runs `fc.ps1 audit -Guest windows`
- **THEN** the command exits 125 before starting a VM, with a hint to re-run `fc.ps1 setup -Guest windows`, and `doctor -Guest windows` reports the check as failed
