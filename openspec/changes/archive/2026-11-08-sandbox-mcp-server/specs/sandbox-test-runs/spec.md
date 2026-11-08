# Spec Delta

## ADDED Requirements

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
