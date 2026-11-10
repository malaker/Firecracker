using FcGateway;

// fc-llm-gateway --profiles FILE --profile NAME --socket PATH --log FILE [--totals FILE]
//                [--upstream-url URL] [--token-budget N]
// The provider key is read from the first line of stdin (profiles with auth "none" need none).
// FC_GATEWAY_TEST_UPSTREAM=http://127.0.0.1:<port> points the gateway at a local fake provider (tests).
// Exit codes: 0 stopped, 2 bad arguments or configuration.
if (args is ["--version"])
{
    Console.WriteLine($"fc-llm-gateway {typeof(Proxy).Assembly.GetName().Version?.ToString(3)}");
    return 0;
}
try
{
    var a = Args.Parse(args);
    var profile = ProfileLoader.Load(File.ReadAllText(a.Require("profiles")), a.Require("profile"), a.Get("upstream-url"),
        Environment.GetEnvironmentVariable("FC_GATEWAY_TEST_UPSTREAM"),
        a.Get("token-budget") is { } tb ? long.Parse(tb, System.Globalization.CultureInfo.InvariantCulture) : null);

    string key = "";
    if (profile.Auth != AuthStyle.None)
    {
        key = (Console.In.ReadLine() ?? "").Trim();
        if (key.Length == 0) throw new ConfigException($"no API key on stdin for profile '{profile.Name}'");
    }

    string socket = a.Require("socket");
    if (File.Exists(socket)) File.Delete(socket);
    var state = new RunState(profile.Limits);
    using var log = new CallLog(a.Require("log"), a.Get("totals"), key);
    var app = GatewayApp.Build(new GatewayOptions(socket, a.Require("log"), a.Get("totals")), profile, key, state, log);
    await app.RunAsync();
    return 0;
}
catch (Exception ex) when (ex is ConfigException or ArgumentException or FormatException or IOException or KeyNotFoundException or InvalidOperationException)
{
    Console.Error.WriteLine($"fc-llm-gateway: {ex.Message}");
    return 2;
}

internal sealed class Args
{
    private readonly Dictionary<string, string> _v = new(StringComparer.Ordinal);

    public static Args Parse(string[] args)
    {
        var a = new Args();
        for (int i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal) || i + 1 >= args.Length) throw new ArgumentException($"unexpected argument '{args[i]}'");
            a._v[args[i][2..]] = args[++i];
        }
        return a;
    }

    public string Require(string k) => _v.TryGetValue(k, out var v) && v.Length > 0 ? v : throw new ArgumentException($"missing --{k}");
    public string? Get(string k) => _v.TryGetValue(k, out var v) && v.Length > 0 ? v : null;
}
