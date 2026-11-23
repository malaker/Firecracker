# Design

## Context

See proposal.md for motivation. What shapes the approach:

- **A Windows run is built from reusable steps** in `windows/fcctl-win.ps1` and `windows/lib/runtime.ps1`: `Start-NewFcWinVm`, `Send-FcWinGuestFiles` (tar over HVSocket into a guest folder), `Invoke-FcWinGuestCommand` (writes the command into a `.cmd` file in `C:\work\.fc`, runs it with `docker exec` as `ContainerAdministrator` in `C:\work`, with the proxy variables in networked mode and an optional timeout), and `Complete-FcWinRunResults` (collects `C:\work\out` through the airlock, writes `exit_code` and `meta.json`).
- **A timeout ends the exec client, not the VM.** `Invoke-FcWinGuestCommand` returns `TimedOut` and the VM keeps running until collection, so more commands can still run in it.
- **The controller runs elevated, and guest-derived data is never parsed with admin rights** (airlock design D7). `fc-airlock launch-unpack` re-runs itself through `FcWin.RestrictedLaunch.RunToCompletion` (`windows/common/FcWinToken`), with a non-admin Medium-integrity token, a kill-on-close job, a timeout and a memory limit.
- **`net.log` is written by the host proxy**, but its `host` field is the name the guest asked for, so it is also guest-derived.
- **Host tools are .NET 10 builds** installed by an `install-*.ps1` script into `C:\ProgramData\fc-sandbox-win\bin\<tool>\` (administrator-only), rebuilt only when sources are newer (`airlock/install-airlock.ps1`).
- **The Nano Server guest has `cmd.exe`, `reg.exe` and `curl.exe`, but no PowerShell**, so in-guest steps are batch files.
- **`fc.ps1` already has `-Sample` and `-Entry`** (recipes, Linux only) and refuses `recipe` for Windows guests.

## Goals / Non-Goals

**Goals:**

- One command, any Windows program, a report a person can read and a JSON file a tool can read.
- After snapshots even for programs that hang or wait forever.
- No new host code that parses guest data with admin rights.
- Reuse the run machinery: same results layout, airlock collection, watchdog, egress proxy and `net.log`.

**Non-Goals:**

- Live process tracing (no ETW or Procmon in the guest). The report compares states before and after.
- Detecting modified files, or hashing file contents.
- Linux guests, and MCP exposure (see proposal.md).

## Decisions

### D1. `audit` is a controller command built from the run steps

`fcctl-win.ps1 audit` (new file `windows/lib/audit.ps1`) does, for each mode:

1. `Start-NewFcWinVm` with lifetime `Timeout + snapshot budget (2 x 5 min) + COLLECT_GRACE_SEC`.
2. `Send-FcWinGuestFiles` the staged sample to `C:\work\in\app`, and the generated audit scripts to `C:\work\in\.audit`.
3. Three `Invoke-FcWinGuestCommand` calls: `snapshot.cmd before` (quiet, 5-minute limit), `program.cmd` (output to `stdout.log`/`stderr.log`, limit `-Timeout`), `snapshot.cmd after` (quiet, 5-minute limit, run even if step 2 timed out).
4. `Complete-FcWinRunResults` (airlock collection, `exit_code` = program exit code or 124, `meta.json` plus an `audit` entry).
5. Build the report (D4).

`fc.ps1 audit` validates the options, passes them through, and refuses Linux guests.

- **Why:** a single `run` with one wrapper script cannot take the after snapshot once the program outlives the timeout, because the exec is abandoned and the run is collected. Separate exec steps in one VM solve that, and need no process-kill tool in the guest.
- **Alternative: an external script calling `fc.ps1 start/put/ssh/get/stop`.** This is what the prototype in `C:\Tools\sandbox-audit` grew towards. Rejected: `ssh` has no per-command timeout or log capture, `start` VMs are not collected into `runs\`, and it adds a second elevated entry point that re-parses console output.
- **Alternative: `fc.ps1 run` with a wrapper `.cmd`.** This is the prototype's current form. Rejected for the timeout reason above.

### D2. Staging

The sample (a file, or a folder minus `-Exclude` top-level entries) is copied to `%TEMP%\fc-audit-<guid>\payload\app\`. The generated scripts go beside it into `payload\.audit\`, never into `app\`, so a sample file named `snapshot.cmd` cannot replace them. The whole `payload\` is uploaded to `C:\work\in` in one transfer and deleted in a `finally` block. `-Entry` is resolved against the staged copy and must stay inside it (no `..`, no rooted paths, no quotes). A folder sample containing a link or junction is refused, so it cannot pull other host files into the VM.

- **Trade-off:** the recipe design (D1 there) avoided a host copy because antivirus may quarantine it. A Windows run needs one folder per upload, and `-Exclude` needs a filtered copy anyway. The README tells users to stage samples in an antivirus-excluded folder; staging under `%TEMP%` is documented the same way, with a `-StagingDir` option to override it.

### D3. Passing `-Arguments` through a batch file

`program.cmd` is written by the controller as UTF-8. It switches `cmd` to code page 65001 (when `chcp.com` exists), changes to `C:\work\out`, runs `"C:\work\in\app\<entry>" <escaped>`, then `exit /b %ERRORLEVEL%`. It is uploaded with the sample rather than passed as `Invoke-FcWinGuestCommand` text, because that helper writes its batch file in the ANSI code page on Windows PowerShell 5.1, which would mangle non-ASCII arguments. `<escaped>` is built by one pass over the user's string that tracks double quotes. `%` always becomes `%%`. Outside quotes, `^ & | < > ( )` get a `^` prefix. Inside quotes they are literal to `cmd`, so they are left alone. Delayed expansion is off in `cmd`'s default, so `!` needs nothing. CR and LF are refused (exit 125).

- **Why:** `Invoke-FcWinGuestCommand` already runs commands as batch files, and the guest has no other launcher. Escaping is a pure string function, so it is unit-tested in isolation (`tests/smoke-win/audit.ps1` checks the round trip in a real guest).
- **Alternative: a guest launcher exe that reads arguments from a file.** It would be more exact, but it is another binary to build and ship into the guest. Rejected for now.

### D4. `fc-audit`: an unprivileged report builder

A new .NET 10 console tool, `audit/FcAudit` (core logic in `audit/FcAudit.Core`, tests in `audit/FcAudit.Tests`), referencing `FcWinToken`:

- `fc-audit report --run <run dir> --info <info.json> --out <staging dir>` reads `out\_audit\*`, `net.log`, `exit_code` and the `out\` file list. It writes `audit-report.md`, `audit-report.json` and the full lists (`files-created.txt`, `files-deleted.txt`, `registry-changes.txt`) into `<staging dir>`.
- `fc-audit launch-report ...` re-runs `report` through `RestrictedLaunch.RunToCompletion` with a 120-second limit and 1 GiB memory, like `launch-unpack`.
- `info.json` is written by the controller from trusted values: sample path and SHA-256 (hashed on the host before upload), arguments, mode, and the paired run id.
- The controller creates the empty staging folder, then moves the produced files into `runs\<id>\` (`audit-report.*`) and `runs\<id>\audit\` (full lists) without reading them. A non-zero exit or timeout leaves no report and makes the audit exit 125 (spec: unprivileged report building).
- **Parsing rules:** file listings are compared as ordinal-ignore-case sets, ignoring `C:\work\`. `.reg` exports are UTF-16. Continuation lines (ending in `\`) are joined, every value is keyed as `[key] name=data`, and a key with no values is kept as `[key]`. `net.log` lines are split on spaces into `key=value` pairs, and `reason=sentinel` (the proxy self-check) is skipped. Each input file is capped (64 MiB) and an oversized one is reported as "too large to compare", not truncated silently. Markdown lists stop at 200 lines with a "full list in audit\..." note. Every guest-derived string is written into Markdown code spans or blocks with backticks neutralised.
- **Why a separate tool and not PowerShell:** the parsing would otherwise run in the elevated controller. A .NET tool reuses the restricted-launch code that the airlock already relies on, and can be unit-tested without VMs.
- **Alternative: build the report inside the guest.** Rejected: there is no PowerShell or .NET SDK in every flavour, and the program under audit controls the guest.
- **Alternative: build it in the airlock VM.** Rejected: the airlock's single job is validating archives, and mixing report logic in would widen it.

### D5. Options and dispatch

- `fc.ps1`: add `audit` to the command set, plus `[string]$Arguments`, `[string[]]$Exclude` and `[string]$StagingDir`. `-Sample` and `-Entry` are reused. For `-Guest windows` they are passed as Windows paths. Without `-Guest windows`, exit 125 with the message from the spec. `-Cmd` and `-Payload` are refused with `audit` (exit 125).
- `-Net` omitted means both modes, in order isolated, networked. A failed isolated run is recorded and the networked run still starts.
- `-Timeout` defaults to `5m` for the program step. `-Vcpu`, `-MemMib` (default `2048` for audits), `-Flavour`, `-WinRuntime` and `-Keep` mean what they mean for `run`.

### D6. Setup and doctor

`audit/install-audit.ps1 -Rid win-x64` mirrors `install-airlock.ps1` (source-newer check, administrator-only folder `bin\audit\`). `setup-nanoserver.ps1` runs it after the airlock step. `doctor.ps1` adds "audit report tool (fc-audit.exe)". `audit` checks for the binary before starting any VM.

## Risks / Trade-offs

- [The audited program runs as `ContainerAdministrator` and can alter the snapshots or the `reg`/`dir` binaries] → stated in every report. The snapshot scripts run from `C:\work\in\.audit` with absolute `C:\Windows\System32\` paths. This is evidence, not a verdict.
- [A program still running during the after snapshot can change things mid-listing] → the report notes when the program did not finish, so readers treat the diff as partial.
- [`dir /s` of `C:\` and full `HKLM\SOFTWARE` exports are large, and `reg export` is slow] → snapshots have their own 5-minute limit. Sizes are well under the airlock's 1 GiB, and `fc-audit` caps each input.
- [The batch escaping is wrong for some edge case] → pure function with table tests, plus an in-guest round-trip smoke test with `%`, `&`, `|`, quotes and parentheses.
- [Copying the sample to `%TEMP%` may trigger antivirus] → `-StagingDir` and a README note, as for recipe samples.
- [Programs that ignore `HTTP(S)_PROXY` leave no network trace] → stated in the report. The isolated run's `stderr.log` usually shows their failed attempts.
- [The Windows backend currently fails to start VMs on this host] → out of scope (proposal.md). Implementation and unit tests do not need VMs. The smoke test and real audits wait for the fix.

## Migration Plan

Additive. `fc.ps1 setup -Guest windows` builds `fc-audit`. Nothing changes for existing commands. To roll back, revert the change and delete `C:\ProgramData\fc-sandbox-win\bin\audit\`. The `C:\Tools\sandbox-audit` prototype script is replaced by `fc.ps1 audit` and can be deleted.

## Open Questions

- Whether to add per-file SHA-256 for created files later. It needs a hashing tool in the guest (`certutil` is not in Nano Server). It is deferrable and does not change this design.
