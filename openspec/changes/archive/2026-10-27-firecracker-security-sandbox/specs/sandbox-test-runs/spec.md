# Spec Delta

## Purpose

Defines the end-to-end workflow for running a security test inside a disposable microVM and getting its results back on Windows.

## ADDED Requirements

### Requirement: One-command test run
The system SHALL provide a run command that, in one step, starts a VM, uploads a local payload folder, executes a given command in the guest, collects the results and destroys the VM.

#### Scenario: Successful run
- **WHEN** the user runs a test with a payload folder and a command
- **THEN** the command executes in a fresh VM, results are collected, and the VM is destroyed

### Requirement: Payload upload
The payload folder SHALL be copied into the guest at a fixed path (`/work/in`) before the command runs, and the command SHALL run with `/work` as its working directory.

#### Scenario: Files available in guest
- **WHEN** the payload folder contains `scan.sh`
- **THEN** the guest command can run `./in/scan.sh`

### Requirement: Result collection
For every run the system SHALL save the exit code, stdout, stderr, run metadata (id, mode, resources, timings, timeout status), and the contents of the guest folder `/work/out`, into `runs/<run-id>/` in the project folder on Windows.

#### Scenario: Results on Windows
- **WHEN** a run finishes
- **THEN** `runs/<run-id>/` contains `exit_code`, `stdout.log`, `stderr.log`, `meta.json` and an `out/` folder

#### Scenario: Results after timeout
- **WHEN** a run hits its timeout
- **THEN** whatever output was produced up to that point is saved and `meta.json` records the timeout

### Requirement: Exit code propagation
The run command SHALL exit with the guest command's exit code, or with a distinct non-zero code when the run failed for infrastructure reasons or timed out.

#### Scenario: Failing test
- **WHEN** the guest command exits with code 3
- **THEN** the run command exits with code 3

### Requirement: Interactive shell
The system SHALL provide a shell command that starts a VM in the chosen network mode and opens an interactive shell in it, destroying the VM when the shell exits.

#### Scenario: Shell session
- **WHEN** the user opens a shell and then exits it
- **THEN** the user had a root shell in the guest, and afterwards the VM no longer exists

### Requirement: Usage documentation
The repository SHALL include documentation that covers setup, every command and option, the network modes, result layout and known limitations.

#### Scenario: Following the docs
- **WHEN** a new user follows the documented quick-start on this PC
- **THEN** they complete a first isolated test run without other instructions
