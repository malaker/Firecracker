using System.Globalization;

namespace FcAudit.Core;

/// <summary>One distinct host, port and decision from net.log, with its attempts folded together.</summary>
public sealed record NetDestination(
    string Host,
    int Port,
    string Decision,
    int Attempts,
    IReadOnlyList<string> Addresses,
    IReadOnlyList<string> Reasons,
    long BytesUp,
    long BytesDown,
    string FirstSeen);

public sealed record NetSummary(InputStatus Status, IReadOnlyList<NetDestination> Destinations, int SkippedLines);

/// <summary>
/// Reads the egress proxy's net.log: one line per event, a timestamp then space-separated
/// <c>key=value</c> fields. Only connection lines (with <c>decision=</c>) count, and the proxy's
/// own start-up check (<c>reason=sentinel</c>) is left out. The host field is the name the guest
/// asked for, so every field is treated as untrusted text.
/// </summary>
public static class NetLog
{
    public static NetSummary Summarize(InputText log)
    {
        if (!log.IsOk) return new NetSummary(log.Status, Array.Empty<NetDestination>(), 0);
        var groups = new List<Group>();
        var index = new Dictionary<(string, int, string), Group>();
        int skipped = 0;
        foreach (var raw in log.Lines)
        {
            var line = raw.TrimEnd('\r');
            if (line.Length == 0) continue;
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var f = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var p in parts.Skip(1))
            {
                int eq = p.IndexOf('=');
                if (eq > 0) f[p[..eq]] = p[(eq + 1)..];
            }
            if (!f.TryGetValue("decision", out var decision)) continue; // event=start/stop lines
            if (f.GetValueOrDefault("reason") == "sentinel") continue;
            if (!f.TryGetValue("host", out var host) || !int.TryParse(f.GetValueOrDefault("port"), NumberStyles.None, CultureInfo.InvariantCulture, out int port))
            {
                skipped++;
                continue;
            }
            var k = (host.ToLowerInvariant(), port, decision);
            if (!index.TryGetValue(k, out var g))
            {
                g = new Group(host, port, decision, parts[0]);
                index[k] = g;
                groups.Add(g);
            }
            g.Attempts++;
            if (f.TryGetValue("ip", out var ip) && ip != "-" && ip.Length > 0 && !g.Addresses.Contains(ip)) g.Addresses.Add(ip);
            if (f.TryGetValue("reason", out var reason) && reason.Length > 0 && !g.Reasons.Contains(reason)) g.Reasons.Add(reason);
            g.BytesUp += ParseLong(f.GetValueOrDefault("bytes_up"));
            g.BytesDown += ParseLong(f.GetValueOrDefault("bytes_down"));
        }
        var list = groups.Select(g => new NetDestination(g.Host, g.Port, g.Decision, g.Attempts, g.Addresses, g.Reasons, g.BytesUp, g.BytesDown, g.FirstSeen)).ToList();
        return new NetSummary(InputStatus.Ok, list, skipped);
    }

    private static long ParseLong(string? s) =>
        long.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out long v) ? v : 0;

    private sealed class Group(string host, int port, string decision, string firstSeen)
    {
        public string Host { get; } = host;
        public int Port { get; } = port;
        public string Decision { get; } = decision;
        public string FirstSeen { get; } = firstSeen;
        public int Attempts { get; set; }
        public List<string> Addresses { get; } = new();
        public List<string> Reasons { get; } = new();
        public long BytesUp { get; set; }
        public long BytesDown { get; set; }
    }
}
