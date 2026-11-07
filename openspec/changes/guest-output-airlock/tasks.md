# Tasks

## 1. Spike: airlock overhead

- [ ] 1.1 Measure boot-to-ready time for a 1 vCPU / 256 MiB isolated Firecracker VM (`fcctl start` + `ssh true`) and for a Hyper-V Nano Server container on docker and containerd (`start -Guest windows` + `ssh <id> ver`), 5 runs each; verify by recording the median and worst case in a "Measured overhead" note in design.md, and raise it with the user before continuing if the Windows median is above 30 s

## 2. Shared rules and the `fc-airlock` tool

- [x] 2.1 Create `airlock/FcAirlock` (`net10.0`, `InvariantGlobalization`, exe `fc-airlock` with `--version`) and `airlock/FcAirlock.Tests` (xUnit) with `Airlock.slnx`; verify `dotnet build` and `dotnet test` succeed
- [x] 2.2 Implement `Rules` (entry types, NTFS-safe component rules, reserved device names with extensions, case-insensitive collision check, length and depth limits, byte and entry limits, the downward-only `FC_AIRLOCK_TEST_MAX_BYTES` override); verify unit tests for every rule in the `guest-output-airlock` spec, including `con.txt`, `COM1`, trailing dot or space, `:`, `Report.txt` + `report.txt`, depth 65 and an override above the default being ignored
- [x] 2.3 Implement `validate` (TarReader over stdin, `./` normalisation, root `.` skipped, streaming data with SHA-256, D3 trailer, exit codes 0/3/4/5); verify unit tests with crafted archives in ustar, pax and GNU formats: regular files and dirs pass; symlink, hardlink, char/block device, FIFO, sparse, absolute path, `../x`, oversize file, too many entries and a truncated archive are each refused with the right exit code and a reason naming the entry
- [x] 2.4 Implement `unpack` (trailer magic and length checks, manifest size and depth limits, re-applying `Rules`, contiguous non-overlapping ranges ending at the manifest, SHA-256 check, writing into the given staging folder, no partial results on failure); verify unit tests for a valid round-trip from `validate`, a hash mismatch, overlapping ranges, a range past the end, a bad magic, an oversized manifest, an unsafe path in an otherwise valid manifest, and that the staging folder is empty after every refusal
- [ ] 2.5 Add `airlock/install-airlock.ps1` publishing self-contained trimmed single-file builds for `linux-x64` (to `%LOCALAPPDATA%\fc-sandbox\airlock\linux-x64\`) and `win-x64` (to `C:\ProgramData\fc-sandbox-win\bin\airlock\`), rebuilding only when sources are newer and failing with an install hint when no .NET 10 SDK is found; verify a second call reports up to date and a machine without the SDK gets the error

## 3. Windows restricted launch shared with `fc-egress`

- [ ] 3.1 Move the token and job-object code from `windows/egress/FcEgress` (`Native.cs`, `TokenInfo.cs`, the restricted-child parts of `Launcher.cs`) into a shared source project `windows/common/FcWinToken` referenced by `FcEgress` without changing behaviour; verify `FcEgress.Tests` passes and a Windows networked smoke run still logs to `net.log`
- [ ] 3.2 Add `fc-airlock launch-unpack` (Windows only) that re-executes `unpack` as a non-admin Medium-integrity child in a kill-on-close job with memory and time limits and returns its exit code; verify a test from an elevated prompt that the child's token is not in the Administrators group and that a child spawning a grandchild leaves no process after return

## 4. Linux backend

- [x] 4.1 Refactor `boot_vm` into `boot_vm_with` with explicit resources, network, lifetime, keep, role and parent, store `role`/`parent` in VM state, and add a trailing `ROLE` column to `fcctl list` (`vm` or `airlock:<parent>`); verify the existing `tests/smoke` suite still passes unchanged
- [x] 4.2 Install `fc-airlock` from the published linux-x64 build into `/opt/fc-sandbox/bin/` in `provision.sh` (called from `setup-host.ps1` after `install-airlock.ps1`) and add the doctor check; verify `fc.ps1 setup` installs it, a second setup is a no-op, and `doctor` fails with the re-run-setup hint after the binary is removed
- [x] 4.3 Implement `airlock_transfer <src-id> <guest-dir> <dest-dir>` in a new `host/lib/airlock.sh` following D4 and D6 (empty check, capped pull to S, airlock boot, validator push and `nobody` exec with capped O, airlock always destroyed, `unpack` as the per-transfer uid under `setpriv`/`timeout`, uid-wide kill, ownership reset, type check, copy to `out.tmp` and rename, cleanup of S/O/staging), returning status, reason, files and bytes; verify by calling it against a `start`-ed VM with a small folder and checking the files and that no airlock remains in `list`
- [x] 4.4 Replace `download_dir` in `cmd_run` with `airlock_transfer`, destroy the source VM right after the pull, and write `collection` into `meta.json` with the exit code unchanged; verify `tests/smoke/run.sh` passes (it checks `out/kernel.txt` and `out/sub/file.txt`) and a run with no output starts no airlock
- [x] 4.5 Extend `cmd_cleanup` to kill processes in the unpack uid range and remove `/var/lib/fc-sandbox/staging/*`; verify by killing `fcctl` during a collection and checking that `cleanup` leaves no airlock, reader process or staging folder
- [x] 4.6 Add `tests/smoke/airlock.sh` and register it in `tests/smoke/all.sh`: output collected and airlock gone; symlink, FIFO, `con.txt`, case collision and an over-limit file (with `FC_AIRLOCK_TEST_MAX_BYTES`) each refused with `out/` empty, `meta.json.collection.status = refused` and the guest exit code kept; empty output starts no airlock; `list` shows `airlock:<id>` during a slow collection; verify the full Linux smoke suite passes

## 5. Windows backend

- [ ] 5.1 Refactor `Start-NewFcWinVm` into a parameterised `Start-FcWinVmCore` (resources, network, lifetime, keep, role, parent), store `role`/`parent` in VM meta and show them in `list`; verify `tests/smoke-win` lifecycle tests still pass
- [ ] 5.2 Call `install-airlock.ps1` for win-x64 from `setup-nanoserver.ps1` and add the `doctor -Guest windows` airlock check; verify setup builds it, a re-run is a no-op, and `doctor` fails with the hint when the exe is missing
- [ ] 5.3 Implement `Invoke-FcWinAirlockTransfer` in a new `windows/lib/airlock.ps1` following D4 and D7 (empty check, capped pull, airlock container start, validator push to `C:\fc\`, `exec -u ContainerUser` with capped output, airlock always removed, `launch-unpack` into a user temp staging folder, reparse-point and type check, move into place, cleanup); verify against a `start -Guest windows` VM on docker and on containerd
- [ ] 5.4 Replace `Receive-FcWinGuestFiles` in `Complete-FcWinRunResults` with the airlock transfer, write `collection` into run `meta.json`, keep the exit code, and stop the source VM after the pull; verify `tests/smoke-win` passes and Windows run results still contain `out\` files
- [ ] 5.5 Extend Windows `cleanup` to remove leftover airlock containers and `fc-airlock-*` staging folders; verify by interrupting a collection and running `cleanup`
- [ ] 5.6 Add `tests/smoke-win/airlock.ps1` (collected output; symbolic link and junction made with `mklink`/`mklink /J`, `con.txt`, case collision and over-limit each refused with `out\` empty and status recorded; empty output starts no airlock) and call it from `tests/smoke-win/all.ps1`; verify the Windows smoke suite passes on docker and containerd

## 6. Documentation

- [ ] 6.1 Update `README.md`: the .NET 10 SDK as a prerequisite for every setup (marked as a breaking change), the airlock in the architecture diagram and the "Simple results" feature, `meta.json.collection`, the `ROLE` column in `list`, limits and refusal reasons, and the airlock in "Security considerations and limitations"; verify every documented command and field matches a real run on both guests

## Workflow follow-up

- Run the full Linux and Windows smoke suites before review.
- Archive this change, then implement `sandbox-mcp-server`, whose `get` builds on `airlock_transfer` and `Invoke-FcWinAirlockTransfer`.
