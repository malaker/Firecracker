using System.Diagnostics;
using FcMcp;

namespace FcMcp.Tests;

/// <summary>Runs the real PowerShell runner against a stub script that stands in for fc.ps1.</summary>
public sealed class CliRunnerTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("fc-mcp-runner-").FullName;
    private string Stub => Path.Combine(_dir, "stub.ps1");
    private string Out => Path.Combine(_dir, "out.log");
    private string Err => Path.Combine(_dir, "err.log");

    public CliRunnerTests()
    {
        File.WriteAllText(Stub, """
            [CmdletBinding(PositionalBinding = $false)]
            param(
                [Parameter(Position = 0)][string]$Command,
                [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest,
                [string]$Cmd,
                [switch]$Keep,
                [string[]]$Allow
            )
            switch ($Command) {
                'echo'  { Write-Output "cmd=[$Cmd] rest=[$($Rest -join '|')] keep=$Keep allow=[$($Allow -join ',')]"; [Console]::Error.WriteLine('to-stderr'); exit 0 }
                'exit'  { exit [int]$Rest[0] }
                'sleep' { Start-Sleep -Seconds 30; exit 0 }
                'stdin' { $line = [Console]::In.ReadLine(); Write-Output "stdin=[$line]"; exit 0 }
                'utf8'  { Write-Output "caf$([char]0xE9) $([char]0x20AC)"; exit 0 }
            }
            exit 99
            """);
    }

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private Task<CliResult> Run(string command, string[]? positional = null, Dictionary<string, object>? named = null, TimeSpan? timeout = null) =>
        new PowerShellCliRunner(Stub).RunAsync(command, positional ?? [], named ?? [], Out, Err, timeout, CancellationToken.None);

    [Fact]
    public async Task ArgumentsWithQuotesAndSpacesSurvive()
    {
        var r = await Run("echo", ["20261107-1", "it's \"quoted\" & $(not expanded)"],
            new() { ["Cmd"] = "echo \"hi\" 'there'; $HOME", ["Keep"] = true, ["Allow"] = new[] { "1.1.1.0/24", "8.8.8.8" } });
        Assert.Equal(0, r.ExitCode);
        string o = File.ReadAllText(Out).Trim();
        Assert.Equal("cmd=[echo \"hi\" 'there'; $HOME] rest=[20261107-1|it's \"quoted\" & $(not expanded)] keep=True allow=[1.1.1.0/24,8.8.8.8]", o);
        Assert.Equal("to-stderr", File.ReadAllText(Err).Trim());
    }

    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    [InlineData(125)]
    public async Task ExitCodesArePassedThrough(int code)
    {
        Assert.Equal(code, (await Run("exit", [code.ToString()])).ExitCode);
    }

    [Fact]
    public async Task TimeoutKillsTheChild()
    {
        var sw = Stopwatch.StartNew();
        var r = await Run("sleep", timeout: TimeSpan.FromSeconds(2));
        Assert.True(r.TimedOut);
        Assert.Equal(124, r.ExitCode);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(15), $"took {sw.Elapsed}");
    }

    [Fact]
    public async Task ChildCannotReadTheServersStdin()
    {
        // The child gets an empty, closed stdin: it reads EOF at once instead of protocol bytes.
        var r = await Run("stdin", timeout: TimeSpan.FromSeconds(20));
        Assert.False(r.TimedOut);
        Assert.Equal("stdin=[]", File.ReadAllText(Out).Trim());
    }

    [Fact]
    public async Task OutputIsUtf8()
    {
        await Run("utf8");
        Assert.Equal("café €", File.ReadAllText(Out, System.Text.Encoding.UTF8).Trim());
    }

    [Fact]
    public void ScriptLiteralsEscapeSingleQuotes()
    {
        Assert.Equal("'it''s'", PowerShellCliRunner.Literal("it's"));
        Assert.Throws<ArgumentException>(() => PowerShellCliRunner.BuildScript("x", "run", [], new Dictionary<string, object> { ["bad name"] = "v" }));
    }
}
