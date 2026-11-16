using System.Text.Json;
using FcMcp;
using ModelContextProtocol.Protocol;

namespace FcMcp.Tests;

/// <summary>Answers 'recipe list -Json' with a fixed list and records every other call, so refusals can be shown to start nothing.</summary>
internal sealed class RecipeFakeRunner : ICliRunner
{
    public const string List = """
        [
          {"name":"probe","valid":true,"description":"self-test","kind":"command","image":"base","net":"isolated",
           "input":{"sample":"none","package":"none","rules":"none","entry":"none"},"require_one_of":[]},
          {"name":"triage-static","valid":true,"description":"static triage","kind":"command","image":"agent","net":"isolated",
           "input":{"sample":"required","package":"none","rules":"optional","entry":"none"},"require_one_of":[]},
          {"name":"detonate","valid":true,"description":"detonate","kind":"command","image":"agent","net":"isolated",
           "input":{"sample":"required","package":"none","rules":"none","entry":"optional"},"require_one_of":[]},
          {"name":"npm-check","valid":true,"description":"npm","kind":"command","image":"agent","net":"networked",
           "input":{"sample":"optional","package":"optional","rules":"none","entry":"none"},"require_one_of":["sample","package"]},
          {"name":"agent-triage","valid":true,"description":"agent","kind":"agent","image":"agent","net":"isolated",
           "input":{"sample":"required","package":"none","rules":"optional","entry":"none"},"require_one_of":[]},
          {"name":"broken","valid":false,"error":"invalid field net"}
        ]
        """;

    public List<(IReadOnlyList<string> Positional, IReadOnlyDictionary<string, object> Named)> Runs { get; } = [];
    public int ListCalls { get; private set; }

    public Task<CliResult> RunAsync(string command, IReadOnlyList<string> positional, IReadOnlyDictionary<string, object> named,
        string stdoutPath, string stderrPath, TimeSpan? timeout, CancellationToken cancel)
    {
        File.WriteAllText(stderrPath, "");
        if (command == "recipe" && positional.Count == 1 && positional[0] == "list")
        {
            ListCalls++;
            Assert.Equal(true, named["Json"]);
            File.WriteAllText(stdoutPath, List);
            return Task.FromResult(new CliResult(0, false));
        }
        Assert.Equal("recipe", command);
        Runs.Add((positional.ToArray(), new Dictionary<string, object>(named)));
        File.WriteAllText(stdoutPath, "");
        File.WriteAllText(stderrPath, "fake runner: no run");
        return Task.FromResult(new CliResult(125, false));
    }
}

public sealed class RecipeToolTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("fc-mcp-recipe-").FullName;
    private readonly string _outside = Directory.CreateTempSubdirectory("fc-mcp-outside-").FullName;
    private readonly RecipeFakeRunner _runner = new();
    private readonly string _sample;
    private readonly string _rules;

    public RecipeToolTests()
    {
        _sample = Path.Combine(_root, "x.bin");
        File.WriteAllText(_sample, "data");
        _rules = Directory.CreateDirectory(Path.Combine(_root, "rules")).FullName;
        Directory.CreateDirectory(Path.Combine(_root, "dir", "bin"));
        File.WriteAllText(Path.Combine(_root, "dir", "bin", "start.sh"), "#!/bin/sh\n");
        File.WriteAllText(Path.Combine(_outside, "secret.txt"), "secret");
    }

    public void Dispose()
    {
        Directory.Delete(_root, recursive: true);
        Directory.Delete(_outside, recursive: true);
    }

    private SandboxTools Tools(bool allowNetworked = false)
    {
        var o = new ServerOptions { RepoRoot = _root, AllowRoots = [_root], AllowNetworked = allowNetworked };
        return new SandboxTools(o, _runner, new PathPolicy(o.AllowRoots), new SessionTable(4));
    }

    private static string Text(CallToolResult r) => string.Join("\n", r.Content.OfType<TextContentBlock>().Select(c => c.Text));

    private async Task Refused(Task<CallToolResult> call, string message)
    {
        var r = await call;
        Assert.True(r.IsError, Text(r));
        Assert.Contains(message, Text(r));
        Assert.Empty(_runner.Runs);
    }

    [Fact]
    public async Task ListReturnsRecipesAndSaysWhichThisServerRefuses()
    {
        var r = await Tools().SandboxRecipes();
        Assert.NotEqual(true, r.IsError);
        var recipes = r.StructuredContent!.Value.GetProperty("recipes").EnumerateArray().ToDictionary(x => x.GetProperty("name").GetString()!);
        Assert.Equal(6, recipes.Count);
        Assert.Equal("yes", recipes["probe"].GetProperty("available").GetString());
        Assert.Equal("required", recipes["triage-static"].GetProperty("input").GetProperty("sample").GetString());
        Assert.StartsWith("no: networked", recipes["npm-check"].GetProperty("available").GetString());
        Assert.StartsWith("no: invalid", recipes["broken"].GetProperty("available").GetString());
        Assert.Empty(_runner.Runs);

        var allowed = await Tools(allowNetworked: true).SandboxRecipes();
        Assert.Contains(allowed.StructuredContent!.Value.GetProperty("recipes").EnumerateArray(),
            x => x.GetProperty("name").GetString() == "npm-check" && x.GetProperty("available").GetString() == "yes");
    }

    [Theory]
    [InlineData("nope", "unknown recipe 'nope' (available: probe, triage-static")]
    [InlineData("../probe", "invalid recipe name")]
    [InlineData("Probe", "invalid recipe name")]
    [InlineData("", "invalid recipe name")]
    [InlineData("broken", "invalid manifest: invalid field net")]
    public async Task NameIsChecked(string name, string message) => await Refused(Tools().SandboxRecipe(name), message);

    [Fact]
    public async Task InvalidNameDoesNotEvenListRecipes()
    {
        await Refused(Tools().SandboxRecipe("x; rm -rf /"), "invalid recipe name");
        Assert.Equal(0, _runner.ListCalls);
    }

    [Fact]
    public async Task NetworkedRecipeNeedsTheServersOptIn()
    {
        await Refused(Tools().SandboxRecipe("npm-check", package: "left-pad@1.3.0"), "networked mode is disabled for this server");
        await Tools(allowNetworked: true).SandboxRecipe("npm-check", package: "left-pad@1.3.0");
        var (positional, named) = Assert.Single(_runner.Runs);
        Assert.Equal(["npm-check"], positional);
        Assert.Equal("left-pad@1.3.0", named["Package"]);
        Assert.False(named.ContainsKey("Net"));
    }

    [Fact]
    public async Task InputsMustMatchWhatTheRecipeTakes()
    {
        await Refused(Tools().SandboxRecipe("triage-static"), "needs a sample");
        await Refused(Tools().SandboxRecipe("probe", sample_path: _sample), "takes no sample");
        await Refused(Tools().SandboxRecipe("triage-static", sample_path: _sample, package: "x"), "takes no package");
        await Refused(Tools().SandboxRecipe("triage-static", sample_path: _sample, entry: "a.sh"), "takes no entry");
        await Refused(Tools(true).SandboxRecipe("npm-check"), "needs a sample or a package");
        await Refused(Tools(true).SandboxRecipe("npm-check", sample_path: _sample, package: "x"), "not both");
        await Refused(Tools().SandboxRecipe("detonate", sample_path: _sample, entry: "a.sh"), "entry only applies to a folder sample");
    }

    [Theory]
    [InlineData("x; rm -rf /")]
    [InlineData("--registry=http://evil.example")]
    [InlineData("a b")]
    [InlineData("$(id)")]
    public async Task PackageSpecIsChecked(string spec) =>
        await Refused(Tools(allowNetworked: true).SandboxRecipe("npm-check", package: spec), "invalid package spec");

    [Theory]
    [InlineData("../x.sh")]
    [InlineData("bin/../../x.sh")]
    [InlineData("/etc/passwd")]
    [InlineData("a;b")]
    public async Task EntryIsChecked(string entry) =>
        await Refused(Tools().SandboxRecipe("detonate", sample_path: Path.Combine(_root, "dir"), entry: entry), "invalid entry");

    [Fact]
    public async Task SampleAndRulesAreConfinedToTheAllowedRoots()
    {
        await Refused(Tools().SandboxRecipe("triage-static", sample_path: Path.Combine(_outside, "secret.txt")), "outside the allowed roots");
        await Refused(Tools().SandboxRecipe("triage-static", sample_path: _sample, rules_path: _outside), "outside the allowed roots");
        await Refused(Tools().SandboxRecipe("triage-static", sample_path: Path.Combine(_root, "missing.bin")), "does not exist");
        await Refused(Tools().SandboxRecipe("triage-static", sample_path: _sample, rules_path: _sample), "rules_path must be a folder");
    }

    [Fact]
    public async Task AgentRecipesNeedAProfileAndCommandRecipesTakeNone()
    {
        await Refused(Tools().SandboxRecipe("agent-triage", sample_path: _sample), "needs an agent");
        await Refused(Tools().SandboxRecipe("agent-triage", sample_path: _sample, agent: "gemini"), "needs an agent");
        await Refused(Tools().SandboxRecipe("probe", agent: "claude"), "not an agent recipe");
        await Refused(Tools().SandboxRecipe("probe", model: "x"), "not an agent recipe");
    }

    [Fact]
    public async Task AValidCallPassesOnlyTheRecipesInputs()
    {
        await Tools().SandboxRecipe("detonate", sample_path: Path.Combine(_root, "dir"), entry: @"bin\start.sh", timeout: "5m", vcpu: 1, mem_mib: 512);
        var (positional, named) = Assert.Single(_runner.Runs);
        Assert.Equal(["detonate"], positional);
        Assert.Equal(Path.Combine(_root, "dir"), (string)named["Sample"], ignoreCase: true);
        Assert.Equal("bin/start.sh", named["Entry"]);
        Assert.Equal("5m", named["Timeout"]);
        Assert.Equal(1, named["Vcpu"]);
        Assert.Equal(512, named["MemMib"]);
        Assert.True(named.ContainsKey("RunInfoFile"));
        // Nothing that could change what the recipe fixes.
        foreach (string fixedByRecipe in new[] { "Cmd", "Payload", "Net", "Allow", "AgentDirect", "Prompt", "PromptFile", "Guest" })
        {
            Assert.False(named.ContainsKey(fixedByRecipe), fixedByRecipe);
        }
    }

    [Fact]
    public async Task AnAgentRecipePassesTheProfileAndModel()
    {
        await Tools().SandboxRecipe("agent-triage", sample_path: _sample, rules_path: _rules, agent: "codex", model: "gpt-5.1-codex-max");
        var (_, named) = Assert.Single(_runner.Runs);
        Assert.Equal("codex", named["Agent"]);
        Assert.Equal("gpt-5.1-codex-max", named["Model"]);
        Assert.Equal(_rules, (string)named["Rules"], ignoreCase: true);
        Assert.False(named.ContainsKey("AgentDirect"));
    }

    [Fact]
    public void RecipeListFixtureIsValidJson() => Assert.Equal(6, JsonDocument.Parse(RecipeFakeRunner.List).RootElement.GetArrayLength());
}
