namespace FcAudit.Core;

/// <summary>A registry key (Name and Data null) or one value of a key, as read from a .reg export.</summary>
public sealed record RegEntry(string Key, string? Name, string? Data)
{
    public bool IsKey => Name is null;

    /// <summary>Identity of a key or value, ignoring its data. Registry names are case-insensitive.</summary>
    internal string Id => IsKey ? $"[{Key}]" : $"[{Key}] {Name}";

    public override string ToString() => IsKey ? $"[{Key}]" : $"[{Key}] {Name}={Data}";
}

public sealed record RegChange(string Key, string Name, string OldData, string NewData);

/// <summary>Differences between two exports of the same key. Lists are null when an export could not be compared.</summary>
public sealed record RegistryChanges(
    string Hive,
    InputStatus Before,
    InputStatus After,
    IReadOnlyList<RegEntry>? Added,
    IReadOnlyList<RegEntry>? Removed,
    IReadOnlyList<RegChange>? Changed)
{
    public bool Compared => Added is not null;

    public int Count => (Added?.Count ?? 0) + (Removed?.Count ?? 0) + (Changed?.Count ?? 0);
}

/// <summary>
/// Parses <c>reg export</c> output (REGEDIT5: UTF-16, <c>[key]</c> lines, <c>"name"=data</c> or
/// <c>@=data</c> values) and compares two exports. A value whose data spans several lines (hex data
/// ending in <c>,\</c>) is joined into one entry. A value present in both with different data is a
/// change rather than an add plus a remove.
/// </summary>
public static class RegistrySnapshot
{
    public static IReadOnlyList<RegEntry> Parse(IReadOnlyList<string> lines)
    {
        var entries = new List<RegEntry>();
        string? key = null;
        for (int i = 0; i < lines.Count; i++)
        {
            string line = lines[i].TrimEnd('\r');
            if (line.Length == 0) continue;
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                key = line[1..^1];
                entries.Add(new RegEntry(key, null, null));
                continue;
            }
            if (key is null) continue; // header ("Windows Registry Editor Version 5.00") or junk before the first key

            // Continuation lines only follow hex data, which reg.exe wraps as "hex...:xx,xx,\".
            while (IsHexContinued(line) && i + 1 < lines.Count)
            {
                line = line[..^1] + lines[++i].TrimEnd('\r').TrimStart();
            }
            if (TrySplitValue(line, out string name, out string data)) entries.Add(new RegEntry(key, name, data));
        }
        return entries;
    }

    public static RegistryChanges Compare(string hive, InputText before, InputText after)
    {
        if (!before.IsOk || !after.IsOk) return new RegistryChanges(hive, before.Status, after.Status, null, null, null);
        var (bList, bMap) = Index(Parse(before.Lines));
        var (aList, aMap) = Index(Parse(after.Lines));
        var added = new List<RegEntry>();
        var removed = new List<RegEntry>();
        var changed = new List<RegChange>();
        foreach (var entry in aList)
        {
            if (!bMap.TryGetValue(entry.Id, out var old)) added.Add(entry);
            else if (!entry.IsKey && !string.Equals(old.Data, entry.Data, StringComparison.Ordinal))
                changed.Add(new RegChange(entry.Key, entry.Name!, old.Data!, entry.Data!));
        }
        foreach (var entry in bList)
        {
            if (!aMap.ContainsKey(entry.Id)) removed.Add(entry);
        }
        return new RegistryChanges(hive, InputStatus.Ok, InputStatus.Ok, added, removed, changed);
    }

    private static bool IsHexContinued(string line) =>
        line.EndsWith('\\') && line.Contains("=hex", StringComparison.OrdinalIgnoreCase);

    // Export order is kept for the report; the first occurrence of a duplicate wins.
    private static (List<RegEntry> List, Dictionary<string, RegEntry> Map) Index(IEnumerable<RegEntry> entries)
    {
        var list = new List<RegEntry>();
        var map = new Dictionary<string, RegEntry>(StringComparer.OrdinalIgnoreCase);
        foreach (var e in entries) if (map.TryAdd(e.Id, e)) list.Add(e);
        return (list, map);
    }

    /// <summary>Splits <c>"name"=data</c> (with <c>\"</c> and <c>\\</c> escapes in the name) or <c>@=data</c>.</summary>
    internal static bool TrySplitValue(string line, out string name, out string data)
    {
        name = data = "";
        if (line.StartsWith("@="))
        {
            name = "@";
            data = line[2..];
            return true;
        }
        if (!line.StartsWith('"')) return false;
        var sb = new System.Text.StringBuilder();
        for (int i = 1; i < line.Length; i++)
        {
            char c = line[i];
            if (c == '\\' && i + 1 < line.Length) { sb.Append(line[++i]); continue; }
            if (c == '"')
            {
                if (i + 1 >= line.Length || line[i + 1] != '=') return false;
                name = "\"" + sb + "\"";
                data = line[(i + 2)..];
                return true;
            }
            sb.Append(c);
        }
        return false;
    }
}
