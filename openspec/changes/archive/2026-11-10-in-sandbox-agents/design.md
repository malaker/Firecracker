# Design

## Context

See proposal.md (Why). Facts about the current system that shape this design:

- **Linux VMs** run under the jailer in `/srv/jailer/firecracker/<id>/root` as uid `64000+slot`. Each has a hybrid vsock with `uds_path: "/v.sock"` inside the chroot. The controller reaches the guest's sshd by connecting to that socket (`CONNECT 22`). Firecracker's hybrid vsock also supports the other direction: a guest connecting to CID 2 port P makes Firecracker connect to the Unix socket `<uds_path>_P`, so `<jail>/root/v.sock_8080` for port 8080. Today nothing listens there, so guests have no guest-initiated channel at all.
- **The base image** is built by `images/build-rootfs.sh` from the pinned Ubuntu 24.04 squashfs (`ROOTFS_SIZE=2G`). It already has `socat`, used for the vsock-to-sshd relay as a systemd unit, and `python3`.
- **Pinned downloads** live in `host/versions.env` and are verified by `provision.sh`'s `fetch`. Rebuilds are driven by stamp files.
- **The guest output airlock** collects `/work/out`; `run` writes `meta.json` with `collection`. Per-transfer unprivileged uids already exist (`FC_UNPACK_UID_BASE=200000`, claimed with `mkdir`).
- **`fc.ps1`** passes arguments to `fcctl` as a base64 blob on the `wsl.exe` command line, so anything passed that way is visible in process lists. Keys must never travel that way.
- **The MCP server** calls `fc.ps1` through `-EncodedCommand` and inherits the MCP client's environment.

## Goals / Non-Goals

**Goals:**
- An agent in gateway mode has exactly one way out (the gateway) and never holds a real key.
- Profiles are data, not code paths, so adding a provider or client later is mostly configuration.
- The smoke suite tests the whole path without real API keys or network calls to providers.

**Non-Goals:**
- Windows guests. A later change could add a guest-to-host channel over the exec channel (the `fc-relay` pattern) and reuse the gateway unchanged.
- Gateway features beyond what the spec needs: no response caching, prompt filtering or content inspection.
- Choosing which model is best for which task. Profiles carry defaults; `-Model` overrides within the allowlist.
- Direct mode through MCP.

## Decisions

### D1. Gateway: ASP.NET Core (Kestrel) on a Unix socket, .NET 10, self-contained linux-x64
New projects `gateway/FcGateway` (exe `fc-llm-gateway`) and `gateway/FcGateway.Tests`.
- Kestrel listens on the per-VM Unix socket (D2), with limits set explicitly: header size and count, request line, body size, concurrent connections, keep-alive and request-header timeouts. It's a maintained, hardened HTTP parser, which matters because the client may be hostile.
- Forwarding uses one `HttpClient` (`SocketsHttpHandler`) bound to the profile's single upstream base URL. Requests are rebuilt from scratch: method and path from the allowlist, body bytes, a small header allowlist (content type, `anthropic-version`, `anthropic-beta`, `accept`), plus the injected credential. Guest headers are never copied wholesale, and the `Host` header and absolute URLs from the guest are ignored.
- Responses use `ResponseHeadersRead` and stream to the guest with a flush per chunk, so SSE works. Size counters cut a response off at the limit.
- Published self-contained single-file (not trimmed, to avoid ASP.NET Core trimming warnings), so `fc-host` needs no .NET runtime.
- *Alternatives:* a hand-written HTTP proxy (rejected: our own parser for hostile input), nginx or socat plus scripts (rejected: key injection, model allowlist and budgets need code anyway), YARP (rejected: more surface than one fixed upstream needs).

### D2. Guest-to-host channel (spike first)
- **Guest:** the agent image has a systemd unit `fc-llm-shim` running `socat TCP-LISTEN:8080,bind=127.0.0.1,fork,reuseaddr VSOCK-CONNECT:2:8080`. Clients point at `http://127.0.0.1:8080`.
- **Host:** the gateway listens on a socket that Firecracker reaches as `/v.sock_8080` inside its chroot, i.e. `<jail>/root/v.sock_8080`.
- **Permissions:** only that VM's Firecracker (uid/gid `64000+slot`) may connect. The gateway runs as `FC_GATEWAY_UID_BASE` (210000) + slot, with primary gid `64000+slot`, and creates the socket with mode `0660`. Other VMs have other uids, and their chroots cannot see this path.
- **Open point for the spike (task 1.1):** how the gateway's socket gets into the jail root, which the gateway uid cannot write to. Candidates: (a) the gateway listens in `/var/lib/fc-sandbox/gw/<id>/llm.sock` and `fcctl` hard-links the socket inode into `<jail>/root/v.sock_8080` (same filesystem, so `connect()` reaches the listener); (b) `fcctl` pre-creates `<jail>/root` group-writable for the gateway's gid. The spike checks that a guest `VSOCK-CONNECT:2:8080` reaches the listener and that another VM's uid cannot, and picks (a) unless it fails. Either way the approach and the tasks stay the same.
- The VM keeps `isolated` network mode: no tap device, no nftables chain.

### D3. Profiles as data
`host/agents/profiles.json` is installed to `/opt/fc-sandbox/agents/` and read by `fcctl` and the gateway:
```json
{ "claude":       { "client": "claude", "provider": "anthropic", "upstream": "https://api.anthropic.com",
                    "default_model": "claude-sonnet-4-5", "models": ["claude-*"],
                    "endpoints": ["POST /v1/messages", "POST /v1/messages/count_tokens"],
                    "key_env": "ANTHROPIC_API_KEY", "direct": true },
  "codex":        { "client": "codex", "provider": "openai", "upstream": "https://api.openai.com", ... },
  "codex-ollama": { "client": "codex", "provider": "ollama", "upstream": "ollama", "direct": false, ... } }
```
- Model allowlists are patterns (`claude-*`), because clients also call smaller helper models. Default limits are per profile: 500 requests, 16 MiB request body, 256 MiB total response, 10 min per request, 2,000,000 tokens. `-AgentTokenBudget` lowers or raises the budget per run.
- The exact model names and client settings are confirmed in the spike (task 1.2) and written into `profiles.json`. That doesn't change the design.

### D4. Agent image (spike first for client installation)
- `images/build-agent-rootfs.sh` starts from the same unpacked squashfs, then adds:
  - the pinned Node.js tarball (`NODE_VERSION`/`NODE_SHA256` in `versions.env`), unpacked to `/opt/node`;
  - the agent clients, installed with `npm ci --ignore-scripts` from the committed `images/agent/package.json` and `package-lock.json`, so npm checks every package against its integrity hash;
  - the `fc-llm-shim` unit and a wrapper `/usr/local/bin/fc-agent` that starts a profile headless or interactively.
- Size: `AGENT_ROOTFS_SIZE` (6G sparse), written to `/opt/fc-sandbox/images/agent-rootfs.ext4` with its own stamp (squashfs hash, Node hash, lockfile hash, script hash, size).
- **Why `--ignore-scripts`:** `npm ci` runs as root in `fc-host` during setup, and package install scripts would run there, which would be a supply-chain path onto the host. If a client turns out to need an install-time download (for example a platform binary), the spike (task 1.2) pins that file's URL and checksum in `versions.env` and the build script installs it explicitly. Package scripts never run on the host.
- `vm_create` gains an image parameter; agent VMs copy `agent-rootfs.ext4`, everything else `rootfs.ext4`.

### D5. Key hand-over
- **Source:** `fc.ps1` reads the key from the profile's `key_env` variable, or else from `%USERPROFILE%\.fc-sandbox\keys\<provider>.key`. Missing means exit 125 before anything starts.
- **Into `fc-host`:** `fc.ps1` makes a second `wsl.exe` call, `fcctl _stash-key <nonce>`, with the key on **stdin**. `fcctl` stores it in `/var/lib/fc-sandbox/keys/<nonce>` (dir `0700`, file `0600`, root). The run's argument blob carries only `--key-ref <nonce>`; the nonce is random, single-use, and the file is deleted once read, or by `cleanup`. The key is never on a command line, so `ps` on either side never shows it, and stdin stays free for `shell -Agent`.
- **Gateway mode:** `fcctl` starts the gateway with the key on its stdin; the gateway reads one line, then serves.
- **Direct mode:** `fcctl` writes the key into the guest over SSH stdin to `/root/.fc-agent/key` (`0600`), and the `fc-agent` wrapper exports it into the client's environment.
- **MCP:** the server's `fc.ps1` child inherits the MCP client's environment, so `ANTHROPIC_API_KEY` set there, or the key file, works unchanged.

### D6. Run flow (gateway mode)
1. `fc.ps1` validates the profile, guest and mode, stashes the key, writes the prompt to a temp file, and calls `fcctl run --agent P --prompt-file F --key-ref N`.
2. `fcctl` allocates the slot, creates the jail, starts the gateway (D2/D5) as the gateway uid, waits until its socket exists, then boots the VM from the agent image. The gateway's pid goes into VM state, so `vm_destroy` and `cleanup` kill it.
3. It uploads the payload to `/work/in` and the prompt to `/work/.fc/prompt.md` (a file, never an argument), then runs `fc-agent headless P` under the usual `timeout`. The wrapper runs, for example, `claude -p "$(cat /work/.fc/prompt.md)" --output-format stream-json --verbose --dangerously-skip-permissions > /work/out/agent-transcript.jsonl`, with `IS_SANDBOX=1` because the client runs as root in the guest. The exact flags come from task 1.2.
4. When the client exits, the airlock collects `/work/out` (transcript included). The gateway is stopped, its log and totals are copied by root into `runs/<id>/llm.log` and `meta.json.agent`, and the VM is destroyed.

`shell -Agent` does steps 1–2, then opens the SSH shell with the profile's environment set; `fc-agent interactive P` is a shortcut inside it.

### D7. Ollama upstream
The gateway runs in `fc-host`, while Ollama normally runs on Windows and listens on `127.0.0.1`, which WSL cannot reach in NAT mode.
- The `codex-ollama` profile's `upstream: "ollama"` resolves at run time to `FC_OLLAMA_URL` from `/opt/fc-sandbox/agents/local.env`. That file is written by setup when `fc.ps1 setup -OllamaUrl <url>` is given; the default is the Windows host's address as seen from WSL, port 11434.
- The README explains the two working setups: Ollama listening on the WSL-facing address (not `0.0.0.0`, which would expose it to the LAN), or Ollama installed inside `fc-host`.
- `doctor` reports the Ollama URL as a WARN-level check, because Ollama is optional.

### D8. Direct mode
`-AgentDirect` implies `-Net networked`, passing `-Allow` through, and boots the same agent image with no gateway and no shim target. The key goes into the guest as in D5. `fc.ps1` prints `WARNING: direct mode - the API key is inside the VM; do not use it with untrusted payloads.` `meta.json.agent.mode = "direct"`. It's refused for profiles with `"direct": false` (Ollama: host protection blocks it, by design).

### D9. MCP
`sandbox_run` gains `agent` and `prompt` (mutually exclusive with `command`). The server writes the prompt to a scratch file and calls `fc.ps1 run -Agent … -PromptFile …`, then adds `transcript_path` and `llm_log_path` to the result. The transcript is guest-produced and is never inlined beyond the usual bounded and marked stdout/stderr. There's no direct-mode parameter at all.

### D10. Testing without providers
- **Unit tests** (`FcGateway.Tests`): header stripping and key injection; endpoint and model allowlists; every limit; SSE pass-through; usage counting for both API styles; malformed HTTP; the key never appearing in logs or errors. All against an in-process fake upstream.
- **Smoke tests** (`tests/smoke/agents.sh`): a test-only override `FC_GATEWAY_TEST_UPSTREAM`, accepted only for `http://127.0.0.1:<port>` and only when set in `fcctl`'s environment, points the gateway at a small fake provider in `fc-host` (python3, answering `/v1/messages` with fixed text, usage and SSE). The checks:
  - from inside an agent VM, `curl` through `127.0.0.1:8080` works and refusals happen (endpoint, model, size, budget);
  - other destinations are unreachable;
  - the guest never sees the key;
  - `llm.log`, the transcript collection and the gateway's lifetime and cleanup;
  - direct mode on a networked VM;
  - key hand-over leaving nothing in process lists.
- **Live check** (opt-in, `FC_AGENT_LIVE=1` with real keys): one short headless run per profile, documented in the README; not part of the default suite.

## Risks / Trade-offs

- [The gateway is the first guest-initiated channel to the host] → Kestrel with tight limits, rebuilt upstream requests, an unprivileged per-VM uid, a socket only that VM's Firecracker can reach, and fuzz-style unit tests on malformed input.
- [The agent sends payload contents (malware, client data) to the provider] → inherent to cloud models; the README says so, and `codex-ollama` keeps data local.
- [A runaway or hostile agent burns money] → request and token budgets per run, and short default timeouts; `llm.log` shows exactly what was spent.
- [Agent CLIs change often and may break headless flags] → versions pinned by the lockfile, a live check per profile, and flags kept in the wrapper and `profiles.json`, not spread through code.
- [Supply chain: npm packages] → integrity-checked lockfile and `--ignore-scripts` at build; the packages only ever run inside guests.
- [Direct mode leaks the key] → explicit flag, printed warning, recorded in `meta.json`, not available through MCP; documented as trusted-work only.
- [Bigger setup: downloads and about 6 GB more sparse disk] → built only on demand; setup can skip the agent image (`-NoAgentImage`), in which case `-Agent` fails with a hint.
- [Ollama networking between WSL and Windows is fiddly] → configurable URL, doctor check, documented setups.

## Migration Plan

Additive. Existing commands, images and results are unchanged. Re-running `fc.ps1 setup` builds the agent image and the gateway. Rollback means reverting and re-running setup; the agent image and keys directory can be deleted by hand.

## Spike results

**1.1 Guest-to-host channel (2026-11-08):** option (a) works and is used.
- The gateway uid (`210000+slot`, primary gid `64000+slot`) listens on `/var/lib/fc-sandbox/gw/<id>/llm.sock` (dir `0750 gw:jail`, socket `0660`). Root hard-links it into the jail as `<jail>/root/v.sock_8080`.
- In the guest, `socat - VSOCK-CONNECT:2:8080` reached the listener.
- Another VM's uid got `Permission denied` on the socket. Its path is unreachable anyway, because the jailer creates each jail root as `0700` for that VM's uid.
- The second VM's guest got `Connection reset` on its own port 8080 (nothing listening).
- `fcctl stop` removed the jail and the link with it.

**1.2 Agent clients (2026-11-08)**, in a scratch networked guest:
- **Node.js:** pinned `v24.22.2` (Active LTS, "Krypton"). The `.tar.gz` (`361718c4…f482a9`) is used, because the guest image has no `xz`. Its checksum is verified against `SHASUMS256.txt`.
- **Install:** `npm install --ignore-scripts` of `@anthropic-ai/claude-code@2.1.319` and `@openai/codex@0.167.0` puts every package, including the platform packages, under the lockfile's integrity hashes.
- **Claude Code:**
  - Its only install script copies the native binary from `@anthropic-ai/claude-code-linux-x64/claude` (about 340 MB) over the `bin/claude.exe` placeholder. The build script does that link itself, so no package code runs on the host, and `claude` needs no Node.js.
  - It refuses `--dangerously-skip-permissions` as root unless `IS_SANDBOX=1` is set. With it set, `claude -p "<prompt>" --output-format stream-json --verbose --dangerously-skip-permissions` starts in `bypassPermissions` mode and uses `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL`.
  - Its default model is `claude-opus-5-5`, and it also calls smaller models, so the allowlist is `claude-*`.
- **Codex CLI:**
  - It needs no install script; `bin/codex.js` (Node) starts the musl binary from `@openai/codex-linux-x64`.
  - Against the built-in OpenAI provider it uses the Responses API over **WebSocket**. A custom provider (`-c model_provider=fcgw -c model_providers.fcgw.base_url="http://127.0.0.1:8080/v1" -c model_providers.fcgw.env_key="FC_GW_KEY" -c model_providers.fcgw.wire_api="responses"`) makes it send plain `POST /v1/responses` with `"stream": true` (SSE) and `Authorization: Bearer <env_key>`, so the gateway stays an ordinary HTTP proxy. The OpenAI profile always uses this custom provider in gateway mode.
  - Headless: `codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -m <model> "<prompt>" < /dev/null`. Stdin must be closed, or it waits for more input.
- **`codex --oss --local-provider ollama`** first checks for a local Ollama server itself and fails before sending anything. So `codex-ollama` uses the same custom provider as `codex`, with the gateway forwarding to Ollama's OpenAI-compatible `/v1/responses` (to be confirmed in the live check, task 6.2).
- **npm skips a failed optional download silently.** One `npm ci` run in `fc-host` reported "added 2 packages" and left out both platform packages; a rerun fetched them (38-43 s each). The image build therefore checks that both native binaries exist after `npm ci` and fails if either is missing.
- **Default models in `profiles.json`:** `claude-opus-5-5` (allow `claude-*`), `gpt-5.1-codex-max` (allow `gpt-*`; the Codex binary names it), and `gpt-oss:20b` for Ollama (allow `*`, since the model is local and costs nothing).

**Found during testing (2026-11-08):** Windows PowerShell 5.1 (`powershell.exe`) prefixed the key it piped to `_stash-key` with a UTF-8 BOM. The gateway then sent a non-ASCII auth header, and every call failed with `upstream_error: HttpRequestException`. `fc.ps1` now pipes with a BOM-less `$OutputEncoding`, and `_stash-key` strips a BOM and surrounding whitespace. The smoke suite checks the second part.

## Open Questions

- Default model names per profile (task 1.2) are set from the clients' current documentation at implementation time; the allowlist patterns keep that from changing behaviour.
