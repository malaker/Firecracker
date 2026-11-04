using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using FcEgress.Host;
using FcEgress.Policy;
using FcEgress.Protocol;

namespace FcEgress.Tests;

public sealed class EgressServerTests : IAsyncLifetime
{
    private readonly TcpListener _echo = new(IPAddress.Loopback, 0);
    private readonly string _logPath = Path.Combine(Path.GetTempPath(), $"fc-egress-test-{Guid.NewGuid():N}.log");
    private readonly CancellationTokenSource _cts = new(TimeSpan.FromSeconds(30));
    private int EchoPort => ((IPEndPoint)_echo.LocalEndpoint).Port;

    public Task InitializeAsync()
    {
        _echo.Start();
        _ = Task.Run(async () =>
        {
            while (!_cts.IsCancellationRequested)
            {
                var c = await _echo.AcceptTcpClientAsync(_cts.Token);
                _ = c.GetStream().CopyToAsync(c.GetStream(), _cts.Token).ContinueWith(_ => c.Dispose());
            }
        });
        return Task.CompletedTask;
    }

    public Task DisposeAsync()
    {
        _cts.Cancel();
        _echo.Stop();
        try { File.Delete(_logPath); } catch (IOException) { }
        return Task.CompletedTask;
    }

    // The test listener is on 127.0.0.1, which is only reachable because the fake host list
    // is empty and the allowlist names it; real host addresses can never be allowlisted.
    private async Task<(Mux Guest, NetworkStream GuestEnd, Task Server, NetLog Log)> StartAsync(int maxStreams = Limits.MaxStreams)
    {
        var (guestEnd, hostEnd) = await Loopback.PairAsync();
        var log = new NetLog(_logPath);
        var policy = new EgressPolicy([Cidr.Parse("127.0.0.1/32")], () => []);
        var server = new EgressServer(policy, log) { MaxStreams = maxStreams }.RunAsync(hostEnd, hostEnd, _cts.Token);
        var guest = new Mux(guestEnd, guestEnd);
        _ = guest.RunAsync(_cts.Token);
        return (guest, guestEnd, server, log);
    }

    private static async Task<string> RoundTripAsync(Mux guest, MuxStream s, string text)
    {
        var (app, relaySide) = await Loopback.PairAsync();
        _ = guest.BridgeAsync(s, relaySide);
        await app.WriteAsync(Encoding.ASCII.GetBytes(text));
        var buf = new byte[text.Length];
        int got = 0;
        while (got < buf.Length) got += await app.ReadAsync(buf.AsMemory(got));
        return Encoding.ASCII.GetString(buf);
    }

    // The server keeps the log open for writing, so read it with write sharing allowed.
    private string[] LogLines()
    {
        if (!File.Exists(_logPath)) return [];
        using var fs = new FileStream(_logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return new StreamReader(fs).ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries);
    }

    private async Task<string[]> WaitForLogAsync(Func<string[], bool> done)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        string[] lines;
        while (!done(lines = LogLines()) && DateTime.UtcNow < deadline) await Task.Delay(20);
        return lines;
    }

    [Fact]
    public async Task Allowed_connection_carries_data_and_is_logged_with_bytes()
    {
        var (guest, guestEnd, server, log) = await StartAsync();
        var (s, fail) = await guest.OpenAsync("127.0.0.1", (ushort)EchoPort, TimeSpan.FromSeconds(5));
        Assert.Null(fail);
        Assert.Equal("hello", await RoundTripAsync(guest, s!, "hello"));

        guestEnd.Dispose(); // channel EOF, as when the container stops
        await server.WaitAsync(TimeSpan.FromSeconds(10));
        log.Dispose();
        var line = Assert.Single(LogLines(), l => l.Contains("decision=allowed"));
        Assert.Contains($"host=127.0.0.1 port={EchoPort} ip=127.0.0.1", line);
        Assert.Contains("bytes_up=5 bytes_down=5", line);
    }

    [Fact]
    public async Task Denied_connection_is_refused_and_logged()
    {
        var (guest, _, _, _) = await StartAsync();
        var (s, fail) = await guest.OpenAsync("8.8.8.8", 443, TimeSpan.FromSeconds(5));
        Assert.Null(s);
        Assert.Equal(OpenFailReason.Denied, fail);
        var lines = await WaitForLogAsync(l => l.Any(x => x.Contains("decision=denied")));
        Assert.Contains(lines, l => l.Contains("decision=denied host=8.8.8.8 port=443 ip=8.8.8.8 reason=not-allowlisted"));
    }

    [Fact]
    public async Task Refused_connect_is_reported_as_failed()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        int closedPort = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var (guest, _, _, _) = await StartAsync();
        var (_, fail) = await guest.OpenAsync("127.0.0.1", (ushort)closedPort, TimeSpan.FromSeconds(15));
        Assert.Equal(OpenFailReason.ConnectFailed, fail);
        Assert.Contains(await WaitForLogAsync(l => l.Any(x => x.Contains("decision=failed"))), l => l.Contains("decision=failed"));
    }

    [Fact]
    public async Task Oversize_frame_closes_channel_and_logs_protocol_error()
    {
        var (_, guestEnd, server, log) = await StartAsync();
        var header = new byte[Limits.HeaderSize];
        header[0] = (byte)FrameType.Data;
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(1), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(5), Limits.MaxPayload + 1);
        await guestEnd.WriteAsync(header);

        await server.WaitAsync(TimeSpan.FromSeconds(10)); // the server ends; the process (and VM) are unaffected
        log.Dispose();
        Assert.Contains(LogLines(), l => l.Contains("event=protocol-error") && l.Contains("exceeds"));
    }

    [Fact]
    public async Task Streams_beyond_the_limit_are_refused_while_existing_ones_keep_working()
    {
        var (guest, _, _, _) = await StartAsync(maxStreams: 2);
        var (s1, _) = await guest.OpenAsync("127.0.0.1", (ushort)EchoPort, TimeSpan.FromSeconds(5));
        var (s2, _) = await guest.OpenAsync("127.0.0.1", (ushort)EchoPort, TimeSpan.FromSeconds(5));
        Assert.NotNull(s1);
        Assert.NotNull(s2);
        Assert.Equal("one", await RoundTripAsync(guest, s1!, "one"));

        var (s3, fail) = await guest.OpenAsync("127.0.0.1", (ushort)EchoPort, TimeSpan.FromSeconds(5));
        Assert.Null(s3);
        Assert.Equal(OpenFailReason.LimitReached, fail);
        Assert.Equal("two", await RoundTripAsync(guest, s2!, "two"));
        Assert.Contains(await WaitForLogAsync(l => l.Any(x => x.Contains("stream-limit"))), l => l.Contains("decision=denied") && l.Contains("reason=stream-limit"));
    }
}
