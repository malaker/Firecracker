# Tasks

## 1. CLI file transfer for started VMs (Linux backend)

- [x] 1.1 Confirm `guest-output-airlock` is implemented and exposes a Linux transfer entry point (source VM, guest path, host destination); verify by running its smoke tests
- [x] 1.2 Add `fcctl put <run-id> <src> [guest-dir]` (file or folder, default `/work/in`) and `fcctl get <run-id> <guest-path> <local-dir>` (put via `upload_dir`, get via the airlock transfer), exiting 125 for a VM that is not running and non-zero with the path named when the guest path is missing; update `usage()`; verify by running both against a `start`-ed VM
- [x] 1.3 Add `put` and `get` to `fc.ps1` (ValidateSet, `-Dest`, host path translation via `ConvertTo-WslPath`, default get destination `runs\<run-id>\files\`); verify `.\fc.ps1 put`/`get` round-trips a file with a Linux VM
- [x] 1.4 Add `tests/smoke/files.sh` (put file, put folder, get folder, missing path, stopped VM, guest symlink refused) and register it in `tests/smoke/all.sh`; verify the Linux smoke suite passes

## 2. CLI file transfer for started VMs (Windows backend)

- [ ] 2.1 Generalise `Send-FcWinGuestFiles` in `windows/lib/runtime.ps1` for single files (put direction), and confirm the Windows airlock transfer entry point from `guest-output-airlock` handles single guest files and folders for `get`; verify by putting a single file and getting it back through the airlock
- [ ] 2.2 Add `put` and `get` cases to `windows/fcctl-win.ps1` and its usage text, and pass `-Dest` through `fc.ps1`; verify round-trip against a `start -Guest windows` VM in an elevated prompt
- [ ] 2.3 Add `tests/smoke-win/files.ps1` covering the same cases as 1.4 and call it from `tests/smoke-win/all.ps1`; verify the Windows smoke suite passes on the docker runtime and, where supported, containerd
- [ ] 2.4 Document `put` and `get` in `README.md` (command list, defaults, contained extraction) and in both usage texts; verify the documented examples run as written

## 3. Run info file for `run`

- [ ] 3.1 Add optional `--run-info-file` to `fcctl run` and `-RunInfoFile` to `fcctl-win.ps1 run`, writing `{"run_id","results_dir"}` (Windows path) as soon as the VM has an id, and pass it through `fc.ps1`; verify the file appears during a run on both guests and that runs without it behave as before

## 4. MCP server scaffolding and build

- [x] 4.1 Create `mcp/FcMcp` (`fc-mcp.exe`, `net10.0-windows`, `ModelContextProtocol` pinned to an exact stable version) and `mcp/FcMcp.Tests` (xUnit) with an `Mcp.slnx`; verify `dotnet build` and an empty `dotnet test` succeed
- [x] 4.2 Add `mcp/install-mcp.ps1` that publishes to `%LOCALAPPDATA%\fc-sandbox\mcp\` only when sources are newer than the output and warns and continues without a .NET 10 SDK; call it from both setup paths in `fc.ps1`; verify a second setup reports the server up to date
- [x] 4.3 Add `fc.ps1 mcp [-AllowRoot] [-AllowNetworked] [-MaxSessions]` that starts the built server with the repo root, or exits non-zero with a stderr message when it is missing or stale; verify by launching with and without a build and checking that stdout is empty on failure

## 5. MCP server policy layer

- [x] 5.1 Implement the CLI runner (child `powershell.exe -File fc.ps1`, argument list, captured stdout/stderr files, kill on timeout); verify unit tests with a stub script for exit codes, timeouts and no stdout leakage
- [x] 5.2 Implement host path confinement (final-path resolution, root prefix match, reparse-point walk); verify unit tests for inside/outside paths, `..`, case differences, a junction escaping the root, and a junction inside the tree
- [x] 5.3 Implement output shaping (32 KiB head + tail with omission marker on UTF-8 boundaries, control and escape stripping, per-call nonce delimiters and untrusted notice); verify unit tests including a forged closing delimiter, ANSI sequences and a 10 MiB stream
- [x] 5.4 Implement the session table (ownership, max sessions, exec counter, parallel stop-all with a deadline on stdin EOF / shutdown / console close); verify unit tests with a fake runner for foreign ids, limit refusal and stop-all on disconnect
- [x] 5.5 Implement elevation and networked gating; verify unit tests that Windows-guest and networked requests are refused before any child process starts

## 6. MCP tools

- [x] 6.1 Implement `sandbox_run` on top of `run -RunInfoFile`, returning run id, exit code, timeout flag, shaped stdout/stderr, result folder and output file list; verify an integration test against a real Linux VM using `samples/hello`
- [x] 6.2 Implement `sandbox_start`, `sandbox_exec` (Linux `cd /work &&` prefix, per-exec logs under `runs/<session-id>/exec/<n>/`, exec timeout), `sandbox_list` and `sandbox_stop`; verify an integration test that state persists between execs and a stopped session is rejected
- [x] 6.3 Implement `sandbox_put` and `sandbox_get` on the CLI commands from groups 1-2, with confinement on put and the fixed `runs/<session-id>/files/` destination on get; verify an integration test that round-trips a file and refuses a path outside the root
- [ ] 6.4 Add a stdio end-to-end smoke script `tests/smoke-mcp/mcp.ps1` that launches `fc.ps1 mcp`, sends `initialize`, `tools/list` (asserting exactly the seven tools), a `sandbox_run`, and a session round-trip, then closes stdin and asserts no VMs remain via `fc.ps1 list`; verify it passes for Linux guests and, from an elevated prompt, Windows guests

## 7. Documentation

- [x] 7.1 Add an MCP section to `README.md`: prerequisites (.NET 10 SDK), `fc.ps1 mcp` options, `claude mcp add` registration plus a generic stdio client config, tool reference, elevation rule for Windows guests, networked opt-in, cleanup behaviour, and the prompt-injection risk with recommended client permission settings; verify the documented Claude Code registration makes the tools appear in the client
- [x] 7.2 Add the MCP server's risks to the README's "Security considerations and limitations" section; verify the section names prompt injection, elevated-client exposure and hard-kill cleanup via the watchdog

## Workflow follow-up

- Run the full Linux, Windows and MCP smoke suites before review.
- Archive the change after review, then capture the follow-up change for in-sandbox agents behind a host LLM gateway.
