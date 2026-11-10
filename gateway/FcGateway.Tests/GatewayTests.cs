using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.AspNetCore.Http;

namespace FcGateway.Tests;

// Task 2.2: profiles and key.
public class ProfileTests
{
    [Fact]
    public void LoadsAProfile()
    {
        var p = ProfileLoader.Load(Gateway.ProfilesJson(), "claude", null, null, null);
        Assert.Equal(AuthStyle.XApiKey, p.Auth);
        Assert.Equal("api.anthropic.com", p.Upstream.Host);
        Assert.True(p.AllowsEndpoint("POST", "/v1/messages"));
        Assert.False(p.AllowsEndpoint("GET", "/v1/messages"));
        Assert.True(p.AllowsModel("claude-opus-5-5"));
        Assert.False(p.AllowsModel("gpt-5"));
        Assert.False(p.AllowsModel(""));
    }

    [Fact]
    public void TokenBudgetOverride() =>
        Assert.Equal(42, ProfileLoader.Load(Gateway.ProfilesJson(), "claude", null, null, 42).Limits.TokenBudget);

    [Fact]
    public void OllamaNeedsAUrl()
    {
        Assert.Contains("Ollama URL", Assert.Throws<ConfigException>(() => ProfileLoader.Load(Gateway.ProfilesJson(), "codex-ollama", null, null, null)).Message);
        Assert.Equal("http://172.30.0.1:11434/", ProfileLoader.Load(Gateway.ProfilesJson(), "codex-ollama", "http://172.30.0.1:11434", null, null).Upstream.ToString());
    }

    [Theory]
    [InlineData("gemini", "unknown profile")]
    public void UnknownProfile(string name, string msg) =>
        Assert.Contains(msg, Assert.Throws<ConfigException>(() => ProfileLoader.Load(Gateway.ProfilesJson(), name, null, null, null)).Message);

    [Theory]
    [InlineData("ftp://x")]
    [InlineData("https://api.example.com/v1")]
    [InlineData("not a url")]
    public void BadOllamaUrls(string url) =>
        Assert.Throws<ConfigException>(() => ProfileLoader.Load(Gateway.ProfilesJson(), "codex-ollama", url, null, null));

    [Fact]
    public void BadLimitsAndJson()
    {
        Assert.Throws<ConfigException>(() => ProfileLoader.Load("{", "claude", null, null, null));
        Assert.Throws<ConfigException>(() => ProfileLoader.Load(Gateway.ProfilesJson("""{"max_requests":0,"max_request_bytes":1,"max_response_bytes":1,"request_timeout_sec":1,"token_budget":1}"""), "claude", null, null, null));
    }

    [Fact]
    public void MissingKeyFailsBeforeListening()
    {
        string dir = Directory.CreateTempSubdirectory("fcgw-nokey-").FullName;
        File.WriteAllText(Path.Combine(dir, "profiles.json"), Gateway.ProfilesJson());
        string dll = Path.Combine(AppContext.BaseDirectory, "fc-llm-gateway.dll");
        var psi = new ProcessStartInfo("dotnet") { RedirectStandardInput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in new[] { dll, "--profiles", Path.Combine(dir, "profiles.json"), "--profile", "claude", "--socket", Path.Combine(dir, "s.sock"), "--log", Path.Combine(dir, "llm.log") }) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        p.StandardInput.Close();
        string err = p.StandardError.ReadToEnd();
        Assert.True(p.WaitForExit(30000));
        Assert.Equal(2, p.ExitCode);
        Assert.Contains("no API key", err);
        Assert.False(File.Exists(Path.Combine(dir, "s.sock")));
        Directory.Delete(dir, true);
    }
}

// Task 2.7: test-only upstream override.
public class TestUpstreamOverrideTests
{
    [Theory]
    [InlineData("http://127.0.0.1:8999", "http://127.0.0.1:8999")]
    [InlineData("http://127.0.0.1:8999/", "http://127.0.0.1:8999")]
    public void Accepted(string v, string expected) => Assert.Equal(expected, ProfileLoader.CheckTestUpstream(v));

    [Theory]
    [InlineData("https://127.0.0.1:8999")]
    [InlineData("http://127.0.0.2:8999")]
    [InlineData("http://localhost:8999")]
    [InlineData("http://evil.example:8999")]
    [InlineData("http://127.0.0.1")]
    [InlineData("http://127.0.0.1:8999/v1")]
    [InlineData("http://user:pw@127.0.0.1:8999")]
    [InlineData("http://127.0.0.1:8999?x=1")]
    public void Rejected(string v) => Assert.Throws<ConfigException>(() => ProfileLoader.CheckTestUpstream(v));
}

// Task 2.3: Kestrel limits and framing.
public class HardeningTests
{
    [Fact]
    public async Task OversizedHeadersAreRefused()
    {
        await using var g = await Gateway.Start();
        using var c = g.Client();
        var req = new HttpRequestMessage(HttpMethod.Post, "/v1/messages") { Content = Gateway.Body("{}") };
        req.Headers.TryAddWithoutValidation("x-big", new string('a', GatewayApp.MaxHeaderBytes + 10));
        var r = await c.SendAsync(req);
        Assert.Equal(HttpStatusCode.RequestHeaderFieldsTooLarge, r.StatusCode);
        Assert.Empty(g.Upstream.Seen);
    }

    [Fact]
    public async Task TooManyHeadersAreRefused()
    {
        await using var g = await Gateway.Start();
        using var c = g.Client();
        var req = new HttpRequestMessage(HttpMethod.Post, "/v1/messages") { Content = Gateway.Body("{}") };
        for (int i = 0; i < GatewayApp.MaxHeaderCount + 5; i++) req.Headers.TryAddWithoutValidation($"x-h{i}", "v");
        Assert.Equal(HttpStatusCode.RequestHeaderFieldsTooLarge, (await c.SendAsync(req)).StatusCode);
    }

    [Fact]
    public async Task MalformedHttpClosesOnlyThatConnection()
    {
        await using var g = await Gateway.Start();
        using var bad = await g.Raw();
        await bad.SendAsync(Encoding.ASCII.GetBytes("\x01\x02 THIS IS NOT HTTP\r\n\r\n"));
        var buf = new byte[4096];
        int n = await bad.ReceiveAsync(buf);
        Assert.StartsWith("HTTP/1.1 400", Encoding.ASCII.GetString(buf, 0, n));
        Assert.Equal(0, await bad.ReceiveAsync(buf)); // closed by the gateway

        using var c = g.Client();
        var ok = await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-opus-5-5"}"""));
        Assert.Equal(HttpStatusCode.OK, ok.StatusCode);
    }

    [Fact]
    public async Task ConnectionLimitRefusesOnlyTheExtraConnection()
    {
        await using var g = await Gateway.Start();
        var open = new List<Socket>();
        for (int i = 0; i < GatewayApp.MaxConnections; i++) open.Add(await g.Raw());
        await Task.Delay(300);
        using var extra = await g.Raw();
        await extra.SendAsync(Encoding.ASCII.GetBytes("GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n"));
        var buf = new byte[4096];
        int n = 0;
        try { n = await extra.ReceiveAsync(buf).WaitAsync(TimeSpan.FromSeconds(5)); } catch (SocketException) { }
        Assert.DoesNotContain("HTTP/1.1 200", Encoding.ASCII.GetString(buf, 0, n));

        // An already-open connection still works.
        await open[0].SendAsync(Encoding.ASCII.GetBytes("POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"model\":\"claude-opus-5-5\"}"));
        n = await open[0].ReceiveAsync(buf).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.StartsWith("HTTP/1.1 200", Encoding.ASCII.GetString(buf, 0, n));
        foreach (var s in open) s.Dispose();
    }
}

// Task 2.4: forwarding rules.
public class ForwardingTests
{
    [Fact]
    public async Task UnlistedEndpointIs403AndNotForwarded()
    {
        await using var g = await Gateway.Start();
        using var c = g.Client();
        var r = await c.SendAsync(new HttpRequestMessage(HttpMethod.Delete, "/v1/files/123"));
        Assert.Equal(HttpStatusCode.Forbidden, r.StatusCode);
        Assert.Contains("endpoint not allowed", await r.Content.ReadAsStringAsync());
        Assert.Empty(g.Upstream.Seen);
        Assert.Contains(g.LogLines(), l => l.Contains("decision=refused") && l.Contains("path=/v1/files/123"));
    }

    [Fact]
    public async Task UnlistedOrMissingModelIs403()
    {
        await using var g = await Gateway.Start();
        using var c = g.Client();
        var r = await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"gpt-5"}"""));
        Assert.Equal(HttpStatusCode.Forbidden, r.StatusCode);
        Assert.Contains("model 'gpt-5' is not allowed", await r.Content.ReadAsStringAsync());
        Assert.Equal(HttpStatusCode.Forbidden, (await c.PostAsync("/v1/messages", Gateway.Body("""{"messages":[]}"""))).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await c.PostAsync("/v1/messages", Gateway.Body("not json"))).StatusCode);
        Assert.Empty(g.Upstream.Seen);
    }

    [Fact]
    public async Task GuestCredentialsAreReplacedByTheRealKey()
    {
        await using var g = await Gateway.Start();
        using var c = g.Client();
        var req = new HttpRequestMessage(HttpMethod.Post, "/v1/messages?beta=true") { Content = Gateway.Body("""{"model":"claude-opus-5-5"}""") };
        req.Headers.TryAddWithoutValidation("x-api-key", "dummy");
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer guest-token");
        req.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        req.Headers.TryAddWithoutValidation("x-evil", "1");
        req.Headers.TryAddWithoutValidation("Cookie", "a=b");
        Assert.Equal(HttpStatusCode.OK, (await c.SendAsync(req)).StatusCode);
        var seen = Assert.Single(g.Upstream.Seen);
        Assert.Equal(Gateway.Key, seen.Headers["x-api-key"]);
        Assert.False(seen.Headers.ContainsKey("authorization"));
        Assert.False(seen.Headers.ContainsKey("x-evil"));
        Assert.False(seen.Headers.ContainsKey("cookie"));
        Assert.Equal("2023-06-01", seen.Headers["anthropic-version"]);
        Assert.Equal("/v1/messages?beta=true", seen.PathAndQuery);
        Assert.Equal("""{"model":"claude-opus-5-5"}""", seen.Body);
    }

    [Fact]
    public async Task BearerProfileInjectsBearerAndOllamaInjectsNothing()
    {
        await using (var g = await Gateway.Start("codex"))
        {
            using var c = g.Client();
            var req = new HttpRequestMessage(HttpMethod.Post, "/v1/responses") { Content = Gateway.Body("""{"model":"gpt-5.1-codex-max"}""") };
            req.Headers.TryAddWithoutValidation("Authorization", "Bearer dummy");
            await c.SendAsync(req);
            Assert.Equal($"Bearer {Gateway.Key}", Assert.Single(g.Upstream.Seen).Headers["authorization"]);
        }
        await using (var g = await Gateway.Start("codex-ollama"))
        {
            using var c = g.Client();
            var req = new HttpRequestMessage(HttpMethod.Post, "/v1/responses") { Content = Gateway.Body("""{"model":"gpt-oss:20b"}""") };
            req.Headers.TryAddWithoutValidation("Authorization", "Bearer dummy");
            await c.SendAsync(req);
            var seen = Assert.Single(g.Upstream.Seen);
            Assert.False(seen.Headers.ContainsKey("authorization"));
            Assert.False(seen.Headers.ContainsKey("x-api-key"));
        }
    }

    [Fact]
    public async Task HostHeaderAndAbsoluteUrlCannotRedirect()
    {
        await using var g = await Gateway.Start();
        using var raw = await g.Raw();
        string body = """{"model":"claude-opus-5-5"}""";
        await raw.SendAsync(Encoding.ASCII.GetBytes(
            $"POST http://evil.example/v1/messages HTTP/1.1\r\nHost: evil.example\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\n\r\n{body}"));
        var buf = new byte[4096];
        int n = await raw.ReceiveAsync(buf).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.StartsWith("HTTP/1.1 200", Encoding.ASCII.GetString(buf, 0, n));
        var seen = Assert.Single(g.Upstream.Seen);
        Assert.StartsWith("127.0.0.1:", seen.Headers["host"]);
    }
}

// Task 2.5: streaming and limits.
public class StreamingAndLimitTests
{
    [Fact]
    public async Task SseEventsArriveBeforeTheResponseEnds()
    {
        await using var g = await Gateway.Start();
        var release = new TaskCompletionSource();
        g.Upstream.Respond = async ctx =>
        {
            ctx.Response.ContentType = "text/event-stream";
            await ctx.Response.WriteAsync("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n");
            await ctx.Response.Body.FlushAsync();
            await release.Task;
            await ctx.Response.WriteAsync("event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":9}}\n\n");
        };
        using var c = g.Client();
        var req = new HttpRequestMessage(HttpMethod.Post, "/v1/messages") { Content = Gateway.Body("""{"model":"claude-opus-5-5","stream":true}""") };
        using var r = await c.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
        using var s = new StreamReader(await r.Content.ReadAsStreamAsync());
        string first = (await s.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)))!;
        Assert.Equal("event: message_start", first);
        release.SetResult();
        await s.ReadToEndAsync();
        await Task.Delay(200);
        Assert.Equal(16, g.State.Tokens); // 7 in + 9 out (cumulative delta, not 1 + 9)
        Assert.Contains(g.LogLines(), l => l.Contains("tokens_in=7") && l.Contains("tokens_out=9"));
    }

    [Fact]
    public async Task OpenAiUsageIsCountedFromResponsesSseAndChatJson()
    {
        await using var g = await Gateway.Start("codex");
        g.Upstream.Respond = async ctx =>
        {
            ctx.Response.ContentType = "text/event-stream";
            await ctx.Response.WriteAsync("data: {\"type\":\"response.created\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":20,\"output_tokens\":3}}}\n\ndata: [DONE]\n\n");
        };
        using var c = g.Client();
        await (await c.PostAsync("/v1/responses", Gateway.Body("""{"model":"gpt-5.1-codex-max"}"""))).Content.ReadAsStringAsync();
        Assert.Equal(23, g.State.Tokens);
        g.Upstream.Respond = ctx => FakeUpstream.Json(ctx, """{"usage":{"prompt_tokens":4,"completion_tokens":6}}""");
        await (await c.PostAsync("/v1/chat/completions", Gateway.Body("""{"model":"gpt-4o"}"""))).Content.ReadAsStringAsync();
        Assert.Equal(33, g.State.Tokens);
    }

    [Fact]
    public async Task RequestBudget()
    {
        await using var g = await Gateway.Start(limitsJson: """{"max_requests":2,"max_request_bytes":16384,"max_response_bytes":1048576,"request_timeout_sec":30,"token_budget":1000000}""");
        using var c = g.Client();
        for (int i = 0; i < 2; i++) Assert.Equal(HttpStatusCode.OK, (await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-x"}"""))).StatusCode);
        var r = await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-x"}"""));
        Assert.Equal(HttpStatusCode.TooManyRequests, r.StatusCode);
        Assert.Contains("request budget of 2 is spent", await r.Content.ReadAsStringAsync());
        Assert.Equal(2, g.Upstream.Seen.Count);
    }

    [Fact]
    public async Task TokenBudget()
    {
        await using var g = await Gateway.Start(limitsJson: """{"max_requests":100,"max_request_bytes":16384,"max_response_bytes":1048576,"request_timeout_sec":30,"token_budget":20}""");
        using var c = g.Client();
        // Each fake answer reports 15 tokens: the second call crosses the budget, the third is refused.
        Assert.Equal(HttpStatusCode.OK, (await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-x"}"""))).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-x"}"""))).StatusCode);
        var r = await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-x"}"""));
        Assert.Equal(HttpStatusCode.TooManyRequests, r.StatusCode);
        Assert.Contains("token budget of 20 is spent", await r.Content.ReadAsStringAsync());
        Assert.Equal(2, g.Upstream.Seen.Count);
    }

    [Fact]
    public async Task OversizedBodyIs413()
    {
        await using var g = await Gateway.Start();
        using var c = g.Client();
        string big = "{\"model\":\"claude-x\",\"pad\":\"" + new string('a', 20000) + "\"}";
        var r = await c.PostAsync("/v1/messages", Gateway.Body(big));
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, r.StatusCode);
        Assert.Empty(g.Upstream.Seen);
    }

    [Fact]
    public async Task ResponseBudgetCutsTheResponse()
    {
        await using var g = await Gateway.Start(limitsJson: """{"max_requests":100,"max_request_bytes":16384,"max_response_bytes":1000,"request_timeout_sec":30,"token_budget":1000000}""");
        g.Upstream.Respond = ctx => FakeUpstream.Json(ctx, "{\"x\":\"" + new string('b', 5000) + "\"}");
        using var c = g.Client();
        await Assert.ThrowsAnyAsync<Exception>(async () => await (await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-x"}"""))).Content.ReadAsStringAsync());
        await Task.Delay(200);
        Assert.Contains(g.LogLines(), l => l.Contains("decision=failed") && l.Contains("response_budget_spent"));
    }

    [Fact]
    public async Task SlowUpstreamTimesOutWith504()
    {
        await using var g = await Gateway.Start(limitsJson: """{"max_requests":100,"max_request_bytes":16384,"max_response_bytes":1048576,"request_timeout_sec":1,"token_budget":1000000}""");
        g.Upstream.Respond = async ctx => { await Task.Delay(5000); await FakeUpstream.Json(ctx, "{}"); };
        using var c = g.Client();
        var sw = Stopwatch.StartNew();
        var r = await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-x"}"""));
        Assert.Equal(HttpStatusCode.GatewayTimeout, r.StatusCode);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(4));
    }
}

// Task 2.6: call log and key secrecy.
public class CallLogTests
{
    [Fact]
    public async Task OneLinePerRequestWithFieldsAndTotals()
    {
        await using var g = await Gateway.Start();
        using var c = g.Client();
        for (int i = 0; i < 5; i++) await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-opus-5-5"}"""));
        await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"gpt-x"}"""));
        var lines = g.LogLines();
        Assert.Equal(6, lines.Length);
        Assert.Equal(5, lines.Count(l => l.Contains("decision=forwarded") && l.Contains("status=200") && l.Contains("model=claude-opus-5-5") && l.Contains("tokens_in=10") && l.Contains("tokens_out=5")));
        // bytes_up is the size of the forwarded request body.
        Assert.All(lines.Where(l => l.Contains("decision=forwarded")), l => Assert.Contains("bytes_up=27 ", l));
        Assert.Single(lines, l => l.Contains("decision=refused") && l.Contains("model=gpt-x"));
        string totals = Gateway.ReadShared(g.TotalsPath);
        Assert.Contains("\"requests\":5", totals);
        Assert.Contains("\"refused\":1", totals);
        Assert.Contains("\"tokens\":75", totals);
    }

    [Fact]
    public async Task KeyNeverAppearsInLogsOrErrors()
    {
        await using var g = await Gateway.Start();
        // A misbehaving upstream that echoes the key back must not leak it into the log.
        g.Upstream.Respond = ctx => FakeUpstream.Json(ctx, "{\"error\":\"bad key\"}", 401);
        using var c = g.Client();
        var r = await c.PostAsync("/v1/messages", Gateway.Body("""{"model":"claude-x"}"""));
        Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);
        var refused = await c.PostAsync("/v1/messages", Gateway.Body("{\"model\":\"" + Gateway.Key + "\"}"));
        Assert.DoesNotContain(Gateway.Key, Gateway.ReadShared(g.LogPath));
        Assert.DoesNotContain("REAL-KEY", Gateway.ReadShared(g.LogPath));
        Assert.Contains("[redacted]", Gateway.ReadShared(g.LogPath));
        Assert.Equal(HttpStatusCode.Forbidden, refused.StatusCode);
    }

    [Fact]
    public void CleanStripsSpacesAndControlCharacters() =>
        Assert.Equal("a_b_c_d", CallLog.Clean("a b\nc\"d"));
}
