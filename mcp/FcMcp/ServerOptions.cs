using System.Security.Principal;

namespace FcMcp;

/// <summary>Launch options passed by 'fc.ps1 mcp' (design D4).</summary>
public sealed class ServerOptions
{
    public required string RepoRoot { get; init; }
    public required IReadOnlyList<string> AllowRoots { get; init; }
    public bool AllowNetworked { get; init; }
    public int MaxSessions { get; init; } = 4;
    public bool Elevated { get; init; }

    public string FcPs1 => Path.Combine(RepoRoot, "fc.ps1");
    public string RunsDir => Path.Combine(RepoRoot, "runs");

    public static ServerOptions Parse(string[] args, string currentDirectory, bool elevated)
    {
        string? repo = null;
        var roots = new List<string>();
        bool networked = false;
        int max = 4;
        for (int i = 0; i < args.Length; i++)
        {
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{args[i]} needs a value");
            switch (args[i])
            {
                case "--repo-root": repo = Next(); break;
                case "--allow-root": roots.Add(Next()); break;
                case "--allow-networked": networked = true; break;
                case "--max-sessions":
                    if (!int.TryParse(Next(), out max) || max < 1 || max > 64) throw new ArgumentException("--max-sessions must be between 1 and 64");
                    break;
                default: throw new ArgumentException($"unknown option '{args[i]}'");
            }
        }
        if (repo is null) throw new ArgumentException("--repo-root is required");
        if (roots.Count == 0) roots.Add(currentDirectory);
        return new ServerOptions
        {
            RepoRoot = Path.GetFullPath(repo),
            AllowRoots = roots,
            AllowNetworked = networked,
            MaxSessions = max,
            Elevated = elevated,
        };
    }

    public static bool IsElevated()
    {
        using var id = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }
}

/// <summary>Request gating (spec: Networked mode opt-in, Guest availability by elevation; design D9).</summary>
public static class Gate
{
    public static string Guest(string? guest, ServerOptions o)
    {
        string g = string.IsNullOrEmpty(guest) ? "linux" : guest;
        if (g is not ("linux" or "windows")) throw new PolicyException("guest must be 'linux' or 'windows'");
        if (g == "windows" && !o.Elevated) throw new PolicyException("Windows guests need the MCP server to run elevated (start the MCP client from an elevated prompt)");
        return g;
    }

    public static string Net(string? net, ServerOptions o)
    {
        string n = string.IsNullOrEmpty(net) ? "isolated" : net;
        if (n is not ("isolated" or "networked")) throw new PolicyException("net must be 'isolated' or 'networked'");
        if (n == "networked" && !o.AllowNetworked) throw new PolicyException("networked mode is disabled for this server (launch it with -AllowNetworked to enable it)");
        return n;
    }
}
