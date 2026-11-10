using FcMcp;
using ModelContextProtocol.Protocol;

namespace FcMcp.Tests;

/// <summary>Records calls instead of starting fc.ps1, so refusals can be shown to happen before any VM starts.</summary>
internal sealed class FakeRunner : ICliRunner
{
    public List<(string Command, IReadOnlyDictionary<string, object> Named)> Calls { get; } = [];

    public Task<CliResult> RunAsync(string command, IReadOnlyList<string> positional, IReadOnlyDictionary<string, object> named,
        string stdoutPath, string stderrPath, TimeSpan? timeout, CancellationToken cancel)
    {
        Calls.Add((command, new Dictionary<string, object>(named)));
        File.WriteAllText(stdoutPath, "");
        File.WriteAllText(stderrPath, "fake runner: no run");
        return Task.FromResult(new CliResult(125, false));
    }
}

public sealed class AgentRunTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("fc-mcp-agent-").FullName;
    private readonly FakeRunner _runner = new();
    private readonly SandboxTools _tools;

    public AgentRunTests()
    {
        var o = new ServerOptions { RepoRoot = _root, AllowRoots = [_root], Elevated = true, AllowNetworked = true };
        _tools = new SandboxTools(o, _runner, new PathPolicy(o.AllowRoots), new SessionTable(4));
    }

    public void Dispose() => Directory.Delete(_root, recursive: true);

    private static string Text(CallToolResult r) => string.Join("\n", r.Content.OfType<TextContentBlock>().Select(c => c.Text));

    [Theory]
    [InlineData("echo hi", "claude", "x", "either command or agent")]
    [InlineData(null, null, null, "either command or agent")]
    [InlineData(null, "gemini", "x", "agent must be claude, codex or codex-ollama")]
    [InlineData(null, "claude", "", "needs a prompt")]
    [InlineData("echo hi", null, "x", "only apply to agent runs")]
    public async Task ArgumentChecksRefuseBeforeAnyRun(string? command, string? agent, string? prompt, string message)
    {
        var r = await _tools.SandboxRun(payload_path: _root, command: command, agent: agent, prompt: prompt);
        Assert.True(r.IsError);
        Assert.Contains(message, Text(r));
        Assert.Empty(_runner.Calls);
    }

    [Fact]
    public async Task DirectModeIsRefused()
    {
        var r = await _tools.SandboxRun(agent: "claude", prompt: "x", agent_direct: true);
        Assert.True(r.IsError);
        Assert.Contains("direct mode is not available through MCP", Text(r));
        Assert.Empty(_runner.Calls);
    }

    [Theory]
    [InlineData("windows", null, "agents need Linux guests")]
    [InlineData(null, "networked", "agent runs have no network")]
    public async Task AgentsAreLinuxAndIsolatedOnly(string? guest, string? net, string message)
    {
        var r = await _tools.SandboxRun(agent: "claude", prompt: "x", guest: guest, net: net);
        Assert.True(r.IsError);
        Assert.Contains(message, Text(r));
        Assert.Empty(_runner.Calls);
    }

    [Fact]
    public async Task AgentRunPassesAgentAndPromptFileAndNoCommand()
    {
        string prompt = "multi-line\n\"quoted\" & it's fine";
        await _tools.SandboxRun(agent: "codex", prompt: prompt, model: "gpt-5.1-codex-max");
        var (cmd, named) = Assert.Single(_runner.Calls);
        Assert.Equal("run", cmd);
        Assert.Equal("codex", named["Agent"]);
        Assert.Equal("gpt-5.1-codex-max", named["Model"]);
        Assert.False(named.ContainsKey("Cmd"));
        Assert.False(named.ContainsKey("Payload"));
        Assert.False(named.ContainsKey("AgentDirect"));
        Assert.Equal(prompt, File.ReadAllText((string)named["PromptFile"]));
    }
}
