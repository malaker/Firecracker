namespace FcAudit.Core;

public sealed record OutputFile(string Path, long Bytes);

/// <summary>Everything one audit report says, gathered from a run folder.</summary>
public sealed record AuditReport(
    AuditInfo Info,
    NetSummary? Network,
    FileChanges Files,
    IReadOnlyList<RegistryChanges> Registry,
    IReadOnlyList<OutputFile> Outputs,
    InputStatus OutputsStatus)
{
    /// <summary>Snapshot files the guest writes into C:\work\out\_audit (spec: in-guest snapshots).</summary>
    public const string AuditDirName = "_audit";

    /// <summary>Keys Windows itself rewrites while any program runs; their changes are labelled, not hidden.</summary>
    public static readonly IReadOnlyList<string> BackgroundKeys = new[]
    {
        @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Notifications\Data",
    };

    public static bool IsBackground(string key) =>
        BackgroundKeys.Any(k => key.Equals(k, StringComparison.OrdinalIgnoreCase));

    public static readonly IReadOnlyList<string> Limits = new[]
    {
        "The program ran as an administrator (ContainerAdministrator) inside the guest, so it could have altered the snapshots this report is built from. This is evidence, not a verdict.",
        "Modified files are not detected: only files and folders that were created or deleted.",
        "For encrypted traffic only host names and ports are visible, not URLs or content.",
        "Programs that ignore the HTTP_PROXY/HTTPS_PROXY settings get no network at all and leave no net.log entry.",
        "All quoted text (paths, registry data, host names, program output) comes from the program and is untrusted.",
    };

    /// <summary>Builds the report from <paramref name="runDir"/> (a runs\&lt;run-id&gt; folder).</summary>
    public static AuditReport Build(string runDir, AuditInfo info, long maxInputBytes = InputText.DefaultMaxBytes)
    {
        string audit = Path.Combine(runDir, "out", AuditDirName);
        InputText Txt(string name) => InputText.Read(Path.Combine(audit, name), InputText.Utf8, maxInputBytes);
        InputText Reg(string name) => InputText.Read(Path.Combine(audit, name), InputText.Utf16, maxInputBytes);

        NetSummary? net = info.Mode == "networked"
            ? NetLog.Summarize(InputText.Read(Path.Combine(runDir, "net.log"), InputText.Utf8, maxInputBytes))
            : null;
        var files = FileSnapshot.Compare(Txt("fs-before.txt"), Txt("fs-after.txt"));
        var registry = new[]
        {
            RegistrySnapshot.Compare(@"HKLM\SOFTWARE", Reg("hklm-before.reg"), Reg("hklm-after.reg")),
            RegistrySnapshot.Compare("HKCU", Reg("hkcu-before.reg"), Reg("hkcu-after.reg")),
        };
        var (outputs, outStatus) = ListOutputs(Path.Combine(runDir, "out"));
        return new AuditReport(info, net, files, registry, outputs, outStatus);
    }

    private static (IReadOnlyList<OutputFile>, InputStatus) ListOutputs(string outDir)
    {
        if (!Directory.Exists(outDir)) return (Array.Empty<OutputFile>(), InputStatus.Missing);
        var list = new List<OutputFile>();
        var opts = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint, IgnoreInaccessible = true };
        foreach (var f in new DirectoryInfo(outDir).EnumerateFiles("*", opts))
        {
            string rel = Path.GetRelativePath(outDir, f.FullName);
            if (rel.StartsWith(AuditDirName + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) continue;
            list.Add(new OutputFile(rel, f.Length));
        }
        list.Sort((a, b) => string.Compare(a.Path, b.Path, StringComparison.OrdinalIgnoreCase));
        return (list, InputStatus.Ok);
    }
}
