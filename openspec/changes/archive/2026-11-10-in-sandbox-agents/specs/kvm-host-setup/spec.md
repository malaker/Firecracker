# Spec Delta

## ADDED Requirements

### Requirement: Agent image and gateway build
Linux setup SHALL build the agent image (from the base image, a pinned and checksum-verified Node.js release, and agent clients installed from a committed lockfile with integrity hashes) and install the LLM gateway into the controller. Re-running setup SHALL rebuild the agent image only when its inputs changed. `doctor` SHALL report the agent image and the gateway as checks.

#### Scenario: Pinned inputs
- **WHEN** the downloaded Node.js release or an agent package does not match its recorded checksum or integrity hash
- **THEN** setup stops with an error naming the file, and the previous agent image is kept

#### Scenario: Re-run without changes
- **WHEN** setup runs again and the agent image inputs did not change
- **THEN** the agent image is not rebuilt

#### Scenario: Doctor checks
- **WHEN** the agent image or the gateway is missing
- **THEN** `doctor` reports that check as failed with a hint to re-run setup, and exits non-zero
