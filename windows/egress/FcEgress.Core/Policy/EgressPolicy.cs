using System.Net;
using System.Net.Sockets;

namespace FcEgress.Policy;

public readonly record struct Decision(bool Allowed, uint? Address, string Reason)
{
    public string AddressText => Address is { } a ? Ipv4.Format(a) : "-";
}

// Decides, on the host, whether a guest-requested destination may be connected to.
// The decision picks one concrete IPv4 address; the caller connects to exactly that address.
public sealed class EgressPolicy
{
    public static readonly IReadOnlyList<Cidr> AlwaysBlocked = new[]
    {
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
        "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
    }.Select(Cidr.Parse).ToArray();

    public delegate Task<IPAddress[]> Resolver(string host, CancellationToken ct);

    private readonly IReadOnlyList<Cidr> _allow;
    private readonly Func<IReadOnlyList<Cidr>> _hostAddresses;
    private readonly Resolver _resolve;

    public EgressPolicy(IReadOnlyList<Cidr> allow, Func<IReadOnlyList<Cidr>>? hostAddresses = null, Resolver? resolve = null)
    {
        _allow = allow;
        _hostAddresses = hostAddresses ?? HostAddresses.Current;
        _resolve = resolve ?? ((h, ct) => Dns.GetHostAddressesAsync(h, ct));
    }

    public TimeSpan ResolveTimeout { get; init; } = TimeSpan.FromSeconds(5);

    public bool IsPermitted(uint address, out string reason) => IsPermitted(address, _hostAddresses(), out reason);

    private bool IsPermitted(uint address, IReadOnlyList<Cidr> host, out string reason)
    {
        if (host.Any(c => c.Contains(address)))
        {
            reason = "host-address";
            return false;
        }
        if (_allow.Count > 0)
        {
            bool listed = _allow.Any(c => c.Contains(address));
            reason = listed ? "allowlisted" : "not-allowlisted";
            return listed;
        }
        var blocked = AlwaysBlocked.FirstOrDefault(c => c.Contains(address));
        if (blocked != default)
        {
            reason = $"blocked-range:{blocked}";
            return false;
        }
        reason = "public";
        return true;
    }

    public async Task<Decision> DecideAsync(string host, ushort port, CancellationToken ct = default)
    {
        if (port == 0) return new Decision(false, null, "invalid-port");
        if (host.Contains(':') || host.StartsWith('[')) return new Decision(false, null, "ipv6-denied");

        IReadOnlyList<uint> candidates;
        if (Ipv4.TryParseStrict(host, out var literal))
        {
            candidates = new[] { literal };
        }
        else if (!HostName.IsValid(host))
        {
            return new Decision(false, null, "invalid-host");
        }
        else if (host.EndsWith(".invalid", StringComparison.OrdinalIgnoreCase))
        {
            // RFC 2606 name used by the readiness probe: answered without any lookup.
            return new Decision(false, null, "sentinel");
        }
        else
        {
            IPAddress[] resolved;
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeout.CancelAfter(ResolveTimeout);
                resolved = await _resolve(host, timeout.Token);
            }
            catch (Exception ex) when (ex is SocketException or OperationCanceledException or ArgumentException)
            {
                return new Decision(false, null, "resolve-failed");
            }
            candidates = resolved
                .Select(a => a.IsIPv4MappedToIPv6 ? a.MapToIPv4() : a)
                .Where(a => a.AddressFamily == AddressFamily.InterNetwork)
                .Select(Ipv4.FromIPAddress)
                .Distinct()
                .ToArray();
            if (candidates.Count == 0) return new Decision(false, null, "no-ipv4-address");
        }

        // Read the host's addresses once per decision (not per candidate), but on every
        // decision: DHCP or VPN changes must not open a hole.
        var hostAddresses = _hostAddresses();
        string? firstReason = null;
        uint? firstAddress = null;
        foreach (var a in candidates)
        {
            if (IsPermitted(a, hostAddresses, out var reason)) return new Decision(true, a, reason);
            firstReason ??= reason;
            firstAddress ??= a;
        }
        return new Decision(false, firstAddress, firstReason!);
    }
}
