# Proposal

## Why

Coding agents running on the Windows host (Claude Code, ChatGPT/Codex clients, Ollama-backed agents) regularly need to do risky things: detonate a sample, run an exploit PoC, execute an untrusted installer. Today they either do it on the host or a human has to drive `fc.ps1` by hand. Exposing the sandbox as a set of MCP tools lets any MCP-capable agent route those actions into a disposable microVM. This is the first of two planned changes; the second (agents running *inside* the sandbox behind a host-side LLM gateway) builds on it.

## What Changes

- Add an MCP server (stdio transport) that wraps the existing controllers (`fc.ps1` / `fcctl` / `fcctl-win.ps1`) and exposes sandbox tools:
  - one-shot run: upload a payload, run a command, return exit code, bounded stdout/stderr and the result folder path
  - sessions: start a VM, execute commands in it, copy files in and out, list, and stop
- Add file transfer for *started* VMs (copy a host file or folder into the guest, copy a guest path out to the run folder) to the CLI on both backends, since today only `run` uploads and collects files. Copies out of a guest go through the airlock from `guest-output-airlock`, which this change depends on and follows.
- Treat all guest output as untrusted data: tool results are clearly marked as sandbox output, bounded in size, and the server offers no tool that acts on the host beyond the sandbox's own commands and run folders.
- Host paths the agent hands to the server must lie inside allowed roots (by default the folder the server was started in), and `networked` mode is refused unless the server is launched with it explicitly enabled.
- Sessions created through the server are bounded by the existing hard timeout and are destroyed when the server exits.
- Linux guests are supported unconditionally. Windows guests are supported only when the server process runs elevated; otherwise Windows-guest tool calls are refused with a clear error.
- Document how to register the server with common MCP clients.

## Capabilities

### New Capabilities
- `sandbox-mcp-tools`: the MCP tool surface over the sandbox: tool set and parameters, session ownership and cleanup, output bounding and untrusted-output marking, guest-OS availability, and client registration.

### Modified Capabilities
- `sandbox-test-runs`: adds copying files into and out of a started VM on both guest backends, alongside the existing one-shot payload upload and result collection.

## Impact

- New server component in the repository plus its registration docs; no change to the isolation, network or egress model.
- `host/bin/fcctl`, `windows/fcctl-win.ps1` and `fc.ps1`: new file-transfer commands for started VMs.
- Depends on `guest-output-airlock` (must be implemented first): `get` reuses its airlock instead of unpacking guest archives on the host.
- `tests/smoke` (and `tests/smoke-win` for elevated runs): coverage for the new commands and for the MCP tools.
- `README.md`: new commands and the MCP integration section.
- Security: introduces a prompt-injection path from guest output into the host agent; mitigated by output marking and bounding and by exposing no host-side actions, but the host agent's own permission settings remain the final control.
