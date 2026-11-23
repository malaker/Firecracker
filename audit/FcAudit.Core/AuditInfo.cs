using System.Text.Json;

namespace FcAudit.Core;

/// <summary>
/// Facts about the run that the controller knows from its own side (trusted): what was audited,
/// how, and how the program step ended. Written by the controller as info.json.
/// </summary>
public sealed record AuditInfo(
    string RunId,
    string? PairedRunId,
    string Mode,
    string SamplePath,
    string Entry,
    string Sha256,
    string Arguments,
    int? ProgramExitCode,
    bool ProgramFinished,
    int TimeoutSec,
    bool ProgramStopped = false)
{
    public static AuditInfo Load(string path)
    {
        using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
        var r = doc.RootElement;
        string Str(string name) => r.GetProperty(name).GetString() ?? throw new InvalidDataException($"info.json: '{name}' is null");
        string? OptStr(string name) => r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        int? OptInt(string name) => r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;
        bool OptBool(string name) => r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
        string mode = Str("mode");
        if (mode is not ("isolated" or "networked")) throw new InvalidDataException($"info.json: unknown mode '{mode}'");
        return new AuditInfo(
            Str("run_id"), OptStr("paired_run_id"), mode, Str("sample_path"), Str("entry"), Str("sha256"),
            OptStr("arguments") ?? "", OptInt("program_exit_code"), r.GetProperty("program_finished").GetBoolean(),
            OptInt("timeout_sec") ?? 0, OptBool("program_stopped"));
    }
}
