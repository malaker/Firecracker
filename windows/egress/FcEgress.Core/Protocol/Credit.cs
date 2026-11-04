namespace FcEgress.Protocol;

// Sender side of a per-stream window: DATA may only be sent against credit the peer granted.
internal sealed class SendCredit(int initial)
{
    private readonly Lock _gate = new();
    private long _credit = initial;
    private bool _closed;
    private TaskCompletionSource? _waiter;

    public async ValueTask<int> AcquireAsync(int want, CancellationToken ct)
    {
        while (true)
        {
            TaskCompletionSource tcs;
            lock (_gate)
            {
                if (_closed) throw new OperationCanceledException("stream closed");
                if (_credit > 0)
                {
                    int n = (int)Math.Min(want, _credit);
                    _credit -= n;
                    return n;
                }
                tcs = _waiter ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            }
            await tcs.Task.WaitAsync(ct);
        }
    }

    public void Grant(uint n)
    {
        TaskCompletionSource? w;
        lock (_gate)
        {
            _credit = Math.Min(_credit + n, int.MaxValue);
            w = _waiter;
            _waiter = null;
        }
        w?.TrySetResult();
    }

    public void Close()
    {
        TaskCompletionSource? w;
        lock (_gate)
        {
            _closed = true;
            w = _waiter;
            _waiter = null;
        }
        w?.TrySetResult();
    }
}

// Receiver side: the peer must never have more than one window of unconsumed bytes in flight.
internal sealed class ReceiveWindow(int window)
{
    private readonly Lock _gate = new();
    private long _outstanding;
    private long _unacked;

    public long Outstanding { get { lock (_gate) return _outstanding; } }

    public void OnData(int n)
    {
        lock (_gate)
        {
            _outstanding += n;
            if (_outstanding > window) throw new ProtocolException($"stream window of {window} bytes exceeded");
        }
    }

    // Returns the credit to grant back to the peer, or 0 to wait for more consumption.
    public uint OnConsumed(int n)
    {
        lock (_gate)
        {
            _outstanding -= n;
            _unacked += n;
            if (_unacked < window / 2) return 0;
            uint grant = (uint)_unacked;
            _unacked = 0;
            return grant;
        }
    }
}
