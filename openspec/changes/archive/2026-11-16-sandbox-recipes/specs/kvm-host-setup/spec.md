# Spec Delta

## MODIFIED Requirements

### Requirement: Agent image and gateway build
Linux setup SHALL build the agent image (from the base image, a pinned and checksum-verified Node.js release, agent clients installed from a committed lockfile with integrity hashes, and analysis tool packages listed in a committed lock file with their checksums) and install the LLM gateway into the controller. Re-running setup SHALL rebuild the agent image only when its inputs changed. `doctor` SHALL report the agent image and the gateway as checks.

#### Scenario: Pinned inputs
- **WHEN** the downloaded Node.js release, an agent package or an analysis tool package does not match its recorded checksum or integrity hash
- **THEN** setup stops with an error naming the file, and the previous agent image is kept

#### Scenario: Re-run without changes
- **WHEN** setup runs again and the agent image inputs did not change
- **THEN** the agent image is not rebuilt

#### Scenario: Doctor checks
- **WHEN** the agent image or the gateway is missing
- **THEN** `doctor` reports that check as failed with a hint to re-run setup, and exits non-zero

#### Scenario: Tool lock file changed
- **WHEN** the analysis tool lock file changes and setup runs again
- **THEN** the agent image is rebuilt with the newly listed packages

## ADDED Requirements

### Requirement: Recipes installed with the controller
Linux setup SHALL install the repository's recipes into the controller and update them when they change. `doctor` SHALL report whether the recipes are installed and whether every manifest is valid. Setup with `-NoAgentImage` SHALL still install the recipes, and running a recipe that needs the missing agent image MUST fail with exit code 125 and a hint to re-run setup.

#### Scenario: Recipe changed in the repository
- **WHEN** a recipe's script is edited and setup runs again
- **THEN** the next run of that recipe uses the edited script

#### Scenario: Invalid manifest reported
- **WHEN** an installed recipe has an invalid manifest
- **THEN** `doctor` reports the recipes check as failed, naming the recipe

#### Scenario: Agent image skipped
- **WHEN** setup ran with `-NoAgentImage` and the user runs `fc.ps1 recipe triage-static -Sample .\x.bin`
- **THEN** the command exits 125 saying the agent image is missing and to re-run setup
