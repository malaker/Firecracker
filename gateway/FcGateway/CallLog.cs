using System.Text;
using System.Text.Json;

namespace FcGateway;

/// <summary>Counters for one run, shared by all requests. Thread-safe.</summary>
public sealed class RunState(Limits limits)
{
    private readonly object _lock = new();
    public Limits Limits { get; } = limits;
    public int Requests { get; private set; }
    public int Refused { get; private set; }
    public long Tokens { get; private set; }
    public long BytesUp { get; private set; }
    public long BytesDown { get; private set; }

    /// <summary>Reserves one request; returns a refusal reason when a run budget is spent.</summary>
    public string? TryStartRequest()
    {
        lock (_lock)
        {
            if (Requests >= Limits.MaxRequests) return $"request budget of {Limits.MaxRequests} is spent";
            if (Tokens >= Limits.TokenBudget) return $"token budget of {Limits.TokenBudget} is spent";
            Requests++;
            return null;
        }
    }

    public void CountRefused() { lock (_lock) Refused++; }
    public void AddTokens(long n) { lock (_lock) Tokens += n; }
    public void AddUp(long n) { lock (_lock) BytesUp += n; }

    /// <summary>Adds response bytes; false once the run's response budget is exceeded.</summary>
    public bool TryAddDown(long n)
    {
        lock (_lock)
        {
            BytesDown += n;
            return BytesDown <= Limits.MaxResponseBytes;
        }
    }

    public string TotalsJson()
    {
        lock (_lock)
        {
            return JsonSerializer.Serialize(new Dictionary<string, long>
            {
                ["requests"] = Requests, ["refused"] = Refused, ["tokens"] = Tokens,
                ["bytes_up"] = BytesUp, ["bytes_down"] = BytesDown,
            });
        }
    }
}

public sealed record LogEntry(string Method, string Path, string Model, string Decision, string Reason,
    int Status, long BytesUp, long BytesDown, long TokensIn, long TokensOut);

/// <summary>
/// llm.log: one key=value line per request (spec: Call log). No bodies. Every value is sanitised, and
/// the real key is scrubbed from every line as a last line of defence. Totals are rewritten after each call.
/// </summary>
public sealed class CallLog : IDisposable
{
    private readonly StreamWriter _w;
    private readonly string? _totalsPath;
    private readonly string _secret;
    private readonly object _lock = new();

    public CallLog(string path, string? totalsPath, string secret)
    {
        _w = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete), new UTF8Encoding(false)) { AutoFlush = true };
        _totalsPath = totalsPath;
        _secret = secret;
    }

    public void Write(LogEntry e, RunState state)
    {
        string line = string.Join(' ',
            $"ts={DateTime.UtcNow:yyyy-MM-ddTHH:mm:ss.fffZ}", $"method={Clean(e.Method)}", $"path={Clean(e.Path)}",
            $"model={Clean(e.Model)}", $"decision={e.Decision}", $"reason={Clean(e.Reason)}", $"status={e.Status}",
            $"bytes_up={e.BytesUp}", $"bytes_down={e.BytesDown}", $"tokens_in={e.TokensIn}", $"tokens_out={e.TokensOut}");
        if (_secret.Length > 0) line = line.Replace(_secret, "[redacted]", StringComparison.Ordinal);
        lock (_lock)
        {
            _w.WriteLine(line);
            if (_totalsPath is not null)
            {
                File.WriteAllText(_totalsPath + ".tmp", state.TotalsJson());
                File.Move(_totalsPath + ".tmp", _totalsPath, overwrite: true);
            }
        }
    }

    public void Event(string text)
    {
        string line = $"ts={DateTime.UtcNow:yyyy-MM-ddTHH:mm:ss.fffZ} event={Clean(text)}";
        if (_secret.Length > 0) line = line.Replace(_secret, "[redacted]", StringComparison.Ordinal);
        lock (_lock) _w.WriteLine(line);
    }

    /// <summary>Printable, space-free, at most 200 characters ("-" when empty).</summary>
    internal static string Clean(string? s)
    {
        if (string.IsNullOrEmpty(s)) return "-";
        var sb = new StringBuilder(Math.Min(s.Length, 200));
        foreach (char c in s)
        {
            if (sb.Length >= 200) break;
            sb.Append(c is <= ' ' or (char)0x7F or '"' ? '_' : c);
        }
        return sb.ToString();
    }

    public void Dispose() => _w.Dispose();
}
