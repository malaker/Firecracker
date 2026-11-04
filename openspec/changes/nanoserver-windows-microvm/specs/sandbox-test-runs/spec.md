# Spec Delta

## MODIFIED Requirements

### Requirement: Payload upload
The payload folder SHALL be copied or mapped into the guest at a fixed path (`/work/in` on Linux guests, `C:\work\in` on Windows guests) before the command runs, and the command SHALL run with `/work` (Linux) or `C:\work` (Windows) as its working directory.

#### Scenario: Files available in guest
- **WHEN** the payload folder contains `scan.sh`
- **THEN** the guest command can run `./in/scan.sh`

#### Scenario: Files available in Windows guest
- **WHEN** the payload folder contains `hello.cmd` and the user runs with `-Guest windows`
- **THEN** the Windows guest command runs in `C:\work` and can execute `.\in\hello.cmd`

### Requirement: Result collection
For every run the system SHALL save the exit code, stdout, stderr, run metadata (id, guest OS, flavour/image, runtime backend, mode, resources, timings, timeout status), and the contents of the guest output folder (`/work/out` on Linux, `C:\work\out` on Windows), into `runs/<run-id>/` in the project folder on Windows.

#### Scenario: Results on Windows
- **WHEN** a run finishes
- **THEN** `runs/<run-id>/` contains `exit_code`, `stdout.log`, `stderr.log`, `meta.json` and an `out/` folder

#### Scenario: Results after timeout
- **WHEN** a run hits its timeout
- **THEN** whatever output was produced up to that point is saved and `meta.json` records the timeout

#### Scenario: Windows guest results and metadata
- **WHEN** a Windows microVM run writes files to `C:\work\out` and finishes
- **THEN** `runs/<run-id>/out/` contains those files and `meta.json` records `guest: "windows"`, the selected `flavour`, `image_repo`, and `win_runtime`

### Requirement: Interactive shell
The system SHALL provide a shell command that starts a VM in the chosen guest OS and network mode and opens an interactive shell in it (`bash` on Linux, `cmd.exe` on Windows), destroying the VM when the shell exits.

#### Scenario: Shell session
- **WHEN** the user opens a shell and then exits it
- **THEN** the user had a root shell in the guest, and afterwards the VM no longer exists

#### Scenario: Windows shell session
- **WHEN** the user runs `shell -Guest windows` and exits the prompt
- **THEN** the user gets an interactive `ContainerAdministrator` shell in `C:\work`, and the Windows microVM is destroyed on exit
