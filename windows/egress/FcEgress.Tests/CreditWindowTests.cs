using FcEgress.Protocol;

namespace FcEgress.Tests;

public class CreditWindowTests
{
    [Fact]
    public async Task Stalled_stream_does_not_block_others_or_exceed_its_window()
    {
        var (guestEnd, hostEnd) = await Loopback.PairAsync();
        string? protocolError = null;

        // Host: every accepted stream floods the guest with data.
        var host = new Mux(hostEnd, hostEnd, async (mux, s) =>
        {
            await mux.AcceptAsync(s);
            await mux.BridgeAsync(s, new InfiniteSource());
        }) { ProtocolError = e => protocolError = e };
        var guest = new Mux(guestEnd, guestEnd) { ProtocolError = e => protocolError = e };
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var hostRun = host.RunAsync(cts.Token);
        var guestRun = guest.RunAsync(cts.Token);

        // Stream A is opened but nobody ever reads it: it stalls after one window.
        var (a, _) = await guest.OpenAsync("stalled.example", 443, TimeSpan.FromSeconds(5));
        Assert.NotNull(a);

        // Stream B keeps being consumed.
        var (b, _) = await guest.OpenAsync("flowing.example", 443, TimeSpan.FromSeconds(5));
        Assert.NotNull(b);
        var sink = new CountingSink();
        _ = guest.BridgeAsync(b, sink);

        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (sink.Written < 4 * Limits.StreamWindow && DateTime.UtcNow < deadline) await Task.Delay(20);

        Assert.True(sink.Written >= 4 * Limits.StreamWindow, $"stream B only received {sink.Written} bytes");
        Assert.True(a.Receive.Outstanding <= Limits.StreamWindow, $"stream A buffered {a.Receive.Outstanding} bytes");
        Assert.True(a.BytesFromPeer <= Limits.StreamWindow, $"stream A received {a.BytesFromPeer} bytes");
        Assert.Null(protocolError);

        cts.Cancel();
        await Task.WhenAll(hostRun, guestRun);
    }

    [Fact]
    public void Receiver_rejects_data_beyond_the_window()
    {
        var w = new ReceiveWindow(Limits.StreamWindow);
        w.OnData(Limits.StreamWindow);
        Assert.Throws<ProtocolException>(() => w.OnData(1));
    }

    [Fact]
    public void Receiver_grants_credit_after_half_a_window_is_consumed()
    {
        var w = new ReceiveWindow(Limits.StreamWindow);
        w.OnData(Limits.StreamWindow);
        Assert.Equal(0u, w.OnConsumed(Limits.StreamWindow / 2 - 1));
        Assert.Equal((uint)(Limits.StreamWindow / 2), w.OnConsumed(1));
        w.OnData(Limits.StreamWindow / 2);
    }

    [Fact]
    public async Task Sender_waits_for_credit()
    {
        var c = new SendCredit(10);
        Assert.Equal(10, await c.AcquireAsync(100, default));
        var pending = c.AcquireAsync(5, default).AsTask();
        await Task.Delay(50);
        Assert.False(pending.IsCompleted);
        c.Grant(3);
        Assert.Equal(3, await pending);
    }
}
