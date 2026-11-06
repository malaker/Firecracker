# smoke-test-suites Specification

## Purpose

Defines the end-to-end smoke suites for Linux and Windows microVMs: where they run, how they refuse to report results from an unsuitable environment, how the Windows runtime backend under test is selected, and that running them leaves host configuration unchanged.

## Requirements

### Requirement: Linux suite environment check
Before running any check, the Linux smoke suite SHALL verify that it runs on Linux as root with `/dev/kvm`, an executable controller, the installed base image and every host tool its checks use. If any is missing it MUST report no check results, name each missing item, show the documented command for running the suite, and exit 125.

#### Scenario: Run outside the fc-host distro
- **WHEN** the Linux suite is started from Git Bash or another shell on Windows
- **THEN** it prints no `ok` or `FAIL` lines, lists the missing items, shows `wsl -d fc-host -u root -e bash /mnt/c/sources/Firecracker/tests/smoke/all.sh`, and exits 125

#### Scenario: Run as a non-root user
- **WHEN** the Linux suite is started inside `fc-host` without root
- **THEN** it reports that root is required and exits 125 without running checks

#### Scenario: Controller not provisioned
- **WHEN** the controller or base image is not installed in `fc-host`
- **THEN** the suite names the missing path, points to `.\fc.ps1 setup`, and exits 125

#### Scenario: Correct environment
- **WHEN** the Linux suite runs inside a provisioned `fc-host` as root
- **THEN** the environment check passes silently and the checks run as before

### Requirement: Environment check covers every entry point
The environment check SHALL run before any check or controller call, whether the suite is started through `all.sh` or as a single part, and `all.sh` MUST stop at the first environment failure rather than continue with the remaining parts.

#### Scenario: Single part run outside fc-host
- **WHEN** `tests/smoke/net.sh` is run on its own outside `fc-host`
- **THEN** it exits 125 with the same environment report and no check results

#### Scenario: Full suite run outside fc-host
- **WHEN** `tests/smoke/all.sh` is run outside `fc-host`
- **THEN** the environment report appears once, no part runs, and the suite exits 125

### Requirement: Windows suite runtime selection
The Windows smoke suite SHALL accept `-WinRuntime docker|containerd`, defaulting to `docker`, and run every part against the selected backend.

#### Scenario: Default runtime
- **WHEN** the Windows suite is run without `-WinRuntime`
- **THEN** every part runs on the `docker` backend, as before

#### Scenario: containerd runtime
- **WHEN** the Windows suite is run with `-WinRuntime containerd`
- **THEN** setup, doctor and every microVM the suite starts use the `containerd` backend, and each run's `meta.json` records `win_runtime` as `containerd`

#### Scenario: Unsupported feature on the selected runtime
- **WHEN** a part tests a feature declared unsupported on the selected backend
- **THEN** the suite prints that the part is skipped and why, verifies that the feature is refused with exit 125, and does not count the part as failed

### Requirement: Windows suite preserves host configuration
Running the Windows smoke suite SHALL leave the host's configured default runtime, image repository and flavour as they were before the run, whether the run passes, fails or is interrupted.

#### Scenario: containerd run on a docker host
- **WHEN** the host's default runtime is `docker` and the suite is run with `-WinRuntime containerd`
- **THEN** after the suite finishes the default runtime is still `docker`

#### Scenario: Failed run
- **WHEN** a part of the Windows suite fails
- **THEN** the default runtime, image repository and flavour are restored before the suite exits non-zero
