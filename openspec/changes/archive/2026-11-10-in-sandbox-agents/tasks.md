# Tasks

## 1. Spikes

- [x] 1.1 Guest-to-host vsock channel: in a `start`-ed VM run `socat` to `VSOCK-CONNECT:2:8080` and check it reaches a listener at `<jail>/root/v.sock_8080`, trying the hard-linked socket (design D2 option a) first; check a second VM's uid cannot connect; verify by recording the chosen scheme and the commands in a "Spike results" note in design.md
- [x] 1.2 Agent clients: in a scratch Ubuntu VM install the pinned Node.js and the current Claude Code and Codex CLI with `npm ci --ignore-scripts`, and find out whether they run without install scripts (and, if not, which files must be pinned in `versions.env`), the exact headless flags and JSON transcript options, the settings that point them at `http://127.0.0.1:8080` with a dummy key, the Codex settings for an OpenAI-compatible Ollama endpoint, and each client's default and helper model names; verify by recording the results in the "Spike results" note and drafting `host/agents/profiles.json`

## 2. LLM gateway

- [x] 2.1 Create `gateway/FcGateway` (`fc-llm-gateway`, `net10.0`, ASP.NET Core) and `gateway/FcGateway.Tests` with `Gateway.slnx`; verify `dotnet build` and `dotnet test` succeed
- [x] 2.2 Load a profile from `profiles.json` (upstream, endpoints, model patterns, limits, key env) and read the key from stdin; verify unit tests for valid and invalid profiles and that a missing key fails before listening
- [x] 2.3 Kestrel on a Unix socket with explicit limits (header size and count, body size, connections, timeouts) and socket mode `0660`; verify unit tests that oversized headers, too many connections and malformed HTTP close only the offending connection
- [x] 2.4 Forwarding: endpoint allowlist (403), model check on the request JSON (403), rebuilt upstream request with header allowlist, credential stripping and injection (none for Ollama), fixed upstream regardless of `Host` or absolute URL; verify unit tests against an in-process fake upstream, including that the fake upstream never sees guest credentials and always sees the real key
- [x] 2.5 Streaming and limits: SSE pass-through with flush, request count, body size (413), total response size, per-request timeout, token budget from usage in JSON and SSE for both API styles (429 once spent); verify unit tests for each limit and that events arrive before the response ends
- [x] 2.6 `llm.log` (one line per request: time, method, path, model, decision, reason, upstream status, bytes, usage; no bodies) and a totals file at exit; verify unit tests that log lines and error responses never contain the key
- [x] 2.7 `FC_GATEWAY_TEST_UPSTREAM` override accepted only for `http://127.0.0.1:<port>`; verify unit tests that any other value is rejected

## 3. Agent image and setup

- [x] 3.1 Add `NODE_VERSION`/`NODE_URL`/`NODE_SHA256` (and any client files found in 1.2) to `host/versions.env`, and `images/agent/package.json` plus the committed `package-lock.json` pinning the clients; verify `npm ci --ignore-scripts` on a clean folder reproduces the lockfile
- [x] 3.2 Add `images/build-agent-rootfs.sh` (base squashfs + Node.js + `npm ci --ignore-scripts` + `fc-llm-shim` unit + `/usr/local/bin/fc-agent` wrapper, `AGENT_ROOTFS_SIZE`), and build it from `provision.sh` with its own stamp, keeping the previous image if a checksum fails; verify setup builds it, a re-run skips it, and a tampered `NODE_SHA256` stops setup naming the file
- [x] 3.3 Publish `fc-llm-gateway` (linux-x64, self-contained, single file) from setup, the way `install-airlock.ps1` does, install it and `profiles.json` into `/opt/fc-sandbox`, add `-NoAgentImage` and `-OllamaUrl` to `fc.ps1 setup`, and add the doctor checks (agent image, gateway; Ollama URL as WARN); verify doctor passes after setup and fails with the hint when either is removed

## 4. Controller: agent VMs and the gateway

- [x] 4.1 `vm_create`/`boot_vm_with` take an image (`base` or `agent`); agent VMs boot from `agent-rootfs.ext4`; verify a VM started with the agent image reports the pinned client versions and an ordinary VM still boots the base image
- [x] 4.2 Start a gateway per agent VM (gateway uid `210000+slot`, socket scheme from 1.1, key on stdin) before boot, store its pid in VM state, stop it in `vm_destroy`, and extend `cleanup` to kill gateway uids and remove gateway sockets and stashed keys; verify by killing `fcctl` during an agent run and checking cleanup leaves no gateway process, socket or key file
- [x] 4.3 `fcctl _stash-key <nonce>` (key on stdin, `0600` under `/var/lib/fc-sandbox/keys/`, deleted once read) and `--key-ref`; `fc.ps1` reads the key from the profile's environment variable or `%USERPROFILE%\.fc-sandbox\keys\<provider>.key` and stashes it through a separate `wsl.exe` call; verify during a run that no process command line on Windows or in `fc-host` contains the key, and that a missing key exits 125 before any VM starts
- [x] 4.4 `fcctl run --agent P --prompt-file F` and `fc.ps1 run -Agent P -Prompt|-PromptFile [-Model] [-AgentTokenBudget]`: upload the prompt as a file, run `fc-agent headless`, collect the transcript through the airlock, copy `llm.log` and the totals into the results, and write `meta.json.agent`; refuse unknown profiles, `-Guest windows` and `-Net networked` in gateway mode with exit 125; verify against the fake provider that the run exits with the client's exit code and `runs/<id>/` contains `out/agent-transcript.jsonl`, `llm.log` and `meta.json.agent`
- [x] 4.5 `shell -Agent P` (gateway wired up, client environment set, VM and gateway destroyed on exit); verify by hand that the client starts and its requests show up in the gateway log
- [x] 4.6 Direct mode: `-AgentDirect` implies `networked` (passing `-Allow` through), puts the key into the guest over SSH stdin, prints the warning, records `agent.mode: direct`, and is refused for `codex-ollama`; verify a direct run reaches the fake provider over the network, and the refusal for `codex-ollama`
- [x] 4.7 Add `tests/smoke/agents.sh` (fake provider in `fc-host`; from an agent VM: requests through `127.0.0.1:8080` succeed; endpoint, model, size and budget refusals; `curl https://example.com` fails; no key in the guest environment or files; `llm.log` lines; transcript collected; gateway gone after the run; cleanup after a killed controller; direct mode; key not in process lists) and register it in `tests/smoke/all.sh`; verify the full Linux smoke suite passes

## 5. MCP

- [x] 5.1 `sandbox_run` gains `agent` and `prompt` (mutually exclusive with `command`; no direct-mode option), writes the prompt to a scratch file, calls `fc.ps1 run -Agent … -PromptFile …`, and returns `transcript_path` and `llm_log_path` with output bounded and marked as usual; verify unit tests for the argument checks and an opt-in integration test against the fake provider
- [x] 5.2 Extend `tests/smoke-mcp/mcp.ps1` with an agent run against the fake provider, and with the refusal when both `command` and `agent` are given; verify the MCP smoke test passes

## 6. Documentation and live check

- [x] 6.1 Update `README.md`: agents and profiles, gateway mode versus direct mode (with the key-in-VM warning), key setup (environment variables or key files), Ollama setups, `llm.log` and `meta.json.agent`, budgets, the MCP `agent` option, and the new risks in "Security considerations and limitations" (gateway as new surface, data sent to providers, direct mode); verify every documented command runs as written against the fake provider
- [ ] 6.2 (Deferred 2026-11-10: no API keys available yet; run `tests/smoke/agents-live.ps1` with `FC_AGENT_LIVE=1` once there are.) Live check with real keys (`FC_AGENT_LIVE=1`): one short headless run each for `claude` and `codex`, and for `codex-ollama` when a local Ollama is available; verify each finishes, the transcript and `llm.log` look right, and record the results in design.md

## Workflow follow-up

- Run the Linux smoke suite, the MCP smoke test and all unit tests before review.
- Archive the change after review; a later change can add Windows guests by giving them a channel to the same gateway.
