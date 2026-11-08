# sandbox-test-runs Specification

## Purpose

Defines the end-to-end workflow for running a security test inside a disposable microVM and getting its results back on Windows.

## Requirements

### Requirement: One-command test run
The system SHALL provide a run command that, in one step, starts a VM, uploads a local payload folder, executes a given command in the guest, collects the results and destroys the VM.

#### Scenario: Successful run
- **WHEN** the user runs a test with a payload folder and a command
- **THEN** the command executes in a fresh VM, results are collected, and the VM is destroyed

### Requirement: Payload upload
The payload folder SHALL be copied or mapped into the guest at a fixed path (`/work/in` on Linux guests, `C:\work\in` on Windows guests) before the command runs, and the command SHALL run with `/work` (Linux) or `C:\work` (Windows) as its working directory.

#### Scenario: Files available in guest
- **WHEN** the payload folder contains `scan.sh`
- **THEN** the guest command can run `./in/scan.sh`

#### Scenario: Files available in Windows guest
- **WHEN** the payload folder contains `hello.cmd` and the user runs with `-Guest windows`
- **THEN** the Windows guest command runs in `C:\work` and can execute `.\in\hello.cmd`

### Requirement: Result collection
For every run the system SHALL save the exit code, stdout, stderr, run metadata (id, guest OS, flavour/image, runtime backend, mode, resources, timings, timeout status), and the contents of the guest output folder (`/work/out` on Linux, `C:\work\out` on Windows), into `runs/<run-id>/` in the project folder on Windows. The output folder's contents SHALL be collected through the guest output airlock (see `guest-output-airlock`), and the collection outcome SHALL be recorded in `meta.json`. A refused or failed collection SHALL leave `out/` empty and SHALL NOT change the run's exit code.

#### Scenario: Results on Windows
- **WHEN** a run finishes
- **THEN** `runs/<run-id>/` contains `exit_code`, `stdout.log`, `stderr.log`, `meta.json` and an `out/` folder

#### Scenario: Results after timeout
- **WHEN** a run hits its timeout
- **THEN** whatever output was produced up to that point is saved and `meta.json` records the timeout

#### Scenario: Windows guest results and metadata
- **WHEN** a Windows microVM run writes files to `C:\work\out` and finishes
- **THEN** `runs/<run-id>/out/` contains those files and `meta.json` records `guest: "windows"`, the selected `flavour`, `image_repo`, and `win_runtime`

#### Scenario: Refused output keeps the guest exit code
- **WHEN** a guest command writes a symbolic link into its output folder and exits with code 0
- **THEN** the run exits with code 0, `out/` is empty, `meta.json` records `collection.status` as `refused`, and an error naming the link is printed

### Requirement: Exit code propagation
The run command SHALL exit with the guest command's exit code, or with a distinct non-zero code when the run failed for infrastructure reasons or timed out.

#### Scenario: Failing test
- **WHEN** the guest command exits with code 3
- **THEN** the run command exits with code 3

### Requirement: Interactive shell
The system SHALL provide a shell command that starts a VM in the chosen guest OS and network mode and opens an interactive shell in it (`bash` on Linux, `cmd.exe` on Windows), destroying the VM when the shell exits.

#### Scenario: Shell session
- **WHEN** the user opens a shell and then exits it
- **THEN** the user had a root shell in the guest, and afterwards the VM no longer exists

#### Scenario: Windows shell session
- **WHEN** the user runs `shell -Guest windows` and exits the prompt
- **THEN** the user gets an interactive `ContainerAdministrator` shell in `C:\work`, and the Windows microVM is destroyed on exit

### Requirement: Usage documentation
The repository SHALL include documentation that covers setup, every command and option, the network modes, result layout and known limitations.

#### Scenario: Following the docs
- **WHEN** a new user follows the documented quick-start on this PC
- **THEN** they complete a first isolated test run without other instructions

### Requirement: Copy files into a started VM
The system SHALL provide a `put` command that copies a host file or folder into a running VM started with `start`, on both guest backends. The default destination SHALL be `/work/in` on Linux guests and `C:\work\in` on Windows guests; another guest folder MAY be given. Files SHALL be transferred over the existing control channel, never through a mounted host folder.

#### Scenario: Put a file into a Linux VM
- **WHEN** the user runs `put <run-id> .\sample.bin` against a started Linux VM
- **THEN** `/work/in/sample.bin` exists in the guest with the same content

#### Scenario: Put a folder into a Windows VM
- **WHEN** the user runs `put <run-id> .\tools -Guest windows -Dest C:\work\tools` against a started Windows VM
- **THEN** the folder's contents exist under `C:\work\tools` in the guest

#### Scenario: VM not running
- **WHEN** the user runs `put` with a run id that is not a running VM
- **THEN** the command exits with the infrastructure-failure exit code and copies nothing

### Requirement: Copy files out of a started VM
The system SHALL provide a `get` command that copies a guest file or folder out of a running VM started with `start`, on both guest backends, into a host folder (default `runs/<run-id>/files/`).

#### Scenario: Get a folder from a Linux VM
- **WHEN** the guest has written `/work/out/report.txt` and the user runs `get <run-id> /work/out`
- **THEN** `runs/<run-id>/files/` contains `report.txt`

#### Scenario: Missing guest path
- **WHEN** the user runs `get` with a guest path that does not exist
- **THEN** the command exits non-zero with an error naming the path

### Requirement: Guest files leave only through the airlock
`get` SHALL transfer guest files to the host only through the guest output airlock (see `guest-output-airlock`); the host MUST NOT unpack a guest-produced archive itself. When the airlock refuses the transfer, `get` SHALL exit non-zero, report the reason and write none of the guest's files.

#### Scenario: Guest returns a link
- **WHEN** a guest folder being copied out contains a symbolic link pointing at `/etc` or `C:\Windows`
- **THEN** `get` fails with an error naming the refused entry and writes no files

#### Scenario: Successful get uses an airlock
- **WHEN** `get` copies `/work/out` from a started VM
- **THEN** a separate airlock VM is started for the transfer and no longer exists once `get` returns
