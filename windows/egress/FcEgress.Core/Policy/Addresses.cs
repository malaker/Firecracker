using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace FcEgress.Policy;

public static class Ipv4
{
    // Exactly four decimal octets 0-255 without leading zeros. Rejects every alternative
    // form resolvers accept (hex, octal, integer, short "127.1"), so a name can never
    // smuggle in an address the policy did not see.
    public static bool TryParseStrict(string s, out uint address)
    {
        address = 0;
        var parts = s.Split('.');
        if (parts.Length != 4) return false;
        foreach (var p in parts)
        {
            if (p.Length is 0 or > 3 || (p.Length > 1 && p[0] == '0')) return false;
            uint v = 0;
            foreach (char c in p)
            {
                if (c is < '0' or > '9') return false;
                v = v * 10 + (uint)(c - '0');
            }
            if (v > 255) return false;
            address = (address << 8) | v;
        }
        return true;
    }

    public static uint FromIPAddress(IPAddress ip)
    {
        var b = ip.GetAddressBytes();
        return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
    }

    public static IPAddress ToIPAddress(uint a) => new([(byte)(a >> 24), (byte)(a >> 16), (byte)(a >> 8), (byte)a]);

    public static string Format(uint a) => $"{a >> 24}.{(a >> 16) & 255}.{(a >> 8) & 255}.{a & 255}";
}

public readonly record struct Cidr(uint Network, int Prefix)
{
    private uint Mask => Prefix == 0 ? 0u : uint.MaxValue << (32 - Prefix);

    public bool Contains(uint address) => (address & Mask) == (Network & Mask);

    public static Cidr Parse(string s)
    {
        if (!TryParse(s, out var c)) throw new FormatException($"invalid CIDR '{s}'");
        return c;
    }

    public static bool TryParse(string s, out Cidr cidr)
    {
        cidr = default;
        var parts = s.Trim().Split('/');
        if (parts.Length > 2 || !Ipv4.TryParseStrict(parts[0], out var net)) return false;
        int prefix = 32;
        if (parts.Length == 2 && (!int.TryParse(parts[1], out prefix) || prefix is < 0 or > 32)) return false;
        cidr = new Cidr(net, prefix);
        return true;
    }

    public override string ToString() => $"{Ipv4.Format(Network)}/{Prefix}";
}

public static class HostName
{
    // RFC 1123 names only. The last label must start with a letter: real TLDs do, and it
    // stops numeric forms such as "2130706433" or "0x7f.1" from reaching the resolver.
    public static bool IsValid(string name)
    {
        if (name.Length is 0 or > 253) return false;
        var labels = name.Split('.');
        foreach (var l in labels)
        {
            if (l.Length is 0 or > 63 || l[0] == '-' || l[^1] == '-') return false;
            foreach (char c in l)
            {
                if (!(char.IsAsciiLetterOrDigit(c) || c == '-')) return false;
            }
        }
        return char.IsAsciiLetter(labels[^1][0]);
    }
}

public static class HostAddresses
{
    // Every IPv4 address bound to a local interface right now, plus the whole loopback
    // and "this network" ranges, which always mean the host itself.
    public static IReadOnlyList<Cidr> Current()
    {
        var list = new List<Cidr> { Cidr.Parse("127.0.0.0/8"), Cidr.Parse("0.0.0.0/8") };
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            foreach (var u in ni.GetIPProperties().UnicastAddresses)
            {
                if (u.Address.AddressFamily == AddressFamily.InterNetwork)
                {
                    list.Add(new Cidr(Ipv4.FromIPAddress(u.Address), 32));
                }
            }
        }
        return list;
    }
}
