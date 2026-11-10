# Proposal

## Why

The sandbox can run untrusted code, but not an AI agent that works on its own inside it: one that inspects a malicious payload, or is asked to try to escape the sandbox so we learn where its boundaries are. Running such an agent safely is hard because the agent needs a model API and an API key, and both are exactly what a hostile payload, or an agent told to misbehave, would abuse. With the guest output airlock and the MCP server in place, the remaining piece is a controlled way for an agent in the guest to reach its model.

## What Changes

- Add a **host-side LLM gateway** (`fc-llm-gateway`): one process per agent run, running in `fc-host` without root, reachable from the guest only through a single vsock port. It speaks one provider's API to one upstream, injects the real API key (the guest only ever holds a dummy key), allows only that provider's model endpoints and the configured models, enforces request, size, time and budget limits, and logs every call to `runs/<run-id>/llm.log`.
- Providers: **Anthropic** (Claude Code), **OpenAI** (Codex CLI) and a **local Ollama** server on the host (through its OpenAI-compatible API).
- Add an **agent image**: a second Linux rootfs that setup builds from the base image plus pinned Node.js and pinned agent CLIs (Claude Code, Codex CLI), with a guest-side shim from `127.0.0.1:8080` to the gateway's vsock port. Agent VMs boot from it; everything else uses the unchanged base image.
- **Gateway mode (default):** agent VMs run in `isolated` mode, with no network adapter. The gateway is their only way out. Results, including the agent's transcript, leave through the existing guest output airlock.
- **Direct mode (explicit opt-in, `-AgentDirect`):** for trusted work, the agent runs in a `networked` VM with the real API key inside the guest and no gateway. Documented as unsafe for untrusted payloads; Anthropic and OpenAI only, since host protection blocks a host Ollama.
- New entry points: `fc.ps1 run -Agent <profile> -Prompt <text>|-PromptFile <file>` (headless), `fc.ps1 shell -Agent <profile>` (interactive, gateway wired up), and an `agent` option on the MCP `sandbox_run` tool so a host agent can hand work to an inside agent (gateway mode only).
- API keys come from the Windows host (environment variables, or a key file outside the repository) and are handed to the gateway, or in direct mode to the guest, without appearing on any command line.
- Linux guests only; Windows guests stay out of scope (no vsock, and Node.js-based agent CLIs are not proven on Nano Server).

## Capabilities

### New Capabilities
- `llm-gateway`: the per-run host-side gateway: its channel to the guest, provider profiles and upstreams, key injection, endpoint and model allowlists, request/size/time/budget limits, hardening against a hostile client, logging, and lifecycle and cleanup.
- `sandbox-agents`: running AI agents in Linux microVMs: the agent image, agent profiles, headless and interactive agent runs, prompt delivery, transcript collection, gateway mode versus explicit direct mode, and how API keys reach the gateway or guest.

### Modified Capabilities
- `sandbox-mcp-tools`: `sandbox_run` gains an optional agent run (profile and prompt) in gateway mode; direct mode is not available through MCP.
- `kvm-host-setup`: setup builds the agent image and the gateway, and `doctor` checks them.

## Impact

- New .NET 10 project for the gateway (published self-contained for `linux-x64`, installed into `/opt/fc-sandbox/bin`), with unit tests.
- `images/`: an agent image build script and pinned agent CLI dependencies (lockfile); `host/versions.env`: pinned Node.js release and checksum.
- `host/bin/fcctl`, `host/lib/*`: agent options on `run` and `shell`, booting from the agent image, starting and stopping a gateway per VM, `cleanup` of gateway processes and sockets; `fc.ps1`: new options and key hand-over.
- `mcp/FcMcp`: the `agent` option on `sandbox_run`.
- Setup downloads more at install time (Node.js, npm packages) and the agent image adds a few GB of disk in `fc-host`; nothing extra is downloaded at run time.
- `tests/smoke`: agent runs against a local fake provider (no real API calls or keys in the smoke suite), gateway refusals, direct mode, cleanup.
- `README.md`: agents, profiles, keys, both modes and their risks.
- Security: the gateway is the first guest-initiated channel to the host. It is new attack surface and is hardened and tested as such.
