using System.Reflection;
using FcEgress.Protocol;
using FcEgress.Relay;

namespace FcRelay;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        switch (args.FirstOrDefault())
        {
            case "--version":
                Console.WriteLine($"fc-relay {Assembly.GetExecutingAssembly().GetName().Version}");
                return 0;
            case "--set-netfx-proxy" when args.Length == 2:
                return NetfxProxyConfig.Apply(args[1]);
            case null:
                break;
            default:
                Console.Error.WriteLine("usage: fc-relay [--version | --set-netfx-proxy <http://host:port>]");
                return 2;
        }

        // stdin/stdout are the relay channel to the host (docker exec -i); never write to stdout.
        await using var input = Console.OpenStandardInput();
        await using var output = Console.OpenStandardOutput();
        var mux = new Mux(input, output) { ProtocolError = e => Console.Error.WriteLine($"fc-relay: protocol error: {e}") };
        var channel = mux.RunAsync();
        var relay = new RelayServer(mux, RelayServer.DefaultEndpoint);
        await relay.RunAsync(channel);
        await channel;
        return 0;
    }
}
