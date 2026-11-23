# Proposal

## Why

The sandbox can run an untrusted Windows program, but finding out what it did takes several hand-built runs: assembling a payload folder, writing a wrapper script, running it isolated and then networked, and reading `net.log`, `stdout.log` and raw guest output side by side. The common question, "what does this program connect to, and what does it change?", should be one command with one report, for any Windows program.

## What Changes

- **`fc.ps1 audit -Guest windows` command.** `fc.ps1 audit -Guest windows -Sample <exe|folder> [-Entry <exe in folder>] [-Arguments '<args>'] [-Net isolated|networked] [-Allow <cidr>,...] [-Exclude <name>,...] [-StagingDir <dir>]` runs the program in disposable Windows Nano Server microVMs and writes an audit report. Without `-Net` it does two runs: isolated, then networked.
- **What the audit records.** Inside each VM a generated wrapper snapshots the guest's file system listing and registry (`HKLM\SOFTWARE`, `HKCU`) before and after the program, and runs the program with `C:\work\out` as its working directory so the files it writes are collected.
- **Audit report.** Each run folder gains `audit-report.md` (for people) and `audit-report.json` (for tools). They list the network destinations from the egress proxy's `net.log` (host, port, decision, addresses, bytes, first seen), files created and deleted outside `C:\work`, registry values added and removed, the files the program wrote, and its exit code.
- **Unprivileged report builder.** Building the report means parsing guest-produced data. A new memory-safe tool, `fc-audit`, does this. The elevated controller never parses the data itself: it starts `fc-audit` with a restricted, non-admin token, the same way `fc-airlock` does for `launch-unpack`.
- **Setup and doctor.** Windows setup builds `fc-audit` with the .NET 10 SDK (already a prerequisite), and `doctor -Guest windows` reports it.

Not in this change:

- Linux guests. `fc.ps1 audit` without `-Guest windows` exits 125 and points to `recipe detonate` and `recipe triage-static`.
- Visibility into encrypted traffic. The audit shows host names and ports, not URLs or content inside TLS.
- Detection of modified files (only created and deleted ones), file-content hashes, and registry hives other than `HKLM\SOFTWARE` and `HKCU`.
- An MCP tool for audits.
- The current Windows microVM start failure on the `docker` backend (`docker run --isolation=hyperv --network=none` ends in `/start: EOF` on this host, most likely since the 2026-11-12 Windows updates). The `containerd` backend is not affected and is used for testing until the Docker failure is fixed separately.

## Capabilities

### New Capabilities

- `sandbox-audit`: auditing a program's behaviour in disposable microVMs: the `audit` command and its inputs, the in-guest snapshots, the isolated and networked runs, the report contents and format, the unprivileged report builder, exit codes and evidence limits.

### Modified Capabilities

- `windows-microvm-host-setup`: setup also builds the `fc-audit` tool for `win-x64` into the administrator-only tools folder, and `doctor -Guest windows` checks for it.

## Impact

- **New files:** `audit/FcAudit/` (report builder and restricted relaunch), `audit/FcAudit.Tests/`, `audit/install-audit.ps1`, `windows/lib/audit.ps1` (orchestration and wrapper generation), `tests/smoke-win/audit.ps1`, a small test program under `samples/`.
- **Changed code:** `fc.ps1` (new `audit` command, `-Arguments`, `-Exclude` and `-StagingDir` options), `windows/fcctl-win.ps1` (dispatch), `windows/setup-nanoserver.ps1` (build step), `windows/lib/doctor.ps1` (check), `tests/smoke-win/all.ps1`, `README.md`.
- **Setup:** one more small .NET build during Windows setup. No new prerequisites.
- **Compatibility:** existing commands behave as before. `-Sample` and `-Entry` keep their recipe meaning and also apply to `audit`.
- **Security:** the audited program runs only inside microVMs, as `ContainerAdministrator`, like any Windows payload. It can tamper with the in-guest snapshots, so the report is evidence, not a verdict. Guest-derived data is parsed on the host only by `fc-audit` under a non-admin token. Networked audits reach the internet through the existing egress proxy, with the usual host and private-range blocking.
