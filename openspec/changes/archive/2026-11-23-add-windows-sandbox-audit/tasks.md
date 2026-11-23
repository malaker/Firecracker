# Tasks

## 1. Report builder (`fc-audit`)

- [x] 1.1 Create `audit/Audit.slnx` with `FcAudit.Core` (library), `FcAudit` (console, references `windows/common/FcWinToken`) and `FcAudit.Tests` (xunit), matching `airlock/`'s project settings (net10.0, nullable, trimmed single-file publish for win-x64). Verify `dotnet build audit/Audit.slnx` and `dotnet test audit/Audit.slnx` succeed with an empty test
- [x] 1.2 Implement the parsers in `FcAudit.Core` (design D4): file listing set diff ignoring `C:\work\`, `.reg` UTF-16 parsing with continuation lines and `[key] name=data` keys, `net.log` `key=value` parsing that skips `reason=sentinel`, grouping by host/port/decision in first-seen order with summed bytes and distinct IPs, and the 64 MiB per-input cap. Verify with unit tests for each, including a multi-line `hex:` value, a key with no values, a missing file (reported as missing, not "no changes") and an oversized input
- [x] 1.3 Implement the report writers: `audit-report.json` (schema with sample, sha256, arguments, mode, paired run id, program exit code or `did_not_finish`, network, files, registry, outputs, limits) and `audit-report.md` with the same facts, 200-line truncation notes, backtick-safe code spans for guest strings, and the evidence-limits section from the spec. Verify with golden-file tests built from a fixture run folder (use the shape of a real `runs\<id>` with `net.log`, `exit_code` and `out\_audit\`)
- [x] 1.4 Implement `fc-audit report --run --info --out` and `fc-audit launch-report` (restricted relaunch, 120 s, 1 GiB, like `fc-airlock launch-unpack`). Verify with a unit or integration test that `launch-report` from an elevated prompt runs the child without the Administrators group enabled (check the token with `FcWin.TokenInfo`), and that a forced timeout returns non-zero and leaves `--out` without report files
- [x] 1.5 Add `audit/install-audit.ps1 -Rid win-x64` mirroring `airlock/install-airlock.ps1` (source-newer check, administrator-only `C:\ProgramData\fc-sandbox-win\bin\audit\`, exit codes 0/1/2). Verify a first run builds, a second run skips the build, and the folder ACL grants write only to Administrators and SYSTEM

## 2. Setup and doctor

- [x] 2.1 Call `install-audit.ps1` from `windows/setup-nanoserver.ps1` after the airlock step, failing setup with the SDK message when it exits 1. Add the "audit report tool (fc-audit.exe)" check to `windows/lib/doctor.ps1`. Verify `fc.ps1 setup -Guest windows` installs it, `doctor -Guest windows` shows PASS, and renaming the binary makes the check FAIL with a re-run-setup hint
- [x] 2.2 Document the new build step and the doctor check in the README's Windows setup section and the uninstall steps (`bin\audit\`); verify the documented commands run as written

## 3. Audit command

- [x] 3.1 Implement the argument escaper (design D3) as a pure function in `windows/lib/audit.ps1` and refuse CR/LF. Verify with a table test in `tests/smoke-win/audit.ps1` (runs without VMs) covering `%`, `%%`, `&`, `|`, `<`, `>`, `^`, `(`, `)`, quoted and unquoted forms, and an empty string
- [x] 3.2 Implement staging (design D2): sample file or folder copy into `<StagingDir or %TEMP%>\fc-audit-<guid>\app\` with `-Exclude`, scripts in a separate `scripts\` folder, `-Entry` validation (relative, inside the copy, exists), SHA-256 of the entry, and removal in `finally`. Verify by test that `-Exclude media` leaves `media` out, `-Entry ..\x.exe` exits 125, and no `fc-audit-*` folder remains after success, failure and Ctrl+C
- [x] 3.3 Write the guest scripts `snapshot.cmd before|after` (absolute `C:\Windows\System32\` paths, `dir /s /b /a C:\`, `reg export` of `HKLM\SOFTWARE` and `HKCU` into `C:\work\out\_audit\`) and the generated `program.cmd` (cd `C:\work\out`, quoted entry path, escaped arguments, `exit /b %ERRORLEVEL%`)
- [x] 3.4 Implement `fcctl-win.ps1 audit` (design D1): per mode, start the VM with the extended lifetime, upload `app\` and `scripts\`, run the three exec steps with their limits (after-snapshot also after a program timeout), call `Complete-FcWinRunResults` with the program's exit code or 124, add `meta.json` `audit`, write `info.json` from trusted values, run `fc-audit launch-report` into a fresh staging folder, and move the outputs into `runs\<id>\` and `runs\<id>\audit\`. Isolated then networked when `-Net` is omitted, and the networked run still starts when the isolated one fails. Exit codes as in the spec. Verify with the smoke test in 4.1
- [x] 3.5 Add `audit` to `fc.ps1` with `-Arguments`, `-Exclude`, `-StagingDir`, reusing `-Sample`/`-Entry`, `-Net`, `-Allow`, `-Timeout` (default `5m`), `-MemMib` (default `2048`), `-Flavour`, `-WinRuntime`, `-Keep`. Refuse Linux guests and `-Cmd`/`-Payload` with exit 125 before any VM starts, and refuse when `fc-audit.exe` is missing. Verify each refusal from both `powershell.exe` and `pwsh` without elevation where possible, and that a sample path with spaces works
- [x] 3.6 Add `audit` to the `help` text in `fcctl-win.ps1` and a README section "Auditing a Windows program (`fc.ps1 audit`)" with usage, the report layout, the evidence limits and the antivirus/staging note; verify the documented examples run as written

## 4. Smoke test and integration

- [x] 4.1 Add `samples/audit-win/` (a small C# probe, `fc-audit-probe.exe`, built by the smoke test; a `.cmd` cannot record `%*` faithfully because `cmd` re-parses `&`/`|` after expanding it): it writes `out-file.txt` to its working directory, creates `C:\Users\Public\fc-audit-probe.txt`, adds `HKCU\Software\FcAuditProbe` value `x`, writes its raw arguments to `args.txt`, and fetches `http://example.com/` (through `HTTP_PROXY`); `--hang` makes it wait forever. Add `tests/smoke-win/audit.ps1` that audits it with `-Arguments 'a&b "c|d" (e) 50%'` and checks: two run folders; both reports; the created file and registry value listed; `args.txt` matches exactly; `example.com:80` allowed in the networked report and the isolated report states no network; a `-Timeout 20s` audit of a never-ending sample still has after snapshots and exit code 124. Register it in `tests/smoke-win/all.ps1`
- [x] 4.2 Prerequisite for 4.1 and 4.3: a working Windows backend. The `docker` backend fails here on `--network=none` (`/start: EOF`, see proposal.md). `-WinRuntime containerd` passes `fc.ps1 doctor -Guest windows -WinRuntime containerd -Boot` (checked 2026-11-23), so run 4.1 and 4.3 with `-WinRuntime containerd` until docker is fixed, and with docker too once it is
- [x] 4.3 End-to-end check: run `.\tests\smoke-win\all.ps1 -WinRuntime containerd` (and `docker` once its `--network=none` failure is fixed, see 4.2) and confirm all parts pass, then audit `yt-dlp.exe` (`-Sample <folder> -Entry yt-dlp.exe -Exclude audio -Arguments '-v -f worst -o video.%(ext)s <test url>'`) and confirm the networked report lists the YouTube/Google hosts it contacted
- [x] 4.4 Run `openspec validate add-windows-sandbox-audit --strict` and confirm it passes

## Workflow follow-up

- Delete the prototype `C:\Tools\sandbox-audit\Invoke-SandboxAudit.ps1` once `fc.ps1 audit` replaces it.
- Archive the change after review.

## Post-archive review fixes (2026-11-23)

Found by `/code-review` after archiving; fixed in `windows/lib/audit.ps1` without a new change, because they correct the implementation, not the specified behavior.

- `-Exclude` only takes names of entries directly inside the sample folder. Paths such as `config\secrets.json`, and `.` or `..`, are refused (previously a nested path passed the existence check but was still copied into the VM).
- The link check refuses only junctions and symbolic links (`LinkType`), not every reparse point (OneDrive and cloud placeholders are ordinary files), and skips `-Exclude`d entries.
- A program still running at `-Timeout` is stopped in the guest (`stop.cmd`). Nano Server has no `taskkill.exe` (checked in a guest), so the controller uploads `fc-audit.exe` and runs its new `kill --image <entry>` command (`Process.Kill` of the whole process tree); `taskkill /F /T` is used where a guest has it. This happens before the after snapshots, so they and the collection of `C:\work\out` see a quiet guest. Batch-file entries cannot be stopped by name. The report and `audit-report.json` (`program.stopped`) say whether it was stopped. The smoke test adds a probe mode that keeps writing (`--hang-write`).
- `Invoke-FcWinAuditRun` now cannot throw: the metadata writes and result collection are inside its error handling, and the VM is always removed, so a failed isolated run never skips the networked run or changes the exit code from 125.
- The VM lifetime now also covers the payload and script uploads, the stop step and the airlock's pull.