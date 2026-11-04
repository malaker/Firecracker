using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using FcEgress.Policy;
using FcEgress.Protocol;

namespace FcEgress.Host;

// Policy handed to 'serve' by the controller. Nothing in it comes from the guest.
public sealed record ServeConfig(string RunId, IReadOnlyList<Cidr> Allow, string LogPath)
{
    public static ServeConfig Load(string path)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var root = doc.RootElement;
        var allow = new List<Cidr>();
        if (root.TryGetProperty("allow", out var a) && a.ValueKind == JsonValueKind.Array)
        {
            foreach (var e in a.EnumerateArray())
            {
                allow.Add(Cidr.Parse(e.GetString() ?? ""));
            }
        }
        return new ServeConfig(root.GetProperty("run_id").GetString() ?? "", allow, root.GetProperty("log_path").GetString() ?? "");
    }
}

// Host side of the relay channel: decides each OPEN with the policy, connects outbound to
// the one address the policy picked, and logs every attempt.
public sealed class EgressServer(EgressPolicy policy, NetLog log)
{
    public delegate Task<Stream> Connector(IPAddress address, int port, CancellationToken ct);

    public TimeSpan ConnectTimeout { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan IdleTimeout { get; init; } = TimeSpan.FromSeconds(300);
    public int MaxStreams { get; init; } = Limits.MaxStreams;
    public Connector Connect { get; init; } = ConnectTcpAsync;

    public Task RunAsync(Stream input, Stream output, CancellationToken ct = default)
    {
        var mux = new Mux(input, output, HandleOpenAsync)
        {
            IdleTimeout = IdleTimeout,
            MaxStreams = MaxStreams,
            ProtocolError = e => log.Event("protocol-error", e),
            StreamClosed = Logged,
        };
        return mux.RunAsync(ct);
    }

    private async Task HandleOpenAsync(Mux mux, MuxStream s)
    {
        var decision = await policy.DecideAsync(s.Host, s.Port, s.Cancellation);
        s.Tag = decision;
        if (!decision.Allowed)
        {
            await mux.RejectAsync(s, OpenFailReason.Denied);
            return;
        }

        Stream remote;
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(s.Cancellation);
            cts.CancelAfter(ConnectTimeout);
            remote = await Connect(Ipv4.ToIPAddress(decision.Address!.Value), s.Port, cts.Token);
        }
        catch (Exception ex) when (ex is SocketException or OperationCanceledException or IOException)
        {
            s.CloseReason ??= "connect-failed";
            await mux.RejectAsync(s, OpenFailReason.ConnectFailed);
            return;
        }
        await mux.AcceptAsync(s);
        await mux.BridgeAsync(s, remote);
    }

    private void Logged(MuxStream s)
    {
        if (s.Tag is Decision d)
        {
            bool neverConnected = s.CloseReason is "connect-failed" or "guest-cancelled" or "handler-error";
            string outcome = !d.Allowed ? "denied" : neverConnected && s.BytesFromPeer == 0 && s.BytesToPeer == 0 ? "failed" : "allowed";
            string reason = s.CloseReason is { } r && d.Allowed ? $"{d.Reason},{r}" : d.Reason;
            log.Connection(outcome, s.Host, s.Port, d.AddressText, reason, s.BytesFromPeer, s.BytesToPeer);
        }
        else
        {
            log.Connection("denied", s.Host, s.Port, "-", s.CloseReason ?? "closed-before-decision", s.BytesFromPeer, s.BytesToPeer);
        }
    }

    private static async Task<Stream> ConnectTcpAsync(IPAddress address, int port, CancellationToken ct)
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(new IPEndPoint(address, port), ct);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }
}
