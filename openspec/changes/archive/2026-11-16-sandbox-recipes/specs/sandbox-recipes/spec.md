# Spec Delta

## Purpose

Provides named, ready-to-run security test recipes for Linux microVMs (sandbox self-tests, sample triage and detonation, package install checks, agent tasks), each fixing its own command, image and network mode so a test is one command.

## ADDED Requirements

### Requirement: Recipe definition
A recipe SHALL be a named folder holding a manifest and the recipe's files. The manifest SHALL fix the recipe's kind (`command` or `agent`), its command or prompt, the boot image, the network mode, which inputs it accepts, and its default timeout, vCPUs and memory. A recipe whose manifest is missing, unreadable or has unknown or invalid fields MUST NOT run.

#### Scenario: Invalid manifest
- **WHEN** a recipe's manifest names a network mode other than `isolated` or `networked`
- **THEN** running that recipe exits 125 naming the recipe and the invalid field, and no VM starts

### Requirement: Recipe listing
`fc.ps1 recipe list` SHALL list every installed recipe with its name, description, kind, network mode and accepted inputs, without starting a VM.

#### Scenario: List the starter recipes
- **WHEN** the user runs `fc.ps1 recipe list` after setup
- **THEN** the output lists `probe`, `probe-net`, `agent-escape`, `agent-triage`, `triage-static`, `detonate`, `npm-check` and `pip-check`

### Requirement: Running a recipe
`fc.ps1 recipe <name>` SHALL perform a complete run with the recipe's settings: start a VM, upload the recipe's files and the user's input, execute the recipe, collect results into `runs/<run-id>/` through the guest output airlock and destroy the VM. An unknown recipe name MUST fail with exit code 125 before anything starts.

#### Scenario: Run a recipe
- **WHEN** the user runs `fc.ps1 recipe probe`
- **THEN** one VM boots, the recipe runs, `runs/<run-id>/` holds the usual result files, and no VM remains

#### Scenario: Unknown recipe
- **WHEN** the user runs `fc.ps1 recipe nope`
- **THEN** the command exits 125 naming the available recipes

### Requirement: Recipe settings are fixed
The user SHALL NOT be able to change a recipe's command, image or network mode from the command line. Only the timeout, vCPUs, memory, `-Keep` and, for agent recipes, the agent profile and model SHALL be settable per run. Giving `-Cmd`, `-Payload`, `-Net`, `-Allow` or `-AgentDirect` with `recipe` MUST fail with exit code 125.

#### Scenario: Network mode override refused
- **WHEN** the user runs `fc.ps1 recipe detonate -Sample .\x.bin -Net networked`
- **THEN** the command exits 125 saying the recipe fixes the network mode, and no VM starts

#### Scenario: Longer timeout
- **WHEN** the user runs `fc.ps1 recipe detonate -Sample .\x.bin -Timeout 20m`
- **THEN** the run uses a 20-minute timeout

### Requirement: Sample input
A recipe that accepts a sample SHALL take it as `-Sample <path>`, a host file or folder, and upload it to `/work/in` directly from where it lies, without copying it elsewhere on the host. A recipe that requires a sample MUST fail with exit code 125 before any VM starts when none is given or the path does not exist. Giving a sample to a recipe that accepts none MUST fail the same way.

#### Scenario: Sample from a quarantine folder
- **WHEN** the user runs `fc.ps1 recipe triage-static -Sample C:\quarantine\x.bin`
- **THEN** the guest sees `/work/in/x.bin`, and no copy of the file was created in the repository or a temporary host folder

#### Scenario: Missing sample
- **WHEN** the user runs `fc.ps1 recipe triage-static` without `-Sample`
- **THEN** the command exits 125 saying the recipe needs a sample, and no VM starts

### Requirement: Package input
The package check recipes SHALL accept either `-Sample <path>` (a project folder or package file) or `-Package <spec>` (a package name with an optional version), exactly one of them. A package spec SHALL reach the guest unchanged and MUST be refused with exit code 125 when it contains characters outside those valid in package names and versions.

#### Scenario: Package by name
- **WHEN** the user runs `fc.ps1 recipe npm-check -Package left-pad@1.3.0`
- **THEN** the recipe installs exactly that package version in the guest

#### Scenario: Shell characters in a spec
- **WHEN** the user runs `fc.ps1 recipe npm-check -Package "x; rm -rf /"`
- **THEN** the command exits 125 naming the invalid package spec, and no VM starts

### Requirement: YARA rules input
Recipes that scan with YARA SHALL accept `-Rules <dir>`, a host folder of rule files, and scan the sample with those rules. The system SHALL ship no rules of its own. Without `-Rules` the scan SHALL be skipped and the report SHALL say so.

#### Scenario: Scan with the user's rules
- **WHEN** the user runs `fc.ps1 recipe triage-static -Sample .\x.bin -Rules .\rules` and a rule matches
- **THEN** the report lists the matching rule's name

#### Scenario: No rules
- **WHEN** the user runs `triage-static` without `-Rules`
- **THEN** the report says the YARA scan was skipped because no rules were given

### Requirement: Linux guests only
Recipes SHALL run on Linux guests only. `fc.ps1 recipe <name> -Guest windows` MUST fail with exit code 125 before anything starts.

#### Scenario: Windows guest
- **WHEN** the user runs `fc.ps1 recipe probe -Guest windows`
- **THEN** the command exits 125 saying recipes need Linux guests

### Requirement: Recipe report
Every `command` recipe SHALL write a human-readable `out/report.md` and a machine-readable `out/report.json` that state the recipe, its input, each finding and the limits of the evidence. `meta.json` of every recipe run SHALL record the recipe's name and the name of the sample or package given.

#### Scenario: Report after a run
- **WHEN** a `triage-static` run finishes
- **THEN** `runs/<run-id>/out/report.md` and `report.json` exist and `meta.json` contains `recipe.name: triage-static` and the sample's file name

### Requirement: Recipe exit code
A `command` recipe SHALL exit 0 when it produced its report, whatever the examined sample or install did, and record the sample's or install's own exit code in the report. A self-test recipe SHALL exit 1 when a check found something reachable that is expected to be blocked. An agent recipe SHALL exit with the client's exit code.

#### Scenario: Sample fails, recipe succeeds
- **WHEN** `detonate` runs a sample that exits with code 7
- **THEN** the run exits 0 and the report records exit code 7 for the sample

### Requirement: Sandbox self-test recipes
`probe` (isolated) and `probe-net` (networked) SHALL examine the VM from inside and record, per check, what was expected and what was found: network interfaces, attempts to reach the internet, the WSL host, the Windows host, private address ranges and other microVMs, and the devices and mounts the guest sees. A destination expected to be blocked that answers SHALL fail the run. A destination expected to be open that does not answer SHALL be reported as a warning only.

#### Scenario: Isolated VM holds
- **WHEN** the user runs `fc.ps1 recipe probe` on a correctly set up host
- **THEN** the report shows only the loopback interface, every network attempt failed as expected, and the run exits 0

#### Scenario: Host reachable from a networked VM
- **WHEN** `probe-net` finds that the Windows host answers on a tested port
- **THEN** the report marks that check as failed and the run exits 1

#### Scenario: Internet down
- **WHEN** `probe-net` cannot reach the internet but every blocked destination stays blocked
- **THEN** the report carries a warning for the internet check and the run exits 0

### Requirement: Static triage recipe
`triage-static` SHALL examine a sample in an isolated VM without executing it and report, for each file, its size, SHA-256, detected file type, printable strings, executable headers where the file has them, and YARA matches when rules are given.

#### Scenario: Triage of an ELF binary
- **WHEN** the user runs `triage-static` on a Linux executable
- **THEN** the report gives its SHA-256, identifies it as an ELF executable, and includes its section and dynamic-library information

#### Scenario: Windows executable
- **WHEN** the user runs `triage-static` on a Windows `.exe`
- **THEN** the report identifies it as a PE executable and gives its hash and strings, without running it

### Requirement: Detonation recipe
`detonate` SHALL execute a sample in an isolated VM under system-call tracing, for at most a fixed time, and report the sample's exit code, the processes it started, the files it created or changed and the network connections it attempted. The report SHALL state that a sample can detect tracing and behave differently. A folder sample SHALL need `-Entry <file>` naming the file inside it to execute.

#### Scenario: Folder sample without an entry
- **WHEN** the user runs `fc.ps1 recipe detonate -Sample .\dropper-dir` without `-Entry`
- **THEN** the command exits 125 saying a folder sample needs `-Entry`, and no VM starts

#### Scenario: Detonate a script
- **WHEN** the user detonates a script that writes `/tmp/dropped`, starts `id` and tries to connect to `203.0.113.5:443`
- **THEN** the report lists `/tmp/dropped` among the changed files, `id` among the processes and `203.0.113.5:443` among the connection attempts, and the connection failed

#### Scenario: Sample that does not end
- **WHEN** the sample runs longer than the recipe's detonation time
- **THEN** the recipe stops it, still writes the report with what was traced until then, and says the sample was stopped

### Requirement: Package install check recipes
`npm-check` and `pip-check` SHALL install the given package in a networked VM under system-call tracing and report the install's exit code, the install scripts that ran, the processes they started, the files written outside the install folder and the addresses connected to. The report SHALL state that this evidence is recorded inside the guest and that an install script running as root could alter it.

#### Scenario: Package with an install script
- **WHEN** the user checks a package whose install script starts `sh -c id` and writes `/tmp/marker`
- **THEN** the report names the install script, lists `id` among the processes and `/tmp/marker` among the files written outside the install folder

### Requirement: Agent recipes
An `agent` recipe SHALL run as a headless agent run in gateway mode with the recipe's prompt, and MUST fail with exit code 125 when no agent profile is given. `agent-escape` SHALL ask the agent to look for ways out of the VM and write its findings to `out/report.md`. `agent-triage` SHALL require a sample and ask the agent to examine it with the analysis tools without executing it.

#### Scenario: Agent triage
- **WHEN** the user runs `fc.ps1 recipe agent-triage -Agent claude -Sample .\x.bin`
- **THEN** an agent VM in gateway mode runs with the sample at `/work/in/x.bin`, and the run's results include the agent transcript and `llm.log`

#### Scenario: No profile
- **WHEN** the user runs `fc.ps1 recipe agent-escape` without `-Agent`
- **THEN** the command exits 125 saying the recipe needs an agent profile, and no VM starts

### Requirement: Recipe documentation
The repository SHALL document the `recipe` command, each starter recipe with its input, network mode and report, how to add a recipe, and the limits of the evidence each recipe gives.

#### Scenario: Following the docs
- **WHEN** a user follows the documented command for a starter recipe
- **THEN** the recipe runs as described
