namespace FcMcp;

public sealed class Session(string id, string guest, DateTimeOffset created, int timeoutSec)
{
    private int _exec;
    public string Id { get; } = id;
    public string Guest { get; } = guest;
    public DateTimeOffset Created { get; } = created;
    public int TimeoutSec { get; } = timeoutSec;
    public int NextExec() => Interlocked.Increment(ref _exec);
    public int Execs => Volatile.Read(ref _exec);
    public TimeSpan Remaining(DateTimeOffset now) => Created.AddSeconds(TimeoutSec) - now;
}

/// <summary>
/// Sessions this server started (spec: Session ownership, Session limits and cleanup; design D6).
/// Only ids in this table are accepted by session tools.
/// </summary>
public sealed class SessionTable(int maxSessions)
{
    private readonly Dictionary<string, Session> _sessions = new(StringComparer.Ordinal);
    private int _reserved;
    private readonly object _lock = new();

    public int MaxSessions { get; } = maxSessions;

    /// <summary>Reserves a slot before a VM is started; throws when the limit is reached.</summary>
    public IDisposable Reserve()
    {
        lock (_lock)
        {
            if (_sessions.Count + _reserved >= MaxSessions)
            {
                throw new PolicyException($"the session limit ({MaxSessions}) is reached; stop a session first");
            }
            _reserved++;
        }
        return new Reservation(this);
    }

    public void Add(Session s)
    {
        lock (_lock) _sessions.Add(s.Id, s);
    }

    public Session Get(string id)
    {
        lock (_lock)
        {
            if (id is not null && _sessions.TryGetValue(id, out var s)) return s;
        }
        throw new PolicyException($"session '{id}' does not exist");
    }

    public bool Remove(string id)
    {
        lock (_lock) return _sessions.Remove(id);
    }

    public IReadOnlyList<Session> All()
    {
        lock (_lock) return _sessions.Values.ToList();
    }

    /// <summary>Stops every session in parallel, giving up after <paramref name="deadline"/>.</summary>
    public async Task StopAllAsync(Func<Session, Task> stop, TimeSpan deadline)
    {
        var all = All();
        var tasks = all.Select(async s =>
        {
            try { await stop(s); } catch { /* best effort: the VM watchdog still bounds it */ }
            Remove(s.Id);
        }).ToArray();
        await Task.WhenAny(Task.WhenAll(tasks), Task.Delay(deadline));
    }

    private sealed class Reservation(SessionTable t) : IDisposable
    {
        private int _done;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) == 0)
            {
                lock (t._lock) t._reserved--;
            }
        }
    }
}
