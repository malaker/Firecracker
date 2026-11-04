using System.Collections.Concurrent;
using System.Threading.Channels;

namespace FcEgress.Protocol;

public sealed class MuxStream
{
    internal MuxStream(uint id)
    {
        Id = id;
    }

    public uint Id { get; }
    public string Host { get; internal set; } = "";
    public ushort Port { get; internal set; }
    public long BytesFromPeer => Interlocked.Read(ref _bytesFromPeer);
    public long BytesToPeer => Interlocked.Read(ref _bytesToPeer);
    // Set when the multiplexer itself ended the stream (idle timeout, stream limit, channel closed).
    public string? CloseReason { get; internal set; }
    public object? Tag { get; set; }
    public CancellationToken Cancellation => Cts.Token;

    internal readonly SendCredit Credit = new(Limits.StreamWindow);
    internal readonly ReceiveWindow Receive = new(Limits.StreamWindow);
    internal readonly Channel<byte[]> Inbound = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
    internal readonly CancellationTokenSource Cts = new();
    internal readonly TaskCompletionSource<OpenFailReason?> OpenResult = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal long _bytesFromPeer;
    internal long _bytesToPeer;
    internal long LastActivityTicks = Environment.TickCount64;
    internal int Finished;
    // Host side: set once OPEN_OK or OPEN_FAIL has been sent for this stream.
    internal int Answered;

    internal void Touch() => Interlocked.Exchange(ref LastActivityTicks, Environment.TickCount64);
}

// Multiplexes TCP streams over one frame channel. The guest side opens streams (OpenAsync);
// the host side accepts them through the onOpen callback.
public sealed class Mux
{
    private readonly FrameReader _reader;
    private readonly FrameWriter _writer;
    private readonly ConcurrentDictionary<uint, MuxStream> _streams = new();
    private readonly StreamRegistry _registry = new();
    private readonly ConcurrentDictionary<uint, Task> _handlers = new();
    private readonly Func<Mux, MuxStream, Task>? _onOpen;
    private int _nextId;

    public Mux(Stream input, Stream output, Func<Mux, MuxStream, Task>? onOpen = null)
    {
        _reader = new FrameReader(input);
        _writer = new FrameWriter(output);
        _onOpen = onOpen;
    }

    public TimeSpan IdleTimeout { get; init; } = TimeSpan.FromSeconds(300);
    public int MaxStreams { get; init; } = Limits.MaxStreams;
    public Action<MuxStream>? StreamClosed { get; init; }
    public Action<string>? ProtocolError { get; init; }
    public int OpenStreams => _streams.Count;
    // Tests only: start id allocation near the wrap-around point.
    internal int NextId { set => _nextId = value; }
    private bool IsHost => _onOpen is not null;

    // Runs until the channel reaches EOF or the peer violates the protocol; then closes every stream.
    public async Task RunAsync(CancellationToken ct = default)
    {
        using var sweepCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var sweeper = SweepIdleAsync(sweepCts.Token);
        try
        {
            while (await _reader.ReadAsync(ct) is { } frame)
            {
                await DispatchAsync(frame, ct);
            }
        }
        catch (ProtocolException ex)
        {
            ProtocolError?.Invoke(ex.Message);
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException)
        {
        }
        finally
        {
            sweepCts.Cancel();
            foreach (var s in _streams.Values)
            {
                s.CloseReason ??= "channel-closed";
                Abort(s);
            }
            await sweeper;
            // Let aborted handlers finish (and log) before the caller exits.
            try
            {
                await Task.WhenAll(_handlers.Values).WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch (TimeoutException)
            {
            }
        }
    }

    private async ValueTask DispatchAsync(Frame f, CancellationToken ct)
    {
        switch (f.Type)
        {
            case FrameType.Open:
                if (!IsHost) throw new ProtocolException("unexpected OPEN from host");
                OpenPayload.TryDecode(f.Payload, out var host, out var port);
                if (_registry.Count >= MaxStreams)
                {
                    await _writer.WriteAsync(FrameType.OpenFail, f.Stream, new[] { (byte)OpenFailReason.LimitReached }, ct);
                    StreamClosed?.Invoke(new MuxStream(f.Stream) { Host = host, Port = port, CloseReason = "stream-limit" });
                    return;
                }
                _registry.Register(f.Stream);
                var s = new MuxStream(f.Stream) { Host = host, Port = port };
                _streams[f.Stream] = s;
                _handlers[s.Id] = Task.Run(() => RunOpenHandlerAsync(s), CancellationToken.None);
                break;
            case FrameType.OpenOk or FrameType.OpenFail:
                if (IsHost) throw new ProtocolException($"unexpected {f.Type} from guest");
                if (_streams.TryGetValue(f.Stream, out var pending))
                {
                    pending.OpenResult.TrySetResult(f.Type == FrameType.OpenOk ? null : (OpenFailReason)f.Payload[0]);
                }
                break;
            case FrameType.Data:
                if (_streams.TryGetValue(f.Stream, out var ds) && Volatile.Read(ref ds.Finished) == 0)
                {
                    ds.Receive.OnData(f.Payload.Length);
                    Interlocked.Add(ref ds._bytesFromPeer, f.Payload.Length);
                    ds.Touch();
                    ds.Inbound.Writer.TryWrite(f.Payload);
                }
                break;
            case FrameType.Window:
                if (_streams.TryGetValue(f.Stream, out var ws))
                {
                    ws.Credit.Grant(BitConverter.ToUInt32(f.Payload));
                }
                break;
            case FrameType.Close:
                if (_streams.TryGetValue(f.Stream, out var cs))
                {
                    if (!IsHost)
                    {
                        // The host ended the stream before answering the OPEN: fail it now
                        // instead of letting the client wait for the open timeout.
                        cs.OpenResult.TrySetResult(OpenFailReason.ConnectFailed);
                    }
                    else if (Volatile.Read(ref cs.Answered) == 0)
                    {
                        // The guest gave up while the policy decision or connect was running.
                        cs.CloseReason ??= "guest-cancelled";
                        Abort(cs);
                    }
                    cs.Inbound.Writer.TryComplete();
                }
                break;
        }
    }

    // Guest side: asks the host to open a stream. Returns null and the reason on refusal.
    public async Task<(MuxStream? Stream, OpenFailReason? Failure)> OpenAsync(string host, ushort port, TimeSpan timeout, CancellationToken ct = default)
    {
        if (_streams.Count >= MaxStreams) return (null, OpenFailReason.LimitReached);
        // Ids wrap around within 1..MaxStreamId, skipping ids still open, so a long-lived VM
        // never runs out of them. At most MaxStreams ids are in use, so the loop is short.
        uint id;
        do
        {
            id = (uint)Interlocked.Increment(ref _nextId) % Limits.MaxStreamId + 1;
        }
        while (_streams.ContainsKey(id));
        var s = new MuxStream(id) { Host = host, Port = port };
        _streams[id] = s;
        _registry.Register(id);
        try
        {
            await _writer.WriteAsync(FrameType.Open, id, OpenPayload.Encode(host, port), ct);
            var failure = await s.OpenResult.Task.WaitAsync(timeout, ct);
            if (failure is null) return (s, null);
            Finish(s, sendClose: false);
            return (null, failure);
        }
        catch
        {
            // Timed out or cancelled: tell the host, so it drops the connection and frees the slot.
            Finish(s, sendClose: true);
            throw;
        }
    }

    // Host side: answer a pending OPEN.
    public ValueTask AcceptAsync(MuxStream s, CancellationToken ct = default)
    {
        Interlocked.Exchange(ref s.Answered, 1);
        return _writer.WriteAsync(FrameType.OpenOk, s.Id, ReadOnlyMemory<byte>.Empty, ct);
    }

    public async ValueTask RejectAsync(MuxStream s, OpenFailReason reason, CancellationToken ct = default)
    {
        try
        {
            Interlocked.Exchange(ref s.Answered, 1);
            await _writer.WriteAsync(FrameType.OpenFail, s.Id, new[] { (byte)reason }, ct);
        }
        finally
        {
            Finish(s, sendClose: false);
        }
    }

    // Pumps bytes between an open stream and a local socket stream until either side ends.
    public async Task BridgeAsync(MuxStream s, Stream local, ReadOnlyMemory<byte> initialToPeer = default)
    {
        var ct = s.Cts.Token;
        var up = PumpToPeerAsync(s, local, initialToPeer, ct);
        var down = PumpFromPeerAsync(s, local, ct);
        await Task.WhenAny(up, down);
        // One direction ended (EOF, remote CLOSE, error or abort): the stream is done either
        // way, since half-close is not supported. A remote CLOSE is only seen after its data
        // was written locally, so nothing the peer sent is lost.
        Abort(s);
        await local.DisposeAsync();
        await Task.WhenAll(up, down);
        Finish(s, sendClose: true);
    }

    private async Task PumpToPeerAsync(MuxStream s, Stream local, ReadOnlyMemory<byte> initial, CancellationToken ct)
    {
        try
        {
            if (!initial.IsEmpty) await SendDataAsync(s, initial, ct);
            var buf = new byte[16 * 1024];
            int n;
            while ((n = await local.ReadAsync(buf, ct)) > 0)
            {
                await SendDataAsync(s, buf.AsMemory(0, n), ct);
            }
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException)
        {
        }
    }

    private async Task SendDataAsync(MuxStream s, ReadOnlyMemory<byte> data, CancellationToken ct)
    {
        while (!data.IsEmpty)
        {
            int n = await s.Credit.AcquireAsync(data.Length, ct);
            await _writer.WriteAsync(FrameType.Data, s.Id, data[..n], ct);
            Interlocked.Add(ref s._bytesToPeer, n);
            s.Touch();
            data = data[n..];
        }
    }

    private async Task PumpFromPeerAsync(MuxStream s, Stream local, CancellationToken ct)
    {
        try
        {
            await foreach (var chunk in s.Inbound.Reader.ReadAllAsync(ct))
            {
                await local.WriteAsync(chunk, ct);
                await local.FlushAsync(ct);
                uint grant = s.Receive.OnConsumed(chunk.Length);
                if (grant > 0) await _writer.WriteWindowAsync(s.Id, grant, ct);
            }
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException)
        {
        }
    }

    // The handler owns the stream; whatever happens, the stream is finished when it returns.
    private async Task RunOpenHandlerAsync(MuxStream s)
    {
        try
        {
            await _onOpen!(this, s);
        }
        catch (Exception)
        {
            s.CloseReason ??= "handler-error";
        }
        finally
        {
            if (Interlocked.Exchange(ref s.Answered, 1) == 0)
            {
                // The handler failed before answering: refuse the OPEN explicitly, so the
                // guest's client gets an immediate error instead of waiting for a timeout.
                try
                {
                    await _writer.WriteAsync(FrameType.OpenFail, s.Id, new[] { (byte)OpenFailReason.ConnectFailed });
                }
                catch (Exception ex) when (ex is IOException or ObjectDisposedException or OperationCanceledException)
                {
                }
                Finish(s, sendClose: false);
            }
            else
            {
                Finish(s, sendClose: true);
            }
            _handlers.TryRemove(s.Id, out _);
        }
    }

    // Wakes every pump and pending open; the stream's owner then finishes it.
    private static void Abort(MuxStream s)
    {
        s.OpenResult.TrySetCanceled();
        s.Inbound.Writer.TryComplete();
        s.Credit.Close();
        s.Cts.Cancel();
    }

    private void Finish(MuxStream s, bool sendClose)
    {
        if (Interlocked.Exchange(ref s.Finished, 1) != 0) return;
        _streams.TryRemove(s.Id, out _);
        _registry.Release(s.Id);
        if (sendClose)
        {
            _ = SafeWriteCloseAsync(s.Id);
        }
        StreamClosed?.Invoke(s);
    }

    private async Task SafeWriteCloseAsync(uint id)
    {
        try
        {
            await _writer.WriteAsync(FrameType.Close, id, ReadOnlyMemory<byte>.Empty);
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or OperationCanceledException)
        {
        }
    }

    private async Task SweepIdleAsync(CancellationToken ct)
    {
        try
        {
            var period = IdleTimeout < TimeSpan.FromSeconds(20) ? IdleTimeout / 2 : TimeSpan.FromSeconds(10);
            using var timer = new PeriodicTimer(period);
            while (await timer.WaitForNextTickAsync(ct))
            {
                long now = Environment.TickCount64;
                foreach (var s in _streams.Values)
                {
                    if (now - Interlocked.Read(ref s.LastActivityTicks) > IdleTimeout.TotalMilliseconds)
                    {
                        s.CloseReason ??= "idle-timeout";
                        Abort(s);
                    }
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }
}
