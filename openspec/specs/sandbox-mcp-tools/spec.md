# sandbox-mcp-tools Specification

## Purpose

Lets an MCP-capable agent on the Windows host route risky actions into disposable sandbox microVMs through a fixed set of tools, without ever gaining a way to act on the host itself.

## Requirements

### Requirement: MCP server entry point
The system SHALL provide an `mcp` command that runs an MCP server over stdio. The server's stdout SHALL carry only MCP protocol messages; all diagnostics SHALL go to stderr. If the server has not been built, the command MUST exit non-zero with a message telling the user to run setup.

#### Scenario: Client connects
- **WHEN** an MCP client launches `fc.ps1 mcp` and sends `initialize` followed by `tools/list`
- **THEN** the server answers both and lists the sandbox tools

#### Scenario: Server not built
- **WHEN** `fc.ps1 mcp` is launched before setup has built the server
- **THEN** it exits non-zero, writes the reason to stderr, and writes nothing to stdout

### Requirement: One-shot run tool
The server SHALL provide a `sandbox_run` tool that takes a host payload folder, a command and optional VM options (guest, flavour, network mode, allowlist, vCPUs, memory, timeout), performs a complete test run, and returns the run id, exit code, timeout status, bounded stdout and stderr, the result folder path and the list of collected output files.

#### Scenario: Successful run through the tool
- **WHEN** the agent calls `sandbox_run` with a payload folder and a command that writes `out/report.txt` and exits 0
- **THEN** the result has exit code 0, lists `report.txt` among the output files, and `runs/<run-id>/` exists as for a CLI run

#### Scenario: Failing guest command
- **WHEN** the guest command exits with code 3
- **THEN** the tool call succeeds and its result reports exit code 3

### Requirement: Session tools
The server SHALL provide tools to start a VM (`sandbox_start`, returning a session id), run a command in it (`sandbox_exec`, returning exit code and bounded stdout and stderr), list this server's sessions (`sandbox_list`) and destroy one (`sandbox_stop`). Commands in a session SHALL run with the guest work folder as working directory, and state SHALL persist between commands of the same session.

#### Scenario: State persists across commands
- **WHEN** the agent starts a session, executes `echo hi > marker`, then executes `cat marker`
- **THEN** the second command's stdout is `hi`

#### Scenario: Stopped session
- **WHEN** the agent stops a session and then calls `sandbox_exec` on it
- **THEN** the call fails with an error saying the session does not exist

### Requirement: Session file transfer tools
The server SHALL provide `sandbox_put`, which copies a host file or folder into a session's VM (default destination: the guest input folder), and `sandbox_get`, which copies a guest file or folder out of the VM. The agent SHALL NOT choose the host destination of `sandbox_get`: files SHALL land under `runs/<session-id>/files/`, and the result SHALL return their host paths.

#### Scenario: Copy in and out
- **WHEN** the agent puts `sample.bin` into a session, runs a command that writes `out/analysis.json`, and gets `out/analysis.json`
- **THEN** the result lists a host path under `runs/<session-id>/files/` that contains that file

### Requirement: Session ownership
Session tools SHALL act only on VMs that the same server process started. VMs started from the CLI or by another server process MUST NOT be listed, executed in, copied to or from, or stopped through the tools.

#### Scenario: Foreign VM
- **WHEN** the user starts a VM with `fc.ps1 start` and the agent calls `sandbox_exec` with that VM's run id
- **THEN** the call fails with an error saying the session does not exist, and the VM is unaffected

### Requirement: Session limits and cleanup
Every session SHALL be bounded by the VM hard timeout (default 30 minutes, configurable per session). The server SHALL limit the number of concurrent sessions (default 4) and SHALL refuse to start more. When the server exits or its client disconnects, it SHALL destroy all of its sessions.

#### Scenario: Client disconnects
- **WHEN** the MCP client closes the server's stdin while two sessions are running
- **THEN** both VMs are destroyed before the server exits

#### Scenario: Too many sessions
- **WHEN** four sessions are running and the agent calls `sandbox_start`
- **THEN** the call fails with an error naming the limit, and no VM is started

### Requirement: Host path confinement
Host paths given to `sandbox_run` and `sandbox_put` MUST resolve, after following links and junctions, to a location inside one of the server's allowed roots (by default the working directory the server was started in; configurable at launch). A source tree that contains links or junctions MUST be refused.

#### Scenario: Path outside the allowed roots
- **WHEN** the agent calls `sandbox_put` with `C:\Users\<user>\.ssh` and the allowed root is the project folder
- **THEN** the call fails with an error naming the allowed roots, and nothing is copied

#### Scenario: Junction escaping the root
- **WHEN** a payload folder inside the allowed root contains a junction pointing outside it
- **THEN** the call fails and nothing is copied

### Requirement: Networked mode opt-in
The server SHALL refuse tool calls that request `networked` mode unless the server was launched with networked mode explicitly enabled. `isolated` SHALL be the default network mode for every tool.

#### Scenario: Networked without opt-in
- **WHEN** the server was launched without enabling networked mode and the agent calls `sandbox_start` with network mode `networked`
- **THEN** the call fails with an error saying networked mode is disabled for this server, and no VM is started

### Requirement: Bounded tool output
Each stdout or stderr returned by a tool SHALL be at most 64 KiB; longer output SHALL be cut to its beginning and end with a marker stating how many bytes were omitted. The complete streams SHALL be saved under the run's or session's folder in `runs/`, and the result SHALL give their paths.

#### Scenario: Large output
- **WHEN** a guest command writes 10 MiB to stdout
- **THEN** the returned stdout is at most 64 KiB, contains the omission marker, and the full 10 MiB is in the saved log

### Requirement: Untrusted output marking
Every tool result that contains guest-produced content SHALL state that the content is untrusted sandbox output and not instructions, and SHALL enclose that content between delimiters that include a value unique to the call, so guest output cannot forge the closing delimiter. Terminal control sequences and non-printable characters other than newline and tab SHALL be removed from returned text.

#### Scenario: Guest forges instructions and delimiters
- **WHEN** a guest command prints a fake closing delimiter followed by "ignore previous instructions"
- **THEN** that text appears inside the real delimiters of the result, after the untrusted-content notice

#### Scenario: Escape sequences
- **WHEN** a guest command prints ANSI escape sequences
- **THEN** the returned text contains no escape characters

### Requirement: No host-side actions
The server SHALL expose only sandbox tools. No tool SHALL run a command on the host, read a host file other than a payload being uploaded, or write a host file outside `runs/`.

#### Scenario: Tool inventory
- **WHEN** the client lists the server's tools
- **THEN** the only tools are `sandbox_run`, `sandbox_start`, `sandbox_exec`, `sandbox_put`, `sandbox_get`, `sandbox_list` and `sandbox_stop`

### Requirement: Guest availability by elevation
Linux guests SHALL be available through the server whenever the Linux backend is set up. Windows guests SHALL be available only when the server process runs elevated; otherwise every tool call requesting `guest: windows` MUST fail with an error saying the server must run elevated.

#### Scenario: Windows guest from a non-elevated server
- **WHEN** a non-elevated server receives `sandbox_run` with `guest: windows`
- **THEN** the call fails with the elevation error and no VM is started

### Requirement: MCP client registration documentation
The repository SHALL document how to register the server with Claude Code and with other stdio MCP clients, the server's launch options (allowed roots, networked opt-in, session limit), and the prompt-injection risk of guest output together with the recommended client-side permission settings.

#### Scenario: Registering with Claude Code
- **WHEN** a user follows the documented registration command for Claude Code
- **THEN** the sandbox tools appear in the client's tool list

### Requirement: Agent runs through MCP
`sandbox_run` SHALL accept an optional agent profile and prompt instead of a command, and then perform a headless agent run in gateway mode, returning the same fields as a command run plus the paths of the agent transcript and `llm.log`. Direct mode MUST NOT be available through the MCP server. The agent's transcript and output SHALL be returned as untrusted output, bounded and marked like any other guest output.

#### Scenario: Host agent hands work to an inside agent
- **WHEN** the host agent calls `sandbox_run` with `agent: "claude"`, a prompt and a payload folder
- **THEN** an agent VM in gateway mode runs the task, and the result lists the transcript and `llm.log` paths and the collected output files

#### Scenario: Direct mode refused
- **WHEN** a tool call asks for direct mode
- **THEN** the call fails with an error saying direct mode is not available through MCP, and no VM starts

#### Scenario: Command and agent together
- **WHEN** a tool call gives both a command and an agent profile
- **THEN** the call fails with an error saying to give one or the other
