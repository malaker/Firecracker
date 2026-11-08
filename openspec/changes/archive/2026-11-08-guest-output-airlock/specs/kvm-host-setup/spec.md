# Spec Delta

## ADDED Requirements

### Requirement: Airlock tooling for Linux guests
Linux setup SHALL build the airlock tool for `linux-x64` with the .NET 10 SDK and install it into the controller. When no .NET 10 SDK is found, setup MUST fail with a message naming the SDK and how to install it. Re-running setup SHALL rebuild the tool only when its sources changed. `doctor` SHALL report the tool's presence as a check.

#### Scenario: SDK missing
- **WHEN** the user runs `fc.ps1 setup` on a machine without a .NET 10 SDK
- **THEN** setup exits non-zero with a message naming the .NET 10 SDK

#### Scenario: Doctor check
- **WHEN** the airlock tool is missing from the controller
- **THEN** `doctor` reports the airlock check as failed with a hint to re-run setup, and exits non-zero
