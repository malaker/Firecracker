# sandbox-agents Specification

## Purpose

Runs AI coding agents (Claude Code, Codex CLI) inside disposable Linux microVMs, to inspect payloads or probe the sandbox from within, with the model reached through the LLM gateway by default.

## Requirements

### Requirement: Agent profiles
The system SHALL provide agent profiles that each name a client and a provider: `claude` (Claude Code, Anthropic), `codex` (Codex CLI, OpenAI) and `codex-ollama` (Codex CLI against a host Ollama server). Each profile SHALL define the client's default model and the model allowlist the gateway enforces. Agent runs SHALL be available for Linux guests only; requesting an agent with `-Guest windows` MUST fail with exit code 125 before anything starts.

#### Scenario: Unknown profile
- **WHEN** the user runs `fc.ps1 run -Agent gemini -Prompt "x"`
- **THEN** the command exits 125 naming the available profiles

#### Scenario: Windows guest
- **WHEN** the user runs `fc.ps1 run -Agent claude -Guest windows -Prompt "x"`
- **THEN** the command exits 125 saying agents need Linux guests

### Requirement: Agent image
Agent VMs SHALL boot from a separate agent image that contains the base image plus pinned versions of Node.js and the agent clients, and a guest-side shim from `127.0.0.1:8080` to the gateway's vsock port. VMs without `-Agent` SHALL keep booting from the unchanged base image. Agent runs SHALL need no network access to install anything at run time.

#### Scenario: Clients present
- **WHEN** an agent VM boots
- **THEN** `claude --version` and `codex --version` report the pinned versions

#### Scenario: Ordinary runs unchanged
- **WHEN** the user runs `fc.ps1 run` without `-Agent`
- **THEN** the VM boots from the base image as before

### Requirement: Headless agent run
`fc.ps1 run -Agent <profile>` SHALL take the task as `-Prompt <text>` or `-PromptFile <file>`, upload the prompt and the optional payload, run the profile's client non-interactively in `/work` with permission to act without asking, and end the run when the client exits or the timeout is reached. The run SHALL exit with the client's exit code and produce the usual results in `runs/<run-id>/`.

#### Scenario: Agent inspects a payload
- **WHEN** the user runs `fc.ps1 run -Agent claude -Payload .\sample -PromptFile .\triage.md`
- **THEN** the agent works on `/work/in`, its findings written to `/work/out` appear in `runs/<run-id>/out/`, and the run exits with the client's exit code

#### Scenario: Prompt with special characters
- **WHEN** the prompt contains quotes, newlines and shell metacharacters
- **THEN** the client receives it unchanged

### Requirement: Agent transcript
Every headless agent run SHALL save the client's machine-readable transcript (Claude Code `stream-json`, Codex `--json` events) as `out/agent-transcript.jsonl`, collected through the guest output airlock like any other output.

#### Scenario: Transcript after a run
- **WHEN** a headless agent run finishes or times out
- **THEN** `runs/<run-id>/out/agent-transcript.jsonl` contains the events produced until then

### Requirement: Interactive agent shell
`fc.ps1 shell -Agent <profile>` SHALL open an interactive shell in an agent VM whose client is configured for the gateway (or, in direct mode, for the provider), so the user can run the client by hand. The VM and its gateway SHALL be destroyed when the shell exits.

#### Scenario: Run the client by hand
- **WHEN** the user opens `shell -Agent claude` and runs `claude`
- **THEN** Claude Code starts and its requests go through the gateway

### Requirement: Gateway mode by default
Unless direct mode is requested, every agent VM SHALL run in gateway mode: `isolated` network mode, a dummy key in the guest, and the LLM gateway as the only way to the model. Requesting `-Net networked` together with `-Agent` in gateway mode SHALL be refused.

#### Scenario: No network in gateway mode
- **WHEN** an agent in gateway mode runs `curl https://example.com`
- **THEN** the request fails, while its model calls succeed

### Requirement: Explicit direct mode
`-AgentDirect` SHALL run the agent without a gateway in a `networked` VM (with the usual host protection and optional allowlist), with the provider's real API key in the guest environment. It SHALL be available for the Anthropic and OpenAI profiles only, SHALL print a warning that the key is inside the VM, and SHALL record `agent_mode: direct` in `meta.json`.

#### Scenario: Direct mode warning
- **WHEN** the user runs `fc.ps1 run -Agent claude -AgentDirect -Prompt "x"`
- **THEN** a warning says the API key is inside the VM and the run's `meta.json` records `agent_mode: direct`

#### Scenario: No direct mode for Ollama
- **WHEN** the user requests `-AgentDirect` with the `codex-ollama` profile
- **THEN** the command exits 125, because host protection blocks the host's Ollama server

### Requirement: API key hand-over
API keys SHALL be read on the Windows host from `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, or from a key file under the user's profile outside the repository, and handed to the gateway (gateway mode) or the guest (direct mode) without appearing in any command line, process list, log, result file or `meta.json`. A missing key SHALL fail the run with exit code 125 before any VM starts.

#### Scenario: Key not on any command line
- **WHEN** an agent run is in progress
- **THEN** no process command line on the Windows host or in `fc-host` contains the key

#### Scenario: Missing key
- **WHEN** `ANTHROPIC_API_KEY` is not set and no key file exists, and the user runs `-Agent claude`
- **THEN** the command exits 125 naming the variable and the key file, and no VM starts

### Requirement: Agent run metadata
`meta.json` of an agent run SHALL record the profile, client and its version, provider, model, agent mode (`gateway` or `direct`) and, in gateway mode, the gateway's request and token totals.

#### Scenario: Metadata after a gateway run
- **WHEN** a gateway-mode agent run finishes
- **THEN** `meta.json` contains `agent.profile`, `agent.client_version`, `agent.mode: gateway` and the request and token totals
