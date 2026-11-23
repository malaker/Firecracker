using System.Globalization;
using System.Text;
using System.Text.Json;

namespace FcAudit.Core;

/// <summary>Writes audit-report.md, audit-report.json and the full lists (spec: audit report).</summary>
public static class ReportWriter
{
    public const string MarkdownName = "audit-report.md";
    public const string JsonName = "audit-report.json";
    /// <summary>Full lists go into this sub-folder of the run folder.</summary>
    public const string ListsDir = "audit";
    public const int MarkdownListLimit = 200;

    public static void WriteAll(AuditReport r, string outDir)
    {
        Directory.CreateDirectory(Path.Combine(outDir, ListsDir));
        var utf8 = new UTF8Encoding(false);
        File.WriteAllText(Path.Combine(outDir, MarkdownName), Markdown(r), utf8);
        File.WriteAllBytes(Path.Combine(outDir, JsonName), Json(r));
        WriteList(outDir, "files-created.txt", r.Files.Created);
        WriteList(outDir, "files-deleted.txt", r.Files.Deleted);
        var reg = r.Registry.Where(x => x.Compared).SelectMany(RegistryLines).ToList();
        File.WriteAllLines(Path.Combine(outDir, ListsDir, "registry-changes.txt"), reg, utf8);
    }

    private static void WriteList(string outDir, string name, IReadOnlyList<string>? lines)
    {
        if (lines is null) return;
        File.WriteAllLines(Path.Combine(outDir, ListsDir, name), lines.Select(Md.Visible), new UTF8Encoding(false));
    }

    private static IEnumerable<string> RegistryLines(RegistryChanges c)
    {
        foreach (var e in c.Added!) yield return "+ " + e;
        foreach (var e in c.Removed!) yield return "- " + e;
        foreach (var e in c.Changed!) yield return $"~ [{e.Key}] {e.Name}: {e.OldData} -> {e.NewData}";
    }

    private static string StatusText(InputStatus s) => s switch
    {
        InputStatus.Ok => "ok",
        InputStatus.Missing => "missing",
        _ => "too large to compare",
    };

    private static string StatusJson(InputStatus s) => s switch
    {
        InputStatus.Ok => "ok",
        InputStatus.Missing => "missing",
        _ => "too_large",
    };

    // ---------------- Markdown ----------------

    public static string Markdown(AuditReport r)
    {
        var i = r.Info;
        var md = new List<string>
        {
            $"# Sandbox audit: {Md.Code(i.Entry)} ({i.Mode})",
            "",
            $"- Sample: {Md.Code(i.SamplePath)}",
            $"- Program: {Md.Code(i.Entry)}, SHA-256 {Md.Code(i.Sha256)}",
            $"- Arguments: {Md.Code(i.Arguments)}",
            $"- Run: {Md.Code(i.RunId)}" + (i.PairedRunId is null ? "" : $" (other run of this audit: {Md.Code(i.PairedRunId)})"),
            "- Program result: " + (i.ProgramFinished
                ? $"exited with code {i.ProgramExitCode?.ToString(CultureInfo.InvariantCulture) ?? "unknown"}"
                : $"**did not finish** within the {i.TimeoutSec}s limit; " + (i.ProgramStopped
                    ? "it was stopped there, then the after snapshots were taken"
                    : "it could not be stopped, so the after snapshots were taken while it may still have been running")),
            "",
        };

        md.Add("## Network");
        md.Add("");
        if (r.Network is null)
        {
            md.Add("Isolated run: the VM had no network device, so nothing could be reached and nothing is logged.");
            md.Add("Connection attempts the program made show up only as errors in `stdout.log` / `stderr.log`.");
        }
        else if (r.Network.Status != InputStatus.Ok)
        {
            md.Add($"`net.log` is {StatusText(r.Network.Status)}; the connections are unknown.");
        }
        else if (r.Network.Destinations.Count == 0)
        {
            md.Add("No connection attempts.");
        }
        else
        {
            md.Add("| host | port | decision | attempts | addresses | reason | bytes up | bytes down | first attempt |");
            md.Add("|---|---|---|---|---|---|---|---|---|");
            foreach (var d in r.Network.Destinations.Take(MarkdownListLimit))
            {
                md.Add(string.Join(" | ", new[]
                {
                    "| " + Md.Cell(d.Host), d.Port.ToString(CultureInfo.InvariantCulture), Md.Cell(d.Decision),
                    d.Attempts.ToString(CultureInfo.InvariantCulture),
                    d.Addresses.Count == 0 ? "" : Md.Cell(string.Join(", ", d.Addresses)),
                    d.Reasons.Count == 0 ? "" : Md.Cell(string.Join(", ", d.Reasons)),
                    d.BytesUp.ToString(CultureInfo.InvariantCulture), d.BytesDown.ToString(CultureInfo.InvariantCulture),
                    Md.Cell(d.FirstSeen) + " |",
                }));
            }
            if (r.Network.Destinations.Count > MarkdownListLimit)
                md.Add($"\n{r.Network.Destinations.Count - MarkdownListLimit} more destinations are in `{JsonName}`.");
            if (r.Network.SkippedLines > 0) md.Add($"\n{r.Network.SkippedLines} unreadable `net.log` lines were skipped.");
        }
        md.Add("");

        md.Add("## Files created and deleted (outside C:\\work)");
        md.Add("");
        if (!r.Files.Compared)
        {
            md.Add($"Not compared: the before listing is {StatusText(r.Files.Before)} and the after listing is {StatusText(r.Files.After)}.");
        }
        else
        {
            md.Add($"Created: {r.Files.Created!.Count}, deleted: {r.Files.Deleted!.Count}. Modified files are not detected.");
            AddList(md, "Created", r.Files.Created!, @"audit\files-created.txt");
            AddList(md, "Deleted", r.Files.Deleted!, @"audit\files-deleted.txt");
        }
        md.Add("");

        md.Add("## Registry changes");
        md.Add("");
        foreach (var c in r.Registry)
        {
            md.Add($"### {c.Hive}");
            md.Add("");
            if (!c.Compared)
            {
                md.Add($"Not compared: the before export is {StatusText(c.Before)} and the after export is {StatusText(c.After)}.");
                md.Add("");
                continue;
            }
            md.Add($"Added: {c.Added!.Count}, removed: {c.Removed!.Count}, changed: {c.Changed!.Count}.");
            AddList(md, "Added", c.Added!.Select(e => e.ToString()).ToList(), @"audit\registry-changes.txt");
            AddList(md, "Removed", c.Removed!.Select(e => e.ToString()).ToList(), @"audit\registry-changes.txt");
            AddList(md, "Changed", c.Changed!.Select(e => $"[{e.Key}] {e.Name}: {e.OldData} -> {e.NewData}").ToList(), @"audit\registry-changes.txt");
            var bg = c.Added!.Select(e => e.Key).Concat(c.Removed!.Select(e => e.Key)).Concat(c.Changed!.Select(e => e.Key))
                .Where(AuditReport.IsBackground).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            foreach (var k in bg) md.Add($"\nChanges under {Md.Code(k)} are normally made by Windows itself while any program runs.");
            md.Add("");
        }

        md.Add("## Files the program wrote to its working directory");
        md.Add("");
        if (r.OutputsStatus != InputStatus.Ok) md.Add("The output folder was not collected.");
        else if (r.Outputs.Count == 0) md.Add("None.");
        else
        {
            foreach (var o in r.Outputs.Take(MarkdownListLimit))
                md.Add($"- {Md.Code(@"out\" + o.Path)} ({o.Bytes.ToString(CultureInfo.InvariantCulture)} bytes)");
            if (r.Outputs.Count > MarkdownListLimit) md.Add($"\n{r.Outputs.Count - MarkdownListLimit} more files are in `{JsonName}`.");
        }
        md.Add("");
        md.Add("The program's console output is in `stdout.log` and `stderr.log` in the run folder.");
        md.Add("");

        md.Add("## Limits of this evidence");
        md.Add("");
        foreach (var l in AuditReport.Limits) md.Add("- " + l);
        md.Add("");
        return string.Join("\n", md);
    }

    private static void AddList(List<string> md, string title, IReadOnlyList<string> items, string fullList)
    {
        if (items.Count == 0) return;
        md.Add("");
        md.Add($"{title}:");
        md.Add("");
        md.AddRange(Md.Block(items.Take(MarkdownListLimit)));
        if (items.Count > MarkdownListLimit)
            md.Add($"\nShowing {MarkdownListLimit} of {items.Count}; the full list is in `{fullList}`.");
    }

    // ---------------- JSON ----------------

    public static byte[] Json(AuditReport r)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true }))
        {
            var i = r.Info;
            w.WriteStartObject();
            w.WriteString("schema", "fc-audit-report/1");
            w.WriteString("run_id", i.RunId);
            if (i.PairedRunId is null) w.WriteNull("paired_run_id"); else w.WriteString("paired_run_id", i.PairedRunId);
            w.WriteString("mode", i.Mode);
            w.WriteStartObject("sample");
            w.WriteString("path", i.SamplePath);
            w.WriteString("entry", i.Entry);
            w.WriteString("sha256", i.Sha256);
            w.WriteEndObject();
            w.WriteString("arguments", i.Arguments);
            w.WriteStartObject("program");
            w.WriteBoolean("finished", i.ProgramFinished);
            w.WriteBoolean("did_not_finish", !i.ProgramFinished);
            w.WriteBoolean("stopped", !i.ProgramFinished && i.ProgramStopped);
            if (i.ProgramFinished && i.ProgramExitCode is int code) w.WriteNumber("exit_code", code); else w.WriteNull("exit_code");
            w.WriteNumber("timeout_sec", i.TimeoutSec);
            w.WriteEndObject();

            w.WriteStartObject("network");
            if (r.Network is null) w.WriteString("status", "isolated");
            else
            {
                w.WriteString("status", StatusJson(r.Network.Status));
                w.WriteNumber("skipped_lines", r.Network.SkippedLines);
                w.WriteStartArray("destinations");
                foreach (var d in r.Network.Destinations)
                {
                    w.WriteStartObject();
                    w.WriteString("host", d.Host);
                    w.WriteNumber("port", d.Port);
                    w.WriteString("decision", d.Decision);
                    w.WriteNumber("attempts", d.Attempts);
                    WriteStrings(w, "addresses", d.Addresses);
                    WriteStrings(w, "reasons", d.Reasons);
                    w.WriteNumber("bytes_up", d.BytesUp);
                    w.WriteNumber("bytes_down", d.BytesDown);
                    w.WriteString("first_seen", d.FirstSeen);
                    w.WriteEndObject();
                }
                w.WriteEndArray();
            }
            w.WriteEndObject();

            w.WriteStartObject("files");
            w.WriteString("status", r.Files.Compared ? "ok" : "not_compared");
            w.WriteString("before", StatusJson(r.Files.Before));
            w.WriteString("after", StatusJson(r.Files.After));
            if (r.Files.Compared)
            {
                WriteStrings(w, "created", r.Files.Created!);
                WriteStrings(w, "deleted", r.Files.Deleted!);
            }
            w.WriteEndObject();

            w.WriteStartArray("registry");
            foreach (var c in r.Registry)
            {
                w.WriteStartObject();
                w.WriteString("hive", c.Hive);
                w.WriteString("status", c.Compared ? "ok" : "not_compared");
                w.WriteString("before", StatusJson(c.Before));
                w.WriteString("after", StatusJson(c.After));
                if (c.Compared)
                {
                    WriteEntries(w, "added", c.Added!);
                    WriteEntries(w, "removed", c.Removed!);
                    w.WriteStartArray("changed");
                    foreach (var e in c.Changed!)
                    {
                        w.WriteStartObject();
                        w.WriteString("key", e.Key);
                        w.WriteString("name", e.Name);
                        w.WriteString("old", e.OldData);
                        w.WriteString("new", e.NewData);
                        w.WriteBoolean("background", AuditReport.IsBackground(e.Key));
                        w.WriteEndObject();
                    }
                    w.WriteEndArray();
                }
                w.WriteEndObject();
            }
            w.WriteEndArray();

            w.WriteStartObject("outputs");
            w.WriteString("status", StatusJson(r.OutputsStatus));
            w.WriteStartArray("files");
            foreach (var o in r.Outputs)
            {
                w.WriteStartObject();
                w.WriteString("path", @"out\" + o.Path);
                w.WriteNumber("bytes", o.Bytes);
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();

            WriteStrings(w, "limits", AuditReport.Limits);
            w.WriteEndObject();
        }
        return ms.ToArray();
    }

    private static void WriteStrings(Utf8JsonWriter w, string name, IEnumerable<string> items)
    {
        w.WriteStartArray(name);
        foreach (var s in items) w.WriteStringValue(s);
        w.WriteEndArray();
    }

    private static void WriteEntries(Utf8JsonWriter w, string name, IEnumerable<RegEntry> entries)
    {
        w.WriteStartArray(name);
        foreach (var e in entries)
        {
            w.WriteStartObject();
            w.WriteString("key", e.Key);
            if (e.IsKey) { w.WriteNull("name"); w.WriteNull("data"); }
            else { w.WriteString("name", e.Name); w.WriteString("data", e.Data); }
            w.WriteBoolean("background", AuditReport.IsBackground(e.Key));
            w.WriteEndObject();
        }
        w.WriteEndArray();
    }
}
