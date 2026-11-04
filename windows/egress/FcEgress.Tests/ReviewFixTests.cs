using System.Net;
using FcEgress.Host;
using FcEgress.Policy;
using FcEgress.Protocol;

namespace FcEgress.Tests;

// Regression tests for the issues found in the final code review.
public sealed class ReviewFixTests : IDisposable
{
    private readonly string _logPath = Path.Combine(Path.GetTempPath(), $"fc-review-test-{Guid.NewGuid():N}.log");
    private readonly CancellationTokenSource _cts = new(TimeSpan.FromSeconds(30));

    public void Dispose()
    {
        _cts.Cancel();
        try { File.Delete(_logPath); } catch (IOException) { }
    }

    private string[] LogLines()
    {
        if (!File.Exists(_logPath)) return [];
        using var fs = new FileStream(_logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return new StreamReader(fs).ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries);
    }

    // A stream whose writes take a while and would honour cancellation if given the token.
    private sealed class SlowStream : MemoryStream
    {
        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
        {
            await Task.Delay(100, ct);
            await base.WriteAsync(buffer, ct);
        }
    }

    [Fact]
    public async Task Frame_is_written_whole_even_if_cancelled_mid_write()
    {
        var slow = new SlowStream();
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(20));
        await new FrameWriter(slow).WriteAsync(FrameType.Data, 3, new byte[] { 1, 2, 3, 4 }, cts.Token);

        slow.Position = 0;
        var frame = await new FrameReader(slow).ReadAsync();
        Assert.NotNull(frame);
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, frame.Value.Payload);
        Assert.Null(await new FrameReader(slow).ReadAsync());
    }

    [Fact]
    public async Task Cancelled_before_the_channel_is_free_writes_nothing()
    {
        var ms = new MemoryStream();
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new FrameWriter(ms).WriteAsync(FrameType.Close, 1, default, cts.Token).AsTask());
        Assert.Equal(0, ms.Length);
    }

    private async Task<Mux> StartAsync(EgressServer.Connector connect, int maxStreams)
    {
        var (guestEnd, hostEnd) = await Loopback.PairAsync();
        var policy = new EgressPolicy([Cidr.Parse("127.0.0.1/32")], () => []);
        _ = new EgressServer(policy, new NetLog(_logPath)) { Connect = connect, MaxStreams = maxStreams }.RunAsync(hostEnd, hostEnd, _cts.Token);
        var guest = new Mux(guestEnd, guestEnd);
        _ = guest.RunAsync(_cts.Token);
        return guest;
    }

    [Fact]
    public async Task Guest_open_timeout_tells_the_host_and_frees_its_stream_slot()
    {
        // The host's connect hangs until it is cancelled.
        var guest = await StartAsync(async (_, _, ct) => { await Task.Delay(Timeout.Infinite, ct); return Stream.Null; }, maxStreams: 1);

        await Assert.ThrowsAsync<TimeoutException>(() => guest.OpenAsync("127.0.0.1", 9, TimeSpan.FromMilliseconds(200)));

        // With MaxStreams = 1, a second open only gets past the limit once the host freed the slot.
        var deadline = DateTime.UtcNow.AddSeconds(5);
        OpenFailReason? failure = OpenFailReason.LimitReached;
        while (failure == OpenFailReason.LimitReached && DateTime.UtcNow < deadline)
        {
            try
            {
                (_, failure) = await guest.OpenAsync("8.8.8.8", 443, TimeSpan.FromSeconds(5));
            }
            catch (TimeoutException)
            {
            }
            if (failure == OpenFailReason.LimitReached) await Task.Delay(50);
        }
        Assert.Equal(OpenFailReason.Denied, failure);
        Assert.Contains(LogLines(), l => l.Contains("guest-cancelled"));
    }

    [Fact]
    public async Task Host_handler_failure_fails_the_open_immediately()
    {
        var guest = await StartAsync((_, _, _) => throw new InvalidOperationException("unexpected"), maxStreams: 4);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var (s, failure) = await guest.OpenAsync("127.0.0.1", 9, TimeSpan.FromSeconds(20));
        Assert.Null(s);
        Assert.Equal(OpenFailReason.ConnectFailed, failure);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(5), $"open took {sw.Elapsed}");
    }

    [Fact]
    public async Task Stream_ids_wrap_around_instead_of_running_out()
    {
        var (guestEnd, hostEnd) = await Loopback.PairAsync();
        var host = new Mux(hostEnd, hostEnd, async (mux, s) =>
        {
            await mux.AcceptAsync(s);
            await mux.BridgeAsync(s, new CountingSink());
        });
        _ = host.RunAsync(_cts.Token);
        var guest = new Mux(guestEnd, guestEnd) { NextId = (int)Limits.MaxStreamId - 2 };
        _ = guest.RunAsync(_cts.Token);

        var ids = new List<uint>();
        for (int i = 0; i < 5; i++)
        {
            var (s, failure) = await guest.OpenAsync("example.com", 443, TimeSpan.FromSeconds(5));
            Assert.Null(failure);
            ids.Add(s!.Id);
        }
        Assert.Contains(Limits.MaxStreamId, ids);
        Assert.Contains(1u, ids);
        Assert.All(ids, id => Assert.InRange(id, 1u, Limits.MaxStreamId));
        Assert.Equal(ids.Count, ids.Distinct().Count());
    }

    [Fact]
    public async Task Host_addresses_are_read_once_per_decision()
    {
        int reads = 0;
        var policy = new EgressPolicy([], () => { reads++; return []; },
            (_, _) => Task.FromResult(new[] { IPAddress.Parse("10.0.0.1"), IPAddress.Parse("10.0.0.2"), IPAddress.Parse("10.0.0.3") }));
        var d = await policy.DecideAsync("many.example", 443);
        Assert.False(d.Allowed);
        Assert.Equal(1, reads);
    }
}
