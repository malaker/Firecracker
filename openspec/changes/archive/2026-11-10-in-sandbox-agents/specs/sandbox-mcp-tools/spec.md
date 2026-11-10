# Spec Delta

## ADDED Requirements

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
