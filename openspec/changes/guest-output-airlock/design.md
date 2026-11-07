# Design

## Context

See proposal.md (Why). Current collection paths:

- **Linux:** `fcctl run` runs as root in `fc-host`. After the command, `download_dir` (`host/lib/ssh.sh`) does `ssh guest "tar -C /work/out -cf - ." | tar -C <results>/out -xf -`. GNU tar runs as root and writes straight into `runs/<id>/out/` on `/mnt/c`. The smoke tests call `fcctl` directly inside WSL, without `fc.ps1`.
- **Windows:** `Complete-FcWinRunResults` (`windows/fcctl-win.ps1`) calls `Receive-FcWinGuestFiles` (`windows/lib/runtime.ps1`): `docker|nerdctl exec ... tar.exe -cf - -C C:\work\out .` into a temp file, then host `tar.exe -xf` in the elevated controller.
- **VM start:** `boot_vm` (fcctl) and `Start-NewFcWinVm` (fcctl-win) read their resources and network mode from global options (`OPT_*`, script-scope `$Vcpu`/`$MemMib`/`$Net`), so a second VM with different settings can't be started in the same process today.
- **Privilege handling:** jailed Firecracker processes get per-slot uids (`FC_UID_BASE + slot`). `fc-egress` already shows how to start a child with a non-admin, Medium-integrity token inside a job object (`windows/egress/FcEgress/Launcher.cs`, `Native.cs`, `TokenInfo.cs`).
- **Base rootfs:** 2 GiB (`ROOTFS_SIZE`), copied per VM with `cp --sparse=always --reflink=auto`.

## Goals / Non-Goals

**Goals:**
- No archive parser on the host for guest data. One rules implementation used twice: in the airlock, then on the host.
- Existing commands, result layout and exit codes stay the same apart from the new `collection` field in `meta.json` and the role column in `list`.

**Non-Goals:**
- `get` for started VMs (`sandbox-mcp-server` builds on this change's transfer entry point).
- Configurable limits (constants for now; tests use an internal override, see D9).
- Optimising airlock boot (for example, booting it while the command is still running). Revisit after the spike (task 1.1).
- Changing host-to-guest uploads.

## Decisions

### D1. One .NET tool, two roles: `fc-airlock`
New projects `airlock/FcAirlock` (exe `fc-airlock`, `net10.0`, `InvariantGlobalization`) and `airlock/FcAirlock.Tests` (xUnit).
- `fc-airlock validate`: reads a tar stream on stdin and writes the airlock output format (D3) on stdout. It runs inside the airlock.
- `fc-airlock unpack --in <file> --staging <dir>`: reads the airlock output, re-validates it, writes the files into the empty staging folder (emptied again on failure) and prints `{"files":N,"bytes":M}`. It runs on the host; the controller moves staging into place (D4 step 8).
- Both roles share one `Rules` class (entry types, names, limits).
- Published as self-contained single-file binaries (trimmed), the way the repo already builds `fc-relay`: `linux-x64` (used as both the Linux airlock validator and the Linux host reader) and `win-x64` (Windows airlock validator and Windows host reader).
- *Alternative:* separate validator and reader projects. Rejected: the rules would drift apart.
- *Alternative:* GNU tar plus a shell validator in the Linux airlock. Rejected by the user's decision to use .NET everywhere.

### D2. Validator reads the tar stream with no extraction
`validate` uses `System.Formats.Tar.TarReader` over stdin.
- It accepts V7, ustar, pax and GNU formats, with pax and GNU long-name metadata entries consumed by the reader.
- Entry types allowed: `RegularFile`, `V7RegularFile` and `Directory`. Everything else aborts with exit code 3 and a one-line reason on stderr.
- Names are normalised the way tar archives from `-C dir .` look: a leading `./` is dropped and the root entry `.` is skipped. They are then checked with `Rules`.
- File data is streamed straight to stdout while SHA-256 is computed. Nothing touches the airlock's disk, so the airlock needs no extra drive and the 2 GiB rootfs is not a limit.
- *Alternative:* extract with tar inside the airlock, then walk the tree. Rejected: needs scratch space up to the cap and adds a second parser.

### D3. Airlock output format: blob first, manifest as a trailer
```
[file bytes ... concatenated in entry order]
[manifest JSON, UTF-8]
[8-byte little-endian manifest length]
[8 bytes ASCII "FCALOCK1"]
```
The manifest is `{"version":1,"entries":[{"path":"a/b.txt","type":"file","offset":0,"size":12,"sha256":"..."},{"path":"a","type":"dir"}]}`.
- A trailer lets the validator stream without buffering, because hashes are known only at the end.
- The host reads the trailer first. It checks the magic, that the manifest length is at most 16 MiB and within the file, and parses the JSON with `System.Text.Json` (max depth 4).
- It then requires file ranges to be contiguous, in order, non-overlapping, and to end exactly at the manifest start.
- *Alternative:* manifest first, which would need a second pass or disk inside the airlock. Rejected.
- *Alternative:* a framed per-entry stream. Rejected: the host could not check every name before writing.

### D4. Transfer pipeline, the same on both backends
```
1  ask the source VM whether the output folder has any entry   (guest answer; lying only hurts itself)
     empty -> collection = ok, 0 files; stop
2  pull the source tar stream into host staging file S   (byte cap: D9)
3  start a fresh airlock VM (role=airlock, parent=<id>, isolated, 1 vCPU, 256 MiB, 5 min)
4  push fc-airlock (validator build for that OS) into the airlock
5  exec in the airlock as an unprivileged user: fc-airlock validate < S > O   (O capped)
6  destroy the airlock (always, in a finally/trap)
7  host: fc-airlock unpack --in O --staging <fresh dir> as an unprivileged identity (D6/D7)
8  controller: check the staging tree (dirs + regular files only, no reparse points or links),
   then move it into the destination
9  record meta.json.collection; delete S, O and staging
```
- The source VM is destroyed after step 2 rather than after the whole collection, so the run's VM lifetime does not include airlock time.
- The existing `COLLECT_GRACE` and `COLLECT_GRACE_SEC` still cover step 2.

### D5. Starting a second VM in one controller process
Refactor `boot_vm` into `boot_vm_with <vcpu> <mem> <net> <allow> <lifetime> <keep> <role> <parent>` and `Start-NewFcWinVm` into a parameterised `Start-FcWinVmCore`. The existing commands call these with their parsed options; the airlock calls them with fixed values.
- VM state gains `role` (`vm` or `airlock`) and `parent`.
- `list` gains a `ROLE` column, showing `airlock:<parent-id>` for airlocks.
- Airlocks use the normal slot allocation, jailer uid, watchdog and `cleanup` paths, so they need no special cases there.
- On Windows the airlock uses the configured runtime and the configured default image. It runs with `--isolation=hyperv` and no network adapter, the same as `isolated` mode.

### D6. Linux host reader identity
`unpack` runs inside `fc-host` as a per-transfer unprivileged uid taken from a dedicated range (`FC_UNPACK_UID_BASE` = 200000 + slot of the airlock), via `setpriv --reuid --regid --clear-groups --no-new-privs`, under `timeout`.
- Staging lives under `/var/lib/fc-sandbox/staging/<id>/`, created by root and handed to that uid. S and O are made readable by it only.
- Afterwards root kills every process of that uid (`pkill -KILL -U`), takes ownership of the staging tree back, runs the step-8 check (`find` for anything not `-type f`/`-type d`), and copies the tree into `runs/<id>/out/` on `/mnt/c` with `cp -R --no-preserve=all` into a fresh `out.tmp`, then renames it to `out`.
- *Changed from the exploration default:* we had leaned towards a single Windows-side reader. Running it inside `fc-host` keeps `fcctl` self-contained, which matters for the smoke tests (they call `fcctl` directly) and for the watchdog. It is the same code, published for `linux-x64`.

### D7. Windows host reader identity
The elevated `fcctl-win.ps1` starts `fc-airlock.exe unpack` through a restricted launch:
- a non-admin, Medium-integrity token in a kill-on-close job object, with memory and time limits;
- the token and job code is moved out of `FcEgress` into a shared `windows/common/FcWinToken` source project that both tools reference, so it is not duplicated;
- `fc-airlock` gains a Windows-only `launch-unpack` entry, used only by the elevated controller, which re-executes itself as the restricted child and waits.

Staging is `%TEMP%\fc-airlock-<id>-<guid>` of the user. Step 8 rejects any reparse point before `Move-Item` into `runs\<id>\out`. Closing the job kills any leftover processes before step 8.

### D8. Validator delivery and guest identity
- **Linux:** `upload_dir` puts `fc-airlock` into `/opt/fc-airlock/` in the airlock, and the validator runs as `setpriv --reuid=65534 --regid=65534 --clear-groups` (`nobody`).
- **Windows:** `Send-FcWinGuestFiles` puts `fc-airlock.exe` into `C:\fc\`, and `exec -u ContainerUser` runs it.
- Both images already have these users, so no image change is needed.
- **Build outputs:**
  - Linux: setup publishes into the user's `%LOCALAPPDATA%\fc-sandbox\airlock\linux-x64\` and `provision.sh` installs it to `/opt/fc-sandbox/bin/fc-airlock` (root-owned).
  - Windows: setup publishes into `C:\ProgramData\fc-sandbox-win\bin\airlock\`, which is admin-only, next to `egress\`.

### D9. Limits
- Constants in `Rules`: total file bytes 1 GiB, 10,000 entries, 1 GiB per file, paths of 512 characters and 64 levels, manifest 16 MiB.
- The stream cap for S and for O is total bytes + 1536 × max entries + 1 MiB of tar and manifest overhead.
- The controllers enforce the cap while copying (`head -c` and a counted copy) and refuse at cap + 1.
- For tests only, the environment variable `FC_AIRLOCK_TEST_MAX_BYTES` can *lower* the byte limits. Any value above the default is ignored. It is read by the controllers and passed to both roles.

### D10. Exit codes and reporting
- A refused or failed collection does not change the run's exit code (spec: Exit code propagation). It writes `meta.json.collection = {status, reason, files, bytes}` and prints `collection refused: <reason>` to stderr.
- Airlock infrastructure errors (the airlock didn't boot, or the tool is missing) produce `status: failed`.
- `fc-airlock` exit codes: 0 ok, 3 refused (rule violation), 4 malformed input, 5 internal error.

### D11. Setup and doctor
- A new `airlock/install-airlock.ps1` (rebuild only when sources are newer, like `Install-FcWinEgress`) is called by `setup-host.ps1` (linux-x64, before provisioning) and `setup-nanoserver.ps1` (win-x64).
- A missing .NET 10 SDK now fails setup. This is the breaking change noted in the proposal.
- `doctor` on Linux checks that `/opt/fc-sandbox/bin/fc-airlock` exists and that `fc-airlock --version` runs. `doctor -Guest windows` checks the published exe the same way.

## Risks / Trade-offs

- [Every run with output pays one more VM boot] → measured by the spike in task 1.1. Runs with no output skip the airlock. Early source-VM teardown keeps VM lifetime unchanged.
- [`System.Formats.Tar` itself could have a bug] → it runs only inside the airlock as `nobody`/`ContainerUser`, and the host never runs it on guest data. The host parses only the D3 trailer and manifest.
- [A compromised airlock forges its output] → the host re-validates everything (spec: Host re-validation) and checks hashes and ranges. The reader runs unprivileged, and the move step only ever sees directories and regular files.
- [Compromised reader leaves processes or links behind in staging] → uid-wide kill (Linux) or job kill-on-close (Windows), then an ownership reset and a type check before the move.
- [The Windows airlock adds a container start, which is slow] → accepted, measured in the spike. Windows guests already take longer per run.
- [The .NET 10 SDK becomes mandatory for setup] → clear setup error with an install hint. Documented as breaking.
- [Moving the token code out of `FcEgress` touches a security-sensitive component] → `FcEgress.Tests` must still pass, and the move changes no behaviour.

## Migration Plan

- Re-run `fc.ps1 setup` (and `setup -Guest windows`) after upgrading. Without it, `doctor` fails the airlock check and runs report `collection.status = failed` with a hint.
- Rollback: revert the change and re-run setup. Old runs' result folders stay readable, since `collection` is an extra field.

## Measured overhead

Task 1.1 spike, 2026-11-07, Windows 11 26200, WSL 2.6.3, Firecracker v1.17.0.

- **Linux airlock** (1 vCPU / 256 MiB, isolated; `fcctl start` + `ssh true`), 10 runs: median 7.4 s, best 1.4 s, worst 7.8 s. Almost all of it is `start`; the first `ssh` adds about 150 ms. The two clusters (about 1.5 s and about 7.5 s) come from the existing `wait_ssh` loop: an SSH attempt made before the guest's sshd listens appears to wait out `ConnectTimeout=5`. A shorter connect timeout in `wait_ssh` would help every VM, not only airlocks; out of scope here.
- **Linux collection end to end** (`airlock_transfer` of two small files): 9.1 s.
- **Windows airlock**: not measured yet (needs an elevated prompt). Script: `spike-windows.ps1` from the session scratchpad.

## Open Questions

- Measured airlock overhead (task 1.1) may motivate pre-booting airlocks later. This does not change the approach or the tasks here.
