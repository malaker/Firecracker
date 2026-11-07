namespace FcAirlock.Core;

public enum EntryKind { File, Directory }

/// <summary>A transfer was refused because an entry broke a rule. The message names the entry.</summary>
public sealed class RuleViolationException(string message) : Exception(message);

/// <summary>
/// The rules every transfer must satisfy (spec: guest-output-airlock). The validator applies them
/// inside the airlock and the unpacker applies them again on the host; both use this class.
/// Paths are relative, '/'-separated, and must be safe to create on NTFS.
/// </summary>
public static class Rules
{
    private static readonly HashSet<string> ReservedNames = BuildReservedNames();

    private static HashSet<string> BuildReservedNames()
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" };
        foreach (string p in new[] { "COM", "LPT" })
        {
            for (int i = 1; i <= 9; i++) names.Add(p + i);
            // Windows also reserves the superscript digits 1-3.
            names.Add(p + "¹");
            names.Add(p + "²");
            names.Add(p + "³");
        }
        return names;
    }

    /// <summary>Throws <see cref="RuleViolationException"/> unless <paramref name="path"/> is host-safe.</summary>
    public static void CheckPath(string path, Limits limits)
    {
        if (path.Length == 0) throw Refuse(path, "empty path");
        if (path[0] == '/') throw Refuse(path, "absolute path");
        if (path.Length > limits.MaxPathChars) throw Refuse(path, $"path longer than {limits.MaxPathChars} characters");

        string[] components = path.Split('/');
        if (components.Length > limits.MaxDepth) throw Refuse(path, $"path deeper than {limits.MaxDepth} levels");
        foreach (string c in components) CheckComponent(path, c, limits);
    }

    private static void CheckComponent(string path, string c, Limits limits)
    {
        if (c.Length == 0) throw Refuse(path, "empty path component");
        if (c is "." or "..") throw Refuse(path, $"'{c}' path component");
        if (c.Length > limits.MaxComponentChars) throw Refuse(path, $"name longer than {limits.MaxComponentChars} characters");
        foreach (char ch in c)
        {
            if (ch < 0x20 || ch == 0x7F) throw Refuse(path, "control character in name");
            if (ch is '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|') throw Refuse(path, $"character '{ch}' is not allowed in names");
        }
        char last = c[^1];
        if (last is '.' or ' ') throw Refuse(path, "name ends with a dot or space");

        // "con.txt", "CON .log" and "nul" all open the device on Windows.
        int dot = c.IndexOf('.');
        string stem = (dot < 0 ? c : c[..dot]).TrimEnd(' ');
        if (ReservedNames.Contains(stem)) throw Refuse(path, $"reserved device name '{stem}'");
    }

    internal static RuleViolationException Refuse(string path, string reason) =>
        new($"{reason}: '{Printable(path)}'");

    /// <summary>Renders a guest-supplied path safely for an error message.</summary>
    public static string Printable(string s)
    {
        var sb = new System.Text.StringBuilder(Math.Min(s.Length, 200));
        foreach (char ch in s)
        {
            if (sb.Length >= 200) { sb.Append("..."); break; }
            sb.Append(ch < 0x20 || ch == 0x7F ? $"\\x{(int)ch:x2}" : ch.ToString());
        }
        return sb.ToString();
    }
}

/// <summary>
/// Applies the per-transfer rules across all entries: entry and byte limits, case-insensitive
/// collisions, and file/directory conflicts. One instance per transfer.
/// </summary>
public sealed class TransferChecker(Limits limits)
{
    // Keyed case-insensitively; the value is the first spelling seen, for error messages.
    private readonly Dictionary<string, string> _files = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _dirs = new(StringComparer.OrdinalIgnoreCase);

    public Limits Limits { get; } = limits;
    public int Entries { get; private set; }
    public int Files => _files.Count;
    public long TotalBytes { get; private set; }

    public void Add(string path, EntryKind kind, long size)
    {
        Rules.CheckPath(path, Limits);
        if (++Entries > Limits.MaxEntries) throw Rules.Refuse(path, $"more than {Limits.MaxEntries} entries");

        if (kind == EntryKind.File)
        {
            if (size < 0) throw Rules.Refuse(path, "negative file size");
            if (size > Limits.MaxFileBytes) throw Rules.Refuse(path, $"file larger than {Limits.MaxFileBytes} bytes");
            if (size > Limits.MaxTotalBytes - TotalBytes) throw Rules.Refuse(path, $"transfer larger than {Limits.MaxTotalBytes} bytes");
            TotalBytes += size;
        }

        AddParents(path);
        if (kind == EntryKind.Directory)
        {
            if (_files.TryGetValue(path, out string? f)) throw Collision(path, f);
            _dirs.TryAdd(path, path);
        }
        else
        {
            if (_files.TryGetValue(path, out string? f)) throw Collision(path, f);
            if (_dirs.TryGetValue(path, out string? d)) throw Collision(path, d);
            _files.Add(path, path);
        }
    }

    private void AddParents(string path)
    {
        int i = -1;
        while ((i = path.IndexOf('/', i + 1)) > 0)
        {
            string parent = path[..i];
            if (_files.TryGetValue(parent, out string? f)) throw Collision(path, f);
            _dirs.TryAdd(parent, parent);
        }
    }

    private static RuleViolationException Collision(string path, string other) =>
        new($"names collide on a case-insensitive file system: '{Rules.Printable(other)}' and '{Rules.Printable(path)}'");
}
