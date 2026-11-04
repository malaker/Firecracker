using System.Net;
using System.Net.Sockets;
using System.Text;
using FcEgress.Protocol;

namespace FcEgress.Relay;

// Guest side: an HTTP proxy on loopback whose every connection becomes one stream over the
// relay channel to the host. Refusals are answered locally with a short HTTP status.
public sealed class RelayServer(Mux mux, IPEndPoint listen)
{
    public static readonly IPEndPoint DefaultEndpoint = new(IPAddress.Loopback, 3128);

    public TimeSpan HeadTimeout { get; init; } = TimeSpan.FromSeconds(30);
    public TimeSpan OpenTimeout { get; init; } = TimeSpan.FromSeconds(30);
    public int BoundPort { get; private set; }

    // Accepts clients until the channel ends (mux.RunAsync completes) or ct is cancelled.
    public async Task RunAsync(Task channel, CancellationToken ct = default)
    {
        var listener = new TcpListener(listen);
        listener.Start(backlog: 128);
        BoundPort = ((IPEndPoint)listener.LocalEndpoint).Port;
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _ = channel.ContinueWith(_ => stop.Cancel(), TaskScheduler.Default);
        try
        {
            while (!stop.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(stop.Token);
                client.NoDelay = true;
                _ = Task.Run(() => HandleClientAsync(client, stop.Token), CancellationToken.None);
            }
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            listener.Stop();
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken ct)
    {
        var stream = client.GetStream();
        try
        {
            var (head, leftover) = await ReadHeadAsync(stream, ct);
            if (head is null)
            {
                await RespondAsync(stream, 400, "request head missing, too large or too slow", ct);
                return;
            }
            var request = ProxyRequest.TryParse(head, out var error);
            if (request is null)
            {
                await RespondAsync(stream, 400, error, ct);
                return;
            }

            MuxStream? s;
            OpenFailReason? failure;
            try
            {
                (s, failure) = await mux.OpenAsync(request.Host, request.Port, OpenTimeout, ct);
            }
            catch (TimeoutException)
            {
                await RespondAsync(stream, 504, "egress proxy did not answer", ct);
                return;
            }
            if (s is null)
            {
                var (code, text) = failure switch
                {
                    OpenFailReason.Denied => (403, $"connection to {request.Host}:{request.Port} denied by sandbox policy"),
                    OpenFailReason.ConnectFailed => (502, $"could not connect to {request.Host}:{request.Port}"),
                    _ => (503, "too many concurrent connections"),
                };
                await RespondAsync(stream, code, text, ct);
                return;
            }

            byte[] initial;
            if (request.IsConnect)
            {
                await stream.WriteAsync("HTTP/1.1 200 Connection established\r\n\r\n"u8.ToArray(), ct);
                initial = leftover;
            }
            else
            {
                initial = [.. request.Forward, .. leftover];
            }
            await mux.BridgeAsync(s, stream, initial);
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or SocketException or ObjectDisposedException)
        {
        }
        finally
        {
            client.Dispose();
        }
    }

    private async Task<(string? Head, byte[] Leftover)> ReadHeadAsync(NetworkStream stream, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(HeadTimeout);
        var buf = new byte[ProxyRequest.MaxHeadBytes];
        int len = 0;
        try
        {
            while (len < buf.Length)
            {
                int n = await stream.ReadAsync(buf.AsMemory(len), timeout.Token);
                if (n == 0) return (null, []);
                int searchFrom = Math.Max(0, len - 3);
                len += n;
                int end = buf.AsSpan(searchFrom, len - searchFrom).IndexOf("\r\n\r\n"u8);
                if (end >= 0)
                {
                    int headEnd = searchFrom + end;
                    return (Encoding.ASCII.GetString(buf, 0, headEnd), buf[(headEnd + 4)..len]);
                }
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
        }
        return (null, []);
    }

    private static async Task RespondAsync(NetworkStream stream, int code, string message, CancellationToken ct)
    {
        string reason = code switch { 400 => "Bad Request", 403 => "Forbidden", 502 => "Bad Gateway", 503 => "Service Unavailable", _ => "Gateway Timeout" };
        string body = $"fc-egress: {message}\n";
        string response = $"HTTP/1.1 {code} {reason}\r\nContent-Type: text/plain\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n{body}";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(response), ct);
    }
}
