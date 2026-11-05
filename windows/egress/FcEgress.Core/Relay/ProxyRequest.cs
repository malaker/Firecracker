using System.Text;

namespace FcEgress.Relay;

// A parsed HTTP proxy request (guest side only; the host never sees HTTP).
public sealed record ProxyRequest(bool IsConnect, string Host, ushort Port, byte[] Forward)
{
    public const int MaxHeadBytes = 16 * 1024;

    // Parses the request head (everything up to and including the blank line).
    // CONNECT keeps nothing to forward; an absolute-URI request is rewritten to origin form
    // with Proxy-* and hop-by-hop headers removed and "Connection: close" forced, so a kept-alive
    // client connection can never be reused for a different destination.
    public static ProxyRequest? TryParse(string head, out string error)
    {
        error = "";
        var lines = head.Split("\r\n");
        var requestLine = lines[0].Split(' ');
        if (requestLine.Length != 3 || !requestLine[2].StartsWith("HTTP/1.", StringComparison.Ordinal))
        {
            error = "malformed request line";
            return null;
        }
        string method = requestLine[0], target = requestLine[1], version = requestLine[2];

        if (method == "CONNECT")
        {
            if (!TrySplitAuthority(target, defaultPort: null, out var host, out var port))
            {
                error = "CONNECT target must be host:port";
                return null;
            }
            return new ProxyRequest(true, host, port, []);
        }

        if (!target.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
        {
            error = target.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
                ? "use CONNECT for https URLs"
                : "proxy requests need an absolute http:// URL";
            return null;
        }
        string rest = target["http://".Length..];
        int slash = rest.IndexOf('/');
        string authority = slash < 0 ? rest : rest[..slash];
        string path = slash < 0 ? "/" : rest[slash..];
        if (authority.Contains('@') || !TrySplitAuthority(authority, defaultPort: 80, out var h, out var p))
        {
            error = "invalid host in URL";
            return null;
        }

        var sb = new StringBuilder();
        sb.Append(method).Append(' ').Append(path).Append(' ').Append(version).Append("\r\n");
        bool hasHost = false;
        foreach (var line in lines.Skip(1))
        {
            if (line.Length == 0) continue;
            int colon = line.IndexOf(':');
            string name = colon > 0 ? line[..colon].Trim() : "";
            if (name.StartsWith("Proxy-", StringComparison.OrdinalIgnoreCase)
                || name.Equals("Connection", StringComparison.OrdinalIgnoreCase)
                || name.Equals("Keep-Alive", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            hasHost |= name.Equals("Host", StringComparison.OrdinalIgnoreCase);
            sb.Append(line).Append("\r\n");
        }
        if (!hasHost) sb.Append("Host: ").Append(authority).Append("\r\n");
        sb.Append("Connection: close\r\n\r\n");
        return new ProxyRequest(false, h, p, Encoding.ASCII.GetBytes(sb.ToString()));
    }

    // "host:port", "[v6]:port" or (with a default) "host". The host is passed on as-is:
    // whether it is acceptable is decided by the host policy.
    private static bool TrySplitAuthority(string authority, ushort? defaultPort, out string host, out ushort port)
    {
        host = "";
        port = 0;
        string portText;
        if (authority.StartsWith('['))
        {
            int close = authority.IndexOf(']');
            if (close < 0) return false;
            host = authority[..(close + 1)];
            portText = authority[(close + 1)..];
        }
        else
        {
            int colon = authority.LastIndexOf(':');
            host = colon < 0 ? authority : authority[..colon];
            portText = colon < 0 ? "" : authority[colon..];
        }
        if (portText.Length == 0)
        {
            if (defaultPort is null) return false;
            port = defaultPort.Value;
        }
        else if (!portText.StartsWith(':') || !ushort.TryParse(portText[1..], out port) || port == 0)
        {
            return false;
        }
        return host.Length is > 0 and <= 253;
    }
}
