# Spec Delta

## MODIFIED Requirements

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
