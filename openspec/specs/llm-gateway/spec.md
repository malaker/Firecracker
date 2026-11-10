# llm-gateway Specification

## Purpose

Gives an AI agent inside an isolated microVM access to exactly one model provider through a host-side gateway, so the guest needs no network adapter and never holds a real API key.

## Requirements

### Requirement: One gateway per agent VM
Every agent VM in gateway mode SHALL get its own gateway process, started before the guest boots and stopped when the VM is destroyed (by stop, timeout, cleanup or the end of a run). A gateway SHALL serve only the VM it was started for.

#### Scenario: Gateway follows the VM
- **WHEN** an agent run in gateway mode finishes
- **THEN** its gateway process no longer exists

#### Scenario: Two agent VMs
- **WHEN** two agent VMs run at the same time
- **THEN** each has its own gateway, and neither VM can reach the other's gateway

### Requirement: Single guest-initiated channel
The gateway SHALL be reachable from the guest only through one vsock port of that VM, exposed in the guest as `127.0.0.1:8080`. The agent VM SHALL otherwise stay in `isolated` mode: no network adapter, and no other guest-initiated connection to the host.

#### Scenario: Only the model API is reachable
- **WHEN** a process in a gateway-mode agent VM tries to connect to any address other than `127.0.0.1:8080`
- **THEN** the connection fails, and requests to `127.0.0.1:8080` reach only the gateway

### Requirement: Provider profiles
The gateway SHALL forward to exactly one upstream per run, chosen by the agent profile: the Anthropic API (`https://api.anthropic.com`), the OpenAI API (`https://api.openai.com`), or an Ollama server on the host through its OpenAI-compatible API (a configured URL, default port 11434). It SHALL NOT connect to any other destination.

#### Scenario: Request for another host
- **WHEN** the guest sends a request whose `Host` header or absolute URL names a different host
- **THEN** the gateway still forwards only to the profile's upstream, or refuses the request, and never connects elsewhere

### Requirement: Key injection
The gateway SHALL remove any credentials the guest sends (`Authorization`, `x-api-key` and similar headers) and add the host-side API key for the profile's provider. The real key MUST NOT be sent to the guest in any form, including in error messages and logs.

#### Scenario: Dummy key in the guest
- **WHEN** the agent sends a request with the dummy key it was configured with
- **THEN** the upstream receives the real key, and the guest's environment, files and responses never contain it

#### Scenario: Ollama without a key
- **WHEN** the profile is Ollama
- **THEN** the gateway forwards without adding any credential

### Requirement: Endpoint and model allowlists
The gateway SHALL forward only the profile's model endpoints (Anthropic: `POST /v1/messages` and `POST /v1/messages/count_tokens`; OpenAI and Ollama: `POST /v1/responses`, `POST /v1/chat/completions`, `GET /v1/models`) and only requests whose `model` is in the profile's model allowlist. Anything else SHALL be refused with HTTP 403 and logged.

#### Scenario: Unlisted endpoint
- **WHEN** the guest requests `DELETE /v1/files/123` through the Anthropic profile
- **THEN** the gateway answers 403 and nothing is sent upstream

#### Scenario: Unlisted model
- **WHEN** the guest asks for a model that is not in the profile's allowlist
- **THEN** the gateway answers 403 naming the model and nothing is sent upstream

### Requirement: Run limits
Each gateway SHALL enforce, per run: a maximum number of forwarded requests, a maximum request body size, a maximum total response size, a per-request time limit, and a token budget counted from the providers' reported usage. A request over a limit SHALL be refused with HTTP 429 or 413; once a run's request or token budget is spent, every further request SHALL be refused.

#### Scenario: Budget spent
- **WHEN** a run has used its whole token budget
- **THEN** the next request is refused with 429 and a message saying the budget is spent, and nothing is sent upstream

#### Scenario: Oversized request
- **WHEN** the guest sends a request body larger than the limit
- **THEN** the gateway answers 413 without forwarding it

### Requirement: Hardened against the guest
The gateway SHALL treat everything from the guest as hostile: it SHALL run as an unprivileged user without root rights, parse requests with fixed limits on header size, header count and connection count, close connections that violate HTTP framing or stay idle too long, and keep running for other well-formed requests of the same VM.

#### Scenario: Malformed request
- **WHEN** the guest sends bytes that are not valid HTTP
- **THEN** the gateway closes that connection, logs it, and still serves the next valid request

#### Scenario: Not root
- **WHEN** a gateway is running
- **THEN** its process runs under a non-root uid that owns nothing else on the host

### Requirement: Streaming responses
The gateway SHALL pass streamed responses (server-sent events) to the guest as they arrive, so interactive and long agent turns work.

#### Scenario: Streamed answer
- **WHEN** the agent requests a streamed response
- **THEN** it receives events as the upstream sends them, not only after the response has finished

### Requirement: Call log
For every agent run in gateway mode, the system SHALL write `runs/<run-id>/llm.log` with one line per request: timestamp, method and path, model, decision (`forwarded`, `refused` or `failed`) and reason, upstream status, request and response bytes, and reported token usage. Request and response bodies SHALL NOT be logged.

#### Scenario: Log after a run
- **WHEN** an agent run made five model calls and one was refused
- **THEN** `llm.log` has six lines, five `forwarded` and one `refused` with its reason

### Requirement: Gateway cleanup
`cleanup` SHALL stop every gateway process and remove every gateway socket left from earlier runs, including after the controller was killed.

#### Scenario: Controller killed during an agent run
- **WHEN** the controller is killed while an agent VM and its gateway are running, and the user runs cleanup
- **THEN** no gateway process or socket remains
