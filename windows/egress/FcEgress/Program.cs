using FcEgress.Host;
using FcEgress.Policy;

namespace FcEgress;

internal static class Program
{
    private const string Usage =
        "usage: fc-egress launch --docker <docker.exe> --container <name> --policy <file> --stderr-dir <dir>\n" +
        "       fc-egress serve --policy <file>\n" +
        "       fc-egress token-info";

    private static async Task<int> Main(string[] args)
    {
        try
        {
            return args.FirstOrDefault() switch
            {
                "serve" => await ServeAsync(Options.Parse(args[1..])),
                "launch" => Launcher.Run(Options.Parse(args[1..])),
                "token-info" => PrintTokenInfo(),
                _ => Fail(Usage, 2),
            };
        }
        catch (Exception ex) when (ex is ArgumentException or FormatException or IOException or KeyNotFoundException)
        {
            return Fail($"fc-egress: {ex.Message}", 2);
        }
    }

    private static int PrintTokenInfo()
    {
        Console.WriteLine(TokenInfo.Describe());
        return 0;
    }

    // stdin/stdout are the relay channel (pipes to 'docker exec -i ... fc-relay.exe');
    // nothing else may ever be written to stdout.
    private static async Task<int> ServeAsync(Options o)
    {
        Console.Error.WriteLine($"fc-egress serve: {TokenInfo.Describe()}");
        if (TokenInfo.HasAdminRights(out var why))
        {
            return Fail($"fc-egress serve: refusing to run with administrator rights ({why})", 3);
        }
        var config = ServeConfig.Load(o.Require("policy"));
        using var log = new NetLog(config.LogPath);
        log.Event("start", $"run_id={config.RunId} allow={string.Join(',', config.Allow)}");
        var server = new EgressServer(new EgressPolicy(config.Allow), log);
        await using var input = Console.OpenStandardInput();
        await using var output = Console.OpenStandardOutput();
        await server.RunAsync(input, output);
        log.Event("stop", "channel closed");
        return 0;
    }

    private static int Fail(string message, int code)
    {
        Console.Error.WriteLine(message);
        return code;
    }
}

internal sealed class Options
{
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);

    public static Options Parse(string[] args)
    {
        var o = new Options();
        for (int i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal) || i + 1 >= args.Length)
            {
                throw new ArgumentException($"unexpected argument '{args[i]}'");
            }
            o._values[args[i][2..]] = args[++i];
        }
        return o;
    }

    public string Require(string name) =>
        _values.TryGetValue(name, out var v) && v.Length > 0 ? v : throw new ArgumentException($"missing --{name}");
}
