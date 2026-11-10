using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;

namespace FcGateway;

/// <summary>
/// Handles one guest request (spec: llm-gateway). Everything from the guest is untrusted: only the
/// profile's endpoints and models pass, the upstream request is rebuilt from a header allowlist, the
/// guest's credentials are dropped and the host-side key is added, and the destination is always the
/// profile's single upstream.
/// </summary>
public sealed class Proxy(Profile profile, string key, HttpClient upstream, RunState state, CallLog log)
{
    // Request headers forwarded upstream (besides content-type); everything else is dropped.
    private static readonly string[] ForwardHeaders = ["anthropic-version", "anthropic-beta", "accept", "openai-beta"];
    // Response headers passed back to the guest.
    private static readonly string[] ReturnHeaders = ["content-type", "retry-after", "request-id", "x-request-id"];
    private const int MaxQueryLength = 256;
    // The error body is JSON for an API client, not HTML: keep quotes readable.
    private static readonly JsonSerializerOptions ErrorJson = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public async Task Handle(HttpContext ctx)
    {
        string method = ctx.Request.Method;
        string path = ctx.Request.Path.Value ?? "";
        string query = ctx.Request.QueryString.Value ?? "";

        if (!profile.AllowsEndpoint(method, path))
        {
            await Refuse(ctx, 403, method, path, "-", "endpoint not allowed");
            return;
        }
        if (query.Length > MaxQueryLength || query.IndexOfAny(['\r', '\n']) >= 0)
        {
            await Refuse(ctx, 403, method, path, "-", "query string not allowed");
            return;
        }

        byte[] body;
        try
        {
            using var ms = new MemoryStream();
            await ctx.Request.Body.CopyToAsync(ms, ctx.RequestAborted);
            body = ms.ToArray();
        }
        catch (BadHttpRequestException ex) when (ex.StatusCode == StatusCodes.Status413PayloadTooLarge)
        {
            await Refuse(ctx, 413, method, path, "-", $"request body larger than {profile.Limits.MaxRequestBytes} bytes");
            return;
        }

        string model = "-";
        if (method == "POST")
        {
            model = ReadModel(body) ?? "";
            if (!profile.AllowsModel(model))
            {
                await Refuse(ctx, 403, method, path, model, model.Length == 0 ? "request names no model" : $"model '{model}' is not allowed");
                return;
            }
        }

        string? budget = state.TryStartRequest();
        if (budget is not null)
        {
            await Refuse(ctx, 429, method, path, model, budget);
            return;
        }
        state.AddUp(body.Length);
        await Forward(ctx, method, path + query, model, body);
    }

    private async Task Forward(HttpContext ctx, string method, string pathAndQuery, string model, byte[] body)
    {
        using var req = new HttpRequestMessage(new HttpMethod(method), new Uri(profile.Upstream, pathAndQuery));
        if (method == "POST")
        {
            req.Content = new ByteArrayContent(body);
            req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }
        foreach (string h in ForwardHeaders)
        {
            if (ctx.Request.Headers.TryGetValue(h, out var v)) req.Headers.TryAddWithoutValidation(h, v.ToArray());
        }
        switch (profile.Auth)
        {
            case AuthStyle.XApiKey: req.Headers.TryAddWithoutValidation("x-api-key", key); break;
            case AuthStyle.Bearer: req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key); break;
        }

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted);
        cts.CancelAfter(TimeSpan.FromSeconds(profile.Limits.RequestTimeoutSec));
        long down = 0;
        UsageScanner? usage = null;
        int status = 0;
        try
        {
            using var resp = await upstream.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            status = (int)resp.StatusCode;
            ctx.Response.StatusCode = status;
            foreach (string h in ReturnHeaders)
            {
                if (resp.Headers.TryGetValues(h, out var hv) || resp.Content.Headers.TryGetValues(h, out hv)) ctx.Response.Headers[h] = hv.ToArray();
            }
            bool sse = resp.Content.Headers.ContentType?.MediaType == "text/event-stream";
            usage = new UsageScanner(profile.Usage, sse);

            await using var src = await resp.Content.ReadAsStreamAsync(cts.Token);
            var buf = new byte[16 * 1024];
            int n;
            while ((n = await src.ReadAsync(buf, cts.Token)) > 0)
            {
                down += n;
                if (!state.TryAddDown(n))
                {
                    log.Write(new LogEntry(ctx.Request.Method, ctx.Request.Path, model, "failed", "response budget spent", status, body.Length, down, 0, 0), state);
                    ctx.Abort();
                    return;
                }
                usage.Feed(buf.AsSpan(0, n));
                await ctx.Response.Body.WriteAsync(buf.AsMemory(0, n), cts.Token);
                if (sse) await ctx.Response.Body.FlushAsync(cts.Token);
            }
            usage.Complete();
            state.AddTokens(usage.Total);
            log.Write(new LogEntry(ctx.Request.Method, ctx.Request.Path, model, "forwarded", "-", status, body.Length, down, usage.InputTokens, usage.OutputTokens), state);
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or IOException)
        {
            bool timedOut = ex is OperationCanceledException && !ctx.RequestAborted.IsCancellationRequested;
            string reason = timedOut ? $"upstream did not finish within {profile.Limits.RequestTimeoutSec}s"
                : ctx.RequestAborted.IsCancellationRequested ? "guest closed the connection" : $"upstream error: {ex.GetType().Name}";
            if (usage is not null) { usage.Complete(); state.AddTokens(usage.Total); }
            log.Write(new LogEntry(ctx.Request.Method, ctx.Request.Path, model, "failed", reason, status, body.Length, down, usage?.InputTokens ?? 0, usage?.OutputTokens ?? 0), state);
            if (!ctx.Response.HasStarted)
            {
                await WriteError(ctx, timedOut ? 504 : 502, reason);
            }
            else
            {
                ctx.Abort();
            }
        }
    }

    private async Task Refuse(HttpContext ctx, int status, string method, string path, string model, string reason)
    {
        state.CountRefused();
        log.Write(new LogEntry(method, path, model, "refused", reason, status, 0, 0, 0, 0), state);
        await WriteError(ctx, status, reason);
    }

    private static async Task WriteError(HttpContext ctx, int status, string reason)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        string json = JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["type"] = "error",
            ["error"] = new Dictionary<string, string> { ["type"] = "fc_gateway", ["message"] = "fc-llm-gateway: " + reason },
        }, ErrorJson);
        await ctx.Response.Body.WriteAsync(Encoding.UTF8.GetBytes(json));
    }

    /// <summary>The top-level "model" string of a JSON request body, or null.</summary>
    internal static string? ReadModel(byte[] body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 64 });
            return doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("model", out var m) && m.ValueKind == JsonValueKind.String
                ? m.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
