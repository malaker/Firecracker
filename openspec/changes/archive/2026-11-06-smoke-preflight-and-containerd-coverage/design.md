# Design

## Context

See proposal.md (Why) for motivation and `specs/` for the required behavior.

**Linux suite.** Each part (`boot`, `resources`, `lifecycle`, `net`, `run`, `timeout`) sources `tests/smoke/lib.sh`, which sets `FCCTL`, creates a results temp dir with `mktemp` as soon as it is sourced, and defines `expect`/`not`/`no_leftovers`. `all.sh` calls `/opt/fc-sandbox/bin/fcctl cleanup` *before* sourcing `lib.sh`, then runs each part. Nothing checks the environment. The host tools the checks use are `jq`, `ip`, `nft`, `pgrep`, `socat`, `sha256sum`, `timeout` and `awk`. `curl` runs only inside the guest.

**Windows suite.** `all.ps1` runs `setup -Guest windows -WinRuntime docker`, then `doctor -Boot`, `net-isolated.ps1`, an exit-code check, `lifecycle.ps1`, `net-protect.ps1` and a final cleanup. The parts never pass `-WinRuntime`; they inherit `win_runtime` from `C:\ProgramData\fc-sandbox-win\config.json`, which `setup` overwrites (`Save-FcWinConfig`).

**containerd backend.** Already wired through `Get-FcCli` (`nerdctl.exe` instead of `docker.exe`) everywhere: `run -d -i --isolation=hyperv --cpus --memory -u --network=none --entrypoint cmd.exe`, `exec` with piped stdin/stdout for tar transfer and the egress relay, `inspect --format '{{.State.Running}}'`, `image inspect --format '{{json .Config.Entrypoint}}'`. `-BuildFromSource` is already refused on `containerd` (in `setup-nanoserver.ps1` and `Invoke-FcWinImageBuild`), but with exit code 1. `cleanup` handles orphan containers for both runtimes, but `Clear-AllFcWinNetworkPolicies` defaults to `docker`. containerd is not installed on this workstation; Docker 27.5.1 is, and it drives HCS directly (not through containerd), so the two can run side by side.

## Goals / Non-Goals

**Goals:**
- A wrong-environment run of the Linux suite is impossible to mistake for a result.
- A single command proves whether the `containerd` backend works, and repeats the proof later.
- Every `containerd` limitation is enforced in one place and reported identically by the controller, doctor and README.

**Non-Goals:**
- Fixing `nerdctl`, `containerd` or `hcsshim` upstream, or replacing `nerdctl` with another client (`ctr`, the containerd API) to work around a limitation.
- Making `containerd` the default runtime or promoting it from "experimental".
- Running the Windows suite in CI or making it non-elevated.
- Changing the checks themselves beyond what the environment check and runtime selection need.

## Decisions

**D1: Capability checks in `lib.sh`, not a distro-name check.**
`lib.sh` runs a preflight function as the first thing when sourced, before `mktemp`. It checks: `uname -s` is `Linux`; `id -u` is 0; `/dev/kvm` is a read/write character device; `$FCCTL` is executable; `/opt/fc-sandbox/images/rootfs.ext4` exists; each host tool resolves with `command -v`. It collects *all* missing items, prints them with the documented command and a pointer to `.\fc.ps1 setup`, and `exit 125`.
Alternative: check `WSL_DISTRO_NAME == fc-host`. Rejected: it isn't reliably set under `wsl -e`, and a correctly provisioned host under another name should still pass. Checking what the checks need is what actually prevents vacuous passes.

**D2: `all.sh` sources `lib.sh` first and stops on 125.**
`all.sh` sources `lib.sh` before its first `fcctl cleanup`, so the preflight runs once up front. If a part exits 125 (its own preflight failed, e.g. a tool vanished), `all.sh` stops and exits 125 instead of running the rest. Each part still runs the preflight when started alone, which is cheap (a few `command -v` calls).

**D3: Windows runtime passed explicitly *and* config restored.**
`all.ps1`, `net-isolated.ps1`, `lifecycle.ps1` and `net-protect.ps1` take `-WinRuntime` (default `docker`), and `all.ps1` passes it to every part and to every `fc.ps1` call. This makes each command's backend unambiguous in the output. Separately, `all.ps1` copies `config.json` before `setup` and puts it back in its `finally` block, because `setup` rewrites the default as a side effect.
Alternative: rely on `setup` to switch the default and switch it back at the end. Rejected: a part started on its own would test whichever runtime was last set up.

**D4: One table of containerd limitations.**
`windows/lib/common.ps1` gets a single table mapping each unsupported feature (key, human description) to the runtime(s) it is unsupported on, plus an `Assert-FcWinFeatureSupported` helper that exits 125 with the standard message. `setup-nanoserver.ps1` (for `-BuildFromSource`) and `fcctl-win.ps1` (before `Start-NewFcWinVm`, for features such as `-Net networked`) call it; `doctor` prints the table's entries for the active runtime. The README section is written from the same list, and the suite reads the table to decide which parts to skip and to assert the refusal.
`-BuildFromSource` moves onto this table, changing its exit code from 1 to 125 to match the spec.
Alternative: per-call-site `if ($WinRuntime -eq 'containerd')` checks. Rejected: the three outputs (error, doctor, README) would drift apart.

**D5: Find containerd gaps by running, then triage.**
Install containerd with `setup -WinRuntime containerd`, then run `doctor -Boot` and each suite part on its own with `-WinRuntime containerd`, fixing as you go. Each failure is classified:
- **Fixable**: a wrong flag, output-format difference, process-name or service assumption in our scripts. Fix it so both runtimes work.
- **Limitation**: needs an upstream `nerdctl`/`containerd`/`hcsshim` change or a different client (see Non-Goals). Add it to the D4 table.
Each limitation found gets a one-line rationale in this design (under Risks) when the change is applied, so the decision is recorded.

**D6: `cleanup` covers both runtimes.**
`Clear-AllFcWinNetworkPolicies` runs once per runtime whose CLI is installed, matching the existing orphan-container loop, and skips a runtime that isn't installed instead of failing.

## Risks / Trade-offs

- [The likeliest gaps in `nerdctl` 2.0.3 on Windows: `run -d -i` keeping stdin open, `exec -i` streaming binary stdin (tar upload, egress relay), `--memory`/`--cpus` with Hyper-V isolation, and `--network=none` without CNI configuration.] → These are the first things `doctor -Boot` and `net-isolated.ps1` exercise, so they surface early. Each is triaged under D5.
- [If `exec` cannot stream stdin, file upload fails, and with it every `run`, which would leave little of the backend usable.] → That is a limitation under D5 (all payload commands refused on `containerd`). The suite still passes by asserting the refusals, and README states plainly that `containerd` only supports what remains. Whether to keep a backend that limited is a follow-up decision, not part of this change.

**Findings from the containerd bring-up (D5).** Binary stdin/stdout over `nerdctl exec`, `--network=none`, `-u`, `--entrypoint`, image inspect, the egress relay and every suite part work. Three gaps were fixable, so only `-BuildFromSource` remains a limitation:
- Fixed: nerdctl rejects `run -d -i` (`-i and -d cannot be specified together`). Without `-i`, `cmd /K` exits on closed stdin, so the containerd guest's init process is `cmd /S /C "ping -t 127.0.0.1 >nul"`, which never exits. Docker keeps `-d -i ... cmd /K`.
- Fixed: `--memory` (any size) makes HCS refuse to create the Utility VM (`hcs::CreateComputeSystem ...@vm: winapi error #2147749931`). The containerd Utility VM is sized with hcsshim's `io.microsoft.virtualmachine.computetopology.memory.sizeinmb` and `.processor.count` annotations instead of `--memory`/`--cpus`.
- Fixed: `nerdctl exec` exits 1 for every non-zero guest exit code and reports the real one only as its own last stderr line (`exec failed with exit code N`). The controller reads N from that line and removes it from `stderr.log`; a guest calling `exit N` is covered too, which a guest-side exit-code file would not be.
- Limitation (unchanged): `-BuildFromSource`; nerdctl builds need BuildKit, which has no supported Windows container builder.
- Not a code gap: setup can only pull published images. Images built locally with `-BuildFromSource` exist only in Docker's store and are copied into containerd by hand (`docker save` / `nerdctl load`), as the README documents. That is how this workstation's `malaker/nanoserver` images reached containerd.
- [A second Nano Server image copy in containerd's store costs several GB of disk.] → 2.5 TB is free here; the README notes the cost.
- [Two runtimes contending for HCS could interfere, e.g. `cleanup` on one removing the other's state.] → All names are prefixed `fc-win-` and per-runtime; the `docker` suite is re-run after the `containerd` work to confirm nothing regressed.
- [An interrupted Windows suite (Ctrl+C) could skip restoring `config.json`.] → The restore is in `finally`, which PowerShell runs on Ctrl+C (verified: interrupting during `lifecycle.ps1` restored the file byte-identical and left no microVMs, containers or `fc-egress`). The restore runs before the cleanup call in `finally`, so a second Ctrl+C or a slow cleanup cannot skip it. Ctrl+C kills the part's `fc.ps1` child at once, and the whole `finally` block runs (checked with a real console Ctrl+C). Interrupting `lifecycle.ps1` during `start` has still left a microVM behind even though the final cleanup was launched, while `cleanup` run afterwards removes it; the cause is open. `finally` therefore reports the cleanup's exit code and output when it fails rather than discarding them. A hard kill of the process is not covered and the README says to re-run `setup` to reset the default.
- [Known cosmetic gap, deferred: on `containerd`, nerdctl's `level=fatal msg="exec failed with exit code N"` line still appears on the console while `run` streams guest output.] → Exit codes and the saved `stderr.log` are correct. Hiding the line live would mean holding back the last stderr line in the streaming helper every `run` goes through, which is out of proportion to the issue; left as a follow-up.
- [The preflight could reject a legitimate environment, e.g. a tool installed under a different name.] → The preflight only lists tools the checks call by that exact name, so if they are missing the checks would fail anyway.

## Migration Plan

1. No migration for users: `docker` remains the default, Linux microVMs are unchanged.
2. Rollback of containerd on this workstation: `Stop-Service containerd`, `containerd.exe --unregister-service`, remove the containerd/nerdctl binaries from `C:\ProgramData\fc-sandbox-win\bin`, and delete containerd's image store (`C:\ProgramData\containerd`). The Docker setup is untouched.
