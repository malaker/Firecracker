using System.Text.Json;
using FcMcp;
using ModelContextProtocol.Protocol;

namespace FcMcp.Tests;

/// <summary>Skipped unless FC_MCP_INTEGRATION=1.</summary>
public sealed class IntegrationFactAttribute : FactAttribute
{
    public IntegrationFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("FC_MCP_INTEGRATION") != "1") Skip = "set FC_MCP_INTEGRATION=1 to run against real VMs";
    }
}

/// <summary>
/// Real Linux VMs through fc.ps1 (tasks 6.1-6.3). Opt-in: set FC_MCP_INTEGRATION=1 on a machine
/// where '.\fc.ps1 setup' has run. Each test takes a few VM boots.
/// </summary>
public sealed class IntegrationTests : IDisposable
{
    private static readonly string Repo = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
    private readonly string _root = Directory.CreateTempSubdirectory("fc-mcp-int-").FullName;
    private readonly SandboxTools _tools;
    private readonly SessionTable _sessions = new(4);

    public IntegrationTests()
    {
        var o = new ServerOptions { RepoRoot = Repo, AllowRoots = [_root, Path.Combine(Repo, "samples")], Elevated = false };
        _tools = new SandboxTools(o, new PowerShellCliRunner(o.FcPs1), new PathPolicy(o.AllowRoots), _sessions);
    }

    public void Dispose()
    {
        _sessions.StopAllAsync(s => _tools.StopSessionAsync(s, CancellationToken.None), TimeSpan.FromSeconds(60)).GetAwaiter().GetResult();
        Directory.Delete(_root, recursive: true);
    }

    private static JsonElement S(CallToolResult r) => r.StructuredContent ?? throw new Xunit.Sdk.XunitException("no structured content: " + Text(r));
    private static string Text(CallToolResult r) => string.Join("\n", r.Content.OfType<TextContentBlock>().Select(c => c.Text));

    [IntegrationFact]
    public async Task RunWithTheHelloSample()
    {
        var r = await _tools.SandboxRun(Path.Combine(Repo, "samples", "hello"), "sh ./in/hello.sh");
        Assert.NotEqual(true, r.IsError);
        var s = S(r);
        Assert.Equal(0, s.GetProperty("exit_code").GetInt32());
        Assert.Contains(s.GetProperty("output_files").EnumerateArray(), f => f.GetString() == "whoami.txt");
        Assert.True(Directory.Exists(s.GetProperty("results_dir").GetString()));
        Assert.Contains("Hello from fc-guest", Text(r));
        Assert.Contains(OutputShaper.Notice, Text(r));

        var failing = await _tools.SandboxRun(Path.Combine(Repo, "samples", "hello"), "exit 3");
        Assert.NotEqual(true, failing.IsError);
        Assert.Equal(3, S(failing).GetProperty("exit_code").GetInt32());
    }

    [IntegrationFact]
    public async Task SessionStatePersistsAndStoppedSessionIsRejected()
    {
        var start = await _tools.SandboxStart(vcpu: 1, mem_mib: 256, timeout: "10m");
        string id = S(start).GetProperty("session_id").GetString()!;

        var e1 = await _tools.SandboxExec(id, "echo hi > marker");
        Assert.Equal(0, S(e1).GetProperty("exit_code").GetInt32());
        var e2 = await _tools.SandboxExec(id, "cat marker; pwd");
        Assert.Equal("hi\n/work\n", File.ReadAllText(S(e2).GetProperty("stdout_path").GetString()!));
        Assert.True(File.Exists(Path.Combine(Repo, "runs", id, "exec", "2", "stdout.log")));

        var quoted = await _tools.SandboxExec(id, "printf '%s' \"it's \\\"quoted\\\"\"");
        Assert.Equal("it's \"quoted\"", File.ReadAllText(S(quoted).GetProperty("stdout_path").GetString()!));

        var list = await Task.FromResult(_tools.SandboxList());
        Assert.Contains(S(list).GetProperty("sessions").EnumerateArray(), x => x.GetProperty("session_id").GetString() == id);

        await _tools.SandboxStop(id);
        var after = await _tools.SandboxExec(id, "true");
        Assert.True(after.IsError);
        Assert.Contains("does not exist", Text(after));
    }

    [IntegrationFact]
    public async Task PutAndGetRoundTripAndConfinement()
    {
        string sample = Path.Combine(_root, "sample.bin");
        File.WriteAllBytes(sample, Enumerable.Range(0, 256).Select(i => (byte)i).ToArray());
        string id = S(await _tools.SandboxStart(vcpu: 1, mem_mib: 256, timeout: "10m")).GetProperty("session_id").GetString()!;

        Assert.NotEqual(true, (await _tools.SandboxPut(id, sample)).IsError);
        await _tools.SandboxExec(id, "mkdir -p out && cp in/sample.bin out/copy.bin");
        var get = await _tools.SandboxGet(id, "/work/out");
        Assert.NotEqual(true, get.IsError);
        string file = S(get).GetProperty("files").EnumerateArray().Single().GetString()!;
        Assert.StartsWith(Path.Combine(Repo, "runs", id, "files", "1"), file);
        Assert.Equal(File.ReadAllBytes(sample), File.ReadAllBytes(file));

        var second = await _tools.SandboxGet(id, "/work/out/copy.bin");
        Assert.StartsWith(Path.Combine(Repo, "runs", id, "files", "2"), S(second).GetProperty("files")[0].GetString()!);

        string outside = Path.Combine(Path.GetTempPath(), "fc-mcp-outside-" + Guid.NewGuid().ToString("N") + ".txt");
        File.WriteAllText(outside, "secret");
        try
        {
            var refused = await _tools.SandboxPut(id, outside);
            Assert.True(refused.IsError);
            Assert.Contains("outside the allowed roots", Text(refused));
        }
        finally
        {
            File.Delete(outside);
        }

        await _tools.SandboxExec(id, "ln -s /etc out/link");
        var link = await _tools.SandboxGet(id, "/work/out");
        Assert.True(link.IsError);
        Assert.Contains("symbolic link is not allowed", Text(link));
        Assert.Contains(OutputShaper.Notice, Text(link));
    }
}
