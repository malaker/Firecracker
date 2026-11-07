# Spec Delta

## ADDED Requirements

### Requirement: Airlock tooling for Windows guests
Windows setup SHALL build the airlock tool for `win-x64` with the .NET 10 SDK into a folder that only administrators can modify. When no .NET 10 SDK is found, setup MUST fail with a message naming the SDK and how to install it. Re-running setup SHALL rebuild the tool only when its sources changed. `doctor -Guest windows` SHALL report the tool's presence as a check.

#### Scenario: SDK missing
- **WHEN** the user runs `fc.ps1 setup -Guest windows` on a machine without a .NET 10 SDK
- **THEN** setup exits non-zero with a message naming the .NET 10 SDK

#### Scenario: Doctor check
- **WHEN** the airlock tool is missing
- **THEN** `doctor -Guest windows` reports the airlock check as failed with a hint to re-run setup, and exits non-zero
