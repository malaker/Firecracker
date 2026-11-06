# Proposal

## Why

The Windows `containerd` backend (`-WinRuntime containerd`: containerd 1.7.25, nerdctl 2.0.3, runhcs) is offered by setup, doctor and every controller command, but it has never been run end to end. The smoke suite hardcodes `-WinRuntime docker`, so the backend could be broken without anyone knowing. Separately, the Linux smoke suite (`tests/smoke/*.sh`) has no environment check. Run from Git Bash on Windows instead of inside `fc-host`, it printed about 20 `ok` lines with no VM, controller or tools present: negative checks ("guest cannot reach the host", "no leftovers", "base image unchanged") pass trivially when nothing exists. A test run that can pass without testing anything is worse than no test run.

## What Changes

- The Linux smoke suite checks its environment once before running any check: Linux, root, `/dev/kvm`, an executable controller at `$FCCTL`, the installed base image, and the tools the checks rely on on the host (`jq`, `ip`, `nft`, `pgrep`, `socat`, `sha256sum`, `timeout`, `awk`). If anything is missing it prints what is missing, how to run the suite correctly, and exits 125 without reporting any check results. This applies to `all.sh` and to each part run on its own.
- `all.sh` stops at the first environment failure instead of running all six parts, and no longer calls the controller before the check.
- The Windows smoke suite gains a `-WinRuntime docker|containerd` parameter (default `docker`) and runs every part against the selected backend. It restores the host's configured default runtime afterwards, so testing `containerd` does not switch the host away from `docker`.
- The `containerd` backend is installed on this workstation and run through the full Windows suite. Bugs found are fixed.
- Any feature that cannot reasonably work on `containerd` (for example `-BuildFromSource`, since nerdctl builds need BuildKit, which has no supported Windows container builder) is declared unsupported: commands that need it fail at once with exit 125 and a clear message naming `-WinRuntime docker`, before a microVM is started. Doctor and the README list the limitations, and the suite skips those parts on `containerd`, saying so.
- `cleanup -Guest windows` clears leftovers for both runtimes (today its network-policy cleanup only looks at `docker`).

## Capabilities

### New Capabilities
- `smoke-test-suites`: The end-to-end smoke suites for Linux and Windows microVMs: where and how they run, refusing to report results from the wrong environment, selecting the Windows runtime backend under test, and leaving host configuration unchanged.

### Modified Capabilities
- `windows-microvm-host-setup`: The selectable runtime backend requirement gains verified behavior for `containerd`, including how unsupported features are reported. Doctor reports `containerd` limitations.

## Impact

- `tests/smoke/lib.sh`, `tests/smoke/all.sh`; `README.md` (smoke test instructions, `containerd` limitations).
- `tests/smoke-win/all.ps1` and the parts it runs (`net-isolated.ps1`, `lifecycle.ps1`, `net-protect.ps1`).
- Likely fixes in `windows/lib/runtime.ps1`, `windows/lib/net.ps1`, `windows/fcctl-win.ps1`, `windows/lib/doctor.ps1`, `windows/setup-nanoserver.ps1`, depending on what the `containerd` run finds.
- Host impact on this workstation: installs and registers the `containerd` service alongside `docker` and pulls a second copy of `malaker/nanoserver:aspnet-x86` (several GB) into containerd's image store. Neither replaces the Docker setup.
- No behavior change for users on the default `docker` runtime or for Linux microVMs.
