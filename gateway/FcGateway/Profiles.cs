using System.Text.Json;
using System.Text.RegularExpressions;

namespace FcGateway;

public sealed class ConfigException(string message) : Exception(message);

public enum AuthStyle { None, XApiKey, Bearer }
public enum UsageStyle { Anthropic, OpenAI }

public sealed record Limits(int MaxRequests, long MaxRequestBytes, long MaxResponseBytes, int RequestTimeoutSec, long TokenBudget);

/// <summary>One agent profile from profiles.json (design D3). Immutable after loading.</summary>
public sealed record Profile(
    string Name, string Provider, Uri Upstream, AuthStyle Auth, string KeyEnv, string DefaultModel,
    IReadOnlyList<string> ModelPatterns, IReadOnlyList<(string Method, string Path)> Endpoints, UsageStyle Usage, Limits Limits)
{
    public bool AllowsEndpoint(string method, string path) =>
        Endpoints.Any(e => e.Method.Equals(method, StringComparison.OrdinalIgnoreCase) && e.Path.Equals(path, StringComparison.Ordinal));

    /// <summary>Patterns are exact names or a prefix ending in '*'; '*' alone allows any model.</summary>
    public bool AllowsModel(string model) =>
        model.Length is > 0 and <= 200 && ModelPatterns.Any(p => p == "*" || (p.EndsWith('*') ? model.StartsWith(p[..^1], StringComparison.Ordinal) : model == p));
}

public static class ProfileLoader
{
    private static readonly Regex Endpoint = new(@"^(GET|POST) (/[A-Za-z0-9/_\-.]+)$");

    /// <summary>
    /// Loads <paramref name="name"/> from profiles.json. <paramref name="upstreamOverride"/> replaces the
    /// "ollama" placeholder (FC_OLLAMA_URL); <paramref name="testUpstream"/> is the test-only override.
    /// </summary>
    public static Profile Load(string json, string name, string? upstreamOverride, string? testUpstream, long? tokenBudget)
    {
        JsonElement root;
        try
        {
            root = JsonDocument.Parse(json).RootElement;
        }
        catch (JsonException ex)
        {
            throw new ConfigException($"profiles.json is not valid JSON: {ex.Message}");
        }
        if (!root.TryGetProperty("profiles", out var profiles) || !profiles.TryGetProperty(name, out var p))
        {
            throw new ConfigException($"unknown profile '{name}'");
        }
        var l = root.GetProperty("limits");
        var limits = new Limits(
            l.GetProperty("max_requests").GetInt32(), l.GetProperty("max_request_bytes").GetInt64(),
            l.GetProperty("max_response_bytes").GetInt64(), l.GetProperty("request_timeout_sec").GetInt32(),
            tokenBudget ?? l.GetProperty("token_budget").GetInt64());
        if (limits.MaxRequests <= 0 || limits.MaxRequestBytes <= 0 || limits.MaxResponseBytes <= 0 || limits.RequestTimeoutSec <= 0 || limits.TokenBudget <= 0)
        {
            throw new ConfigException("limits must be positive");
        }

        string upstream = p.GetProperty("upstream").GetString() ?? "";
        if (upstream == "ollama") upstream = upstreamOverride ?? throw new ConfigException("profile needs an Ollama URL (--upstream-url)");
        if (testUpstream is not null) upstream = CheckTestUpstream(testUpstream);
        if (!Uri.TryCreate(upstream, UriKind.Absolute, out var upstreamUri) || upstreamUri.Scheme is not ("https" or "http")
            || !string.IsNullOrEmpty(upstreamUri.Query) || upstreamUri.AbsolutePath != "/")
        {
            throw new ConfigException($"invalid upstream '{upstream}' (expected scheme://host[:port] with no path)");
        }

        var endpoints = new List<(string, string)>();
        foreach (var e in p.GetProperty("endpoints").EnumerateArray())
        {
            var m = Endpoint.Match(e.GetString() ?? "");
            if (!m.Success) throw new ConfigException($"invalid endpoint '{e.GetString()}'");
            endpoints.Add((m.Groups[1].Value, m.Groups[2].Value));
        }
        var models = p.GetProperty("models").EnumerateArray().Select(m => m.GetString() ?? "").ToList();
        if (models.Count == 0 || models.Any(m => m.Length == 0)) throw new ConfigException("profile needs at least one model pattern");

        return new Profile(
            name,
            p.GetProperty("provider").GetString() ?? "",
            upstreamUri,
            (p.GetProperty("auth").GetString() ?? "") switch
            {
                "x-api-key" => AuthStyle.XApiKey,
                "bearer" => AuthStyle.Bearer,
                "none" => AuthStyle.None,
                var a => throw new ConfigException($"unknown auth '{a}'"),
            },
            p.GetProperty("key_env").GetString() ?? "",
            p.GetProperty("default_model").GetString() ?? "",
            models,
            endpoints,
            (p.GetProperty("usage_style").GetString() ?? "") switch
            {
                "anthropic" => UsageStyle.Anthropic,
                "openai" => UsageStyle.OpenAI,
                var u => throw new ConfigException($"unknown usage_style '{u}'"),
            },
            limits);
    }

    /// <summary>FC_GATEWAY_TEST_UPSTREAM may only point at a plain-HTTP listener on 127.0.0.1 (smoke tests).</summary>
    public static string CheckTestUpstream(string value)
    {
        if (Uri.TryCreate(value, UriKind.Absolute, out var u) && u.Scheme == "http" && u.Host == "127.0.0.1"
            && !u.IsDefaultPort && u.AbsolutePath == "/" && u.Query.Length == 0 && u.UserInfo.Length == 0)
        {
            return $"http://127.0.0.1:{u.Port}";
        }
        throw new ConfigException("FC_GATEWAY_TEST_UPSTREAM must be http://127.0.0.1:<port>");
    }
}
