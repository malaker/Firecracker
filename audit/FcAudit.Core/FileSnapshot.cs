namespace FcAudit.Core;

/// <summary>Result of comparing two file listings. Lists are null when a listing could not be compared.</summary>
public sealed record FileChanges(
    InputStatus Before,
    InputStatus After,
    IReadOnlyList<string>? Created,
    IReadOnlyList<string>? Deleted)
{
    public bool Compared => Created is not null && Deleted is not null;
}

/// <summary>
/// Compares two <c>dir /s /b /a C:\</c> listings (one path per line). Windows paths compare
/// case-insensitively; everything under C:\work is the sandbox's own working area and is left out.
/// </summary>
public static class FileSnapshot
{
    public const string ExcludedRoot = @"C:\work";

    public static FileChanges Compare(InputText before, InputText after)
    {
        if (!before.IsOk || !after.IsOk) return new FileChanges(before.Status, after.Status, null, null);
        var b = ToSet(before.Lines);
        var a = ToSet(after.Lines);
        var created = after.Lines.Select(Normalize).Where(p => p.Length > 0 && !IsExcluded(p) && !b.Contains(p))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var deleted = before.Lines.Select(Normalize).Where(p => p.Length > 0 && !IsExcluded(p) && !a.Contains(p))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        return new FileChanges(InputStatus.Ok, InputStatus.Ok, created, deleted);
    }

    internal static bool IsExcluded(string path) =>
        path.Equals(ExcludedRoot, StringComparison.OrdinalIgnoreCase)
        || path.StartsWith(ExcludedRoot + @"\", StringComparison.OrdinalIgnoreCase);

    private static string Normalize(string line) => line.TrimEnd('\r', ' ');

    private static HashSet<string> ToSet(IEnumerable<string> lines)
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var l in lines) set.Add(Normalize(l));
        return set;
    }
}
