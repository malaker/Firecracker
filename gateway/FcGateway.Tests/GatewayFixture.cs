using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace FcGateway.Tests;

public sealed record SeenRequest(string Method, string PathAndQuery, Dictionary<string, string> Headers, string Body);

/// <summary>A fake provider on 127.0.0.1 that records requests and answers with whatever the test set.</summary>
public sealed class FakeUpstream : IAsyncDisposable
{
    private readonly WebApplication _app;
    public ConcurrentQueue<SeenRequest> Seen { get; } = new();
    public Func<HttpContext, Task> Respond { get; set; } = ctx => Json(ctx, """{"id":"x","usage":{"input_tokens":10,"output_tokens":5}}""");
    public string Url { get; }

    private FakeUpstream(WebApplication app, string url) { _app = app; Url = url; }

    public static async Task<FakeUpstream> Start()
    {
        var b = WebApplication.CreateSlimBuilder();
        b.Logging.ClearProviders();
        b.WebHost.UseUrls("http://127.0.0.1:0");
        var app = b.Build();
        FakeUpstream? self = null;
        app.Run(async ctx =>
        {
            using var r = new StreamReader(ctx.Request.Body);
            string body = await r.ReadToEndAsync();
            self!.Seen.Enqueue(new SeenRequest(ctx.Request.Method, ctx.Request.Path + ctx.Request.QueryString,
                ctx.Request.Headers.ToDictionary(h => h.Key.ToLowerInvariant(), h => h.Value.ToString()), body));
            await self.Respond(ctx);
        });
        await app.StartAsync();
        string url = app.Services.GetService(typeof(IServer)) is IServer s ? s.Features.Get<IServerAddressesFeature>()!.Addresses.First() : "";
        self = new FakeUpstream(app, url);
        return self;
    }

    public static Task Json(HttpContext ctx, string json, int status = 200)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        return ctx.Response.WriteAsync(json);
    }

    public async ValueTask DisposeAsync() => await _app.DisposeAsync();
}

/// <summary>Runs the real gateway (Kestrel on a Unix socket) in-process against a fake upstream.</summary>
public sealed class Gateway : IAsyncDisposable
{
    public const string Key = "sk-test-REAL-KEY-0123456789";
    private readonly WebApplication _app;
    private readonly CallLog _log;
    public string Dir { get; }
    public string Socket => Path.Combine(Dir, "gw.sock");
    public string LogPath => Path.Combine(Dir, "llm.log");
    public string TotalsPath => Path.Combine(Dir, "totals.json");
    public RunState State { get; }
    public FakeUpstream Upstream { get; }

    private Gateway(WebApplication app, CallLog log, string dir, RunState state, FakeUpstream up)
    {
        _app = app; _log = log; Dir = dir; State = state; Upstream = up;
    }

    public static string ProfilesJson(string limitsJson = """{"max_requests":500,"max_request_bytes":16384,"max_response_bytes":1048576,"request_timeout_sec":30,"token_budget":1000000}""") => $$"""
        { "version": 1, "limits": {{limitsJson}},
          "profiles": {
            "claude": { "client":"claude","provider":"anthropic","upstream":"https://api.anthropic.com","auth":"x-api-key","key_env":"ANTHROPIC_API_KEY",
                        "default_model":"claude-opus-5-5","models":["claude-*"],"endpoints":["POST /v1/messages","POST /v1/messages/count_tokens"],"usage_style":"anthropic","direct":true },
            "codex":  { "client":"codex","provider":"openai","upstream":"https://api.openai.com","auth":"bearer","key_env":"OPENAI_API_KEY",
                        "default_model":"gpt-5.1-codex-max","models":["gpt-*"],"endpoints":["POST /v1/responses","POST /v1/chat/completions","GET /v1/models"],"usage_style":"openai","direct":true },
            "codex-ollama": { "client":"codex","provider":"ollama","upstream":"ollama","auth":"none","key_env":"",
                        "default_model":"gpt-oss:20b","models":["*"],"endpoints":["POST /v1/responses","GET /v1/models"],"usage_style":"openai","direct":false } } }
        """;

    public static async Task<Gateway> Start(string profile = "claude", string? limitsJson = null)
    {
        var up = await FakeUpstream.Start();
        string dir = Path.Combine(Path.GetTempPath(), "fcgw-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(dir);
        var p = ProfileLoader.Load(limitsJson is null ? ProfilesJson() : ProfilesJson(limitsJson), profile, "http://127.0.0.1:1", up.Url, null);
        var state = new RunState(p.Limits);
        var log = new CallLog(Path.Combine(dir, "llm.log"), Path.Combine(dir, "totals.json"), Key);
        var app = GatewayApp.Build(new GatewayOptions(Path.Combine(dir, "gw.sock"), Path.Combine(dir, "llm.log"), Path.Combine(dir, "totals.json")), p, Key, state, log);
        await app.StartAsync();
        return new Gateway(app, log, dir, state, up);
    }

    /// <summary>An HTTP client whose every connection goes to the gateway's Unix socket (like the guest shim).</summary>
    public HttpClient Client()
    {
        var h = new SocketsHttpHandler
        {
            ConnectCallback = async (_, ct) =>
            {
                var s = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                await s.ConnectAsync(new UnixDomainSocketEndPoint(Socket), ct);
                return new NetworkStream(s, ownsSocket: true);
            },
        };
        return new HttpClient(h) { BaseAddress = new Uri("http://127.0.0.1:8080") };
    }

    /// <summary>A raw connection for malformed-input tests.</summary>
    public async Task<Socket> Raw()
    {
        var s = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        await s.ConnectAsync(new UnixDomainSocketEndPoint(Socket));
        return s;
    }

    public string[] LogLines() => File.Exists(LogPath)
        ? ReadShared(LogPath).Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries).Where(l => !l.Contains(" event=")).ToArray() : [];

    /// <summary>Reads a file the gateway still has open for writing.</summary>
    public static string ReadShared(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var r = new StreamReader(fs);
        return r.ReadToEnd();
    }

    public static StringContent Body(string json) => new(json, Encoding.UTF8, "application/json");

    public async ValueTask DisposeAsync()
    {
        await _app.DisposeAsync();
        _log.Dispose();
        await Upstream.DisposeAsync();
        try { Directory.Delete(Dir, recursive: true); } catch (IOException) { }
    }
}
