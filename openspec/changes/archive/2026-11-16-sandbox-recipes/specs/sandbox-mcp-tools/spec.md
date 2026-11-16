# Spec Delta

## ADDED Requirements

### Requirement: Recipe listing tool
The server SHALL provide `sandbox_recipes`, which lists the installed recipes with their name, description, kind, network mode and accepted inputs, without starting a VM.

#### Scenario: List recipes
- **WHEN** the agent calls `sandbox_recipes`
- **THEN** the result lists the eight starter recipes with their network modes and inputs

### Requirement: Recipe run tool
The server SHALL provide `sandbox_recipe`, which runs one recipe by name with an optional sample path, package spec, rules folder, entry, agent profile, model, timeout, vCPUs and memory. It SHALL return the same fields as `sandbox_run` plus the recipe name and the report paths, with guest output bounded and marked as untrusted. The caller SHALL NOT be able to change a recipe's command, image or network mode.

#### Scenario: Host agent runs a self-test
- **WHEN** the agent calls `sandbox_recipe` with `name: "probe"`
- **THEN** the recipe runs in an isolated VM and the result has the exit code, the output files and the path of `report.md`

#### Scenario: Networked recipe without opt-in
- **WHEN** the server was launched without enabling networked mode and the agent calls `sandbox_recipe` with `name: "npm-check"`
- **THEN** the call fails with an error saying networked mode is disabled for this server, and no VM starts

#### Scenario: Agent recipe
- **WHEN** the agent calls `sandbox_recipe` with `name: "agent-triage"`, `agent: "claude"` and a sample inside the allowed roots
- **THEN** the recipe runs in gateway mode and the result lists the transcript and `llm.log` paths

#### Scenario: Unknown recipe
- **WHEN** the agent calls `sandbox_recipe` with a name that is not installed
- **THEN** the call fails with an error naming the available recipes, and no VM starts

## MODIFIED Requirements

### Requirement: Host path confinement
Host paths given to `sandbox_run`, `sandbox_put` and `sandbox_recipe` (sample and rules folder) MUST resolve, after following links and junctions, to a location inside one of the server's allowed roots (by default the working directory the server was started in; configurable at launch). A source tree that contains links or junctions MUST be refused.

#### Scenario: Path outside the allowed roots
- **WHEN** the agent calls `sandbox_put` with `C:\Users\<user>\.ssh` and the allowed root is the project folder
- **THEN** the call fails with an error naming the allowed roots, and nothing is copied

#### Scenario: Junction escaping the root
- **WHEN** a payload folder inside the allowed root contains a junction pointing outside it
- **THEN** the call fails and nothing is copied

#### Scenario: Recipe sample outside the allowed roots
- **WHEN** the agent calls `sandbox_recipe` with a sample path outside the allowed roots
- **THEN** the call fails with an error naming the allowed roots, and no VM starts

### Requirement: No host-side actions
The server SHALL expose only sandbox tools. No tool SHALL run a command on the host, read a host file other than a payload being uploaded, or write a host file outside `runs/`.

#### Scenario: Tool inventory
- **WHEN** the client lists the server's tools
- **THEN** the only tools are `sandbox_run`, `sandbox_start`, `sandbox_exec`, `sandbox_put`, `sandbox_get`, `sandbox_list`, `sandbox_stop`, `sandbox_recipes` and `sandbox_recipe`
