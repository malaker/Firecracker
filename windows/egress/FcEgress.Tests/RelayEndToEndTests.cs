using System.Net;
using System.Net.Sockets;
using System.Text;
using FcEgress.Host;
using FcEgress.Policy;
using FcEgress.Protocol;
using FcEgress.Relay;

namespace FcEgress.Tests;

// Relay (guest) and EgressServer (host) back to back over a loopback channel, with
// curl-style proxy requests from a client.
public sealed class RelayEndToEndTests : IAsyncLifetime
{
    private readonly CancellationTokenSource _cts = new(TimeSpan.FromSeconds(30));
    private readonly string _logPath = Path.Combine(Path.GetTempPath(), $"fc-relay-test-{Guid.NewGuid():N}.log");
    private readonly TcpListener _echo = new(IPAddress.Loopback, 0);
    private readonly TcpListener _web = new(IPAddress.Loopback, 0);
    private string? _lastWebRequest;
    private RelayServer _relay = null!;
    private int EchoPort => ((IPEndPoint)_echo.LocalEndpoint).Port;
    private int WebPort => ((IPEndPoint)_web.LocalEndpoint).Port;

    public async Task InitializeAsync()
    {
        _echo.Start();
        _ = Task.Run(async () =>
        {
            while (true)
            {
                var c = await _echo.AcceptTcpClientAsync(_cts.Token);
                _ = c.GetStream().CopyToAsync(c.GetStream(), _cts.Token).ContinueWith(_ => c.Dispose());
            }
        });
        _web.Start();
        _ = Task.Run(async () =>
        {
            while (true)
            {
                using var c = await _web.AcceptTcpClientAsync(_cts.Token);
                var s = c.GetStream();
                var buf = new byte[8192];
                int len = 0;
                while (!Encoding.ASCII.GetString(buf, 0, len).Contains("\r\n\r\n")) len += await s.ReadAsync(buf.AsMemory(len), _cts.Token);
                _lastWebRequest = Encoding.ASCII.GetString(buf, 0, len);
                await s.WriteAsync("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"u8.ToArray(), _cts.Token);
            }
        });

        var (guestEnd, hostEnd) = await Loopback.PairAsync();
        var policy = new EgressPolicy([Cidr.Parse("127.0.0.1/32")], () => []);
        _ = new EgressServer(policy, new NetLog(_logPath)).RunAsync(hostEnd, hostEnd, _cts.Token);
        var mux = new Mux(guestEnd, guestEnd);
        var channel = mux.RunAsync(_cts.Token);
        _relay = new RelayServer(mux, new IPEndPoint(IPAddress.Loopback, 0));
        _ = _relay.RunAsync(channel, _cts.Token);
        while (_relay.BoundPort == 0) await Task.Delay(5);
    }

    public Task DisposeAsync()
    {
        _cts.Cancel();
        _echo.Stop();
        _web.Stop();
        return Task.CompletedTask;
    }

    private async Task<(NetworkStream Stream, string Head)> SendAsync(string request)
    {
        var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, _relay.BoundPort);
        var s = client.GetStream();
        await s.WriteAsync(Encoding.ASCII.GetBytes(request));
        var buf = new byte[4096];
        int len = 0;
        while (!Encoding.ASCII.GetString(buf, 0, len).Contains("\r\n\r\n"))
        {
            int n = await s.ReadAsync(buf.AsMemory(len));
            if (n == 0) break;
            len += n;
        }
        return (s, Encoding.ASCII.GetString(buf, 0, len));
    }

    [Fact]
    public async Task Connect_tunnel_carries_bytes_both_ways()
    {
        var (s, head) = await SendAsync($"CONNECT 127.0.0.1:{EchoPort} HTTP/1.1\r\nHost: 127.0.0.1:{EchoPort}\r\n\r\n");
        Assert.StartsWith("HTTP/1.1 200", head);
        await s.WriteAsync("tunnel"u8.ToArray());
        var buf = new byte[6];
        int got = 0;
        while (got < 6) got += await s.ReadAsync(buf.AsMemory(got));
        Assert.Equal("tunnel", Encoding.ASCII.GetString(buf));
    }

    [Fact]
    public async Task Absolute_uri_get_is_rewritten_and_answered()
    {
        using var http = new HttpClient(new HttpClientHandler { Proxy = new WebProxy($"http://127.0.0.1:{_relay.BoundPort}"), UseProxy = true });
        var body = await http.GetStringAsync($"http://127.0.0.1:{WebPort}/path?q=1");
        Assert.Equal("ok", body);
        Assert.NotNull(_lastWebRequest);
        Assert.StartsWith("GET /path?q=1 HTTP/1.1\r\n", _lastWebRequest);
        Assert.DoesNotContain("Proxy-", _lastWebRequest, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Connection: close", _lastWebRequest);
    }

    [Fact]
    public async Task Denied_connect_gets_403()
    {
        var (_, head) = await SendAsync("CONNECT 8.8.8.8:443 HTTP/1.1\r\nHost: 8.8.8.8:443\r\n\r\n");
        Assert.StartsWith("HTTP/1.1 403", head);
    }

    [Fact]
    public async Task Ipv6_literal_connect_gets_403()
    {
        var (_, head) = await SendAsync("CONNECT [2606:4700:4700::1111]:443 HTTP/1.1\r\n\r\n");
        Assert.StartsWith("HTTP/1.1 403", head);
    }

    [Fact]
    public async Task Sentinel_probe_gets_403_without_any_lookup()
    {
        var (_, head) = await SendAsync("GET http://fc-egress.invalid/ HTTP/1.1\r\nHost: fc-egress.invalid\r\n\r\n");
        Assert.StartsWith("HTTP/1.1 403", head);
    }

    [Fact]
    public async Task Failed_connect_gets_502()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        int closed = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var (_, head) = await SendAsync($"CONNECT 127.0.0.1:{closed} HTTP/1.1\r\n\r\n");
        Assert.StartsWith("HTTP/1.1 502", head);
    }

    [Theory]
    [InlineData("GET /local HTTP/1.1\r\n\r\n")]
    [InlineData("GET https://example.com/ HTTP/1.1\r\n\r\n")]
    [InlineData("CONNECT example.com HTTP/1.1\r\n\r\n")]
    [InlineData("garbage\r\n\r\n")]
    public async Task Non_proxy_requests_get_400(string request)
    {
        var (_, head) = await SendAsync(request);
        Assert.StartsWith("HTTP/1.1 400", head);
    }
}
