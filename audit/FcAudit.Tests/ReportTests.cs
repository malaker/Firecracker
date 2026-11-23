using System.Text.Json;
using FcAudit.Core;

namespace FcAudit.Tests;

public sealed class ReportTests
{
    private static AuditInfo Info(string mode = "networked", bool finished = true, int? exit = 1, bool stopped = false) => new(
        RunId: "20261123-200325-dc3b", PairedRunId: "20261123-200123-acfd", Mode: mode,
        SamplePath: @"C:\Tools\yt-dlp", Entry: "yt-dlp.exe",
        Sha256: "08e30ae43a9f0c2d3ed716ef05a95fc7b4ee9d93862148e344bad3de51b93f3c",
        Arguments: "-v -o video.%(ext)s https://example.com/watch?v=x", ProgramExitCode: exit, ProgramFinished: finished, TimeoutSec: 300, ProgramStopped: stopped);

    private static string Golden(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", name)).Replace("\r\n", "\n");

    // Set FC_AUDIT_UPDATE_GOLDEN=<path to Fixtures\golden in the source tree> to regenerate.
    private static void AssertGolden(string name, string actual)
    {
        string? update = Environment.GetEnvironmentVariable("FC_AUDIT_UPDATE_GOLDEN");
        if (!string.IsNullOrEmpty(update))
        {
            File.WriteAllText(Path.Combine(update, name), actual);
            return;
        }
        Assert.Equal(Golden(name), actual.Replace("\r\n", "\n"));
    }

    [Fact]
    public void NetworkedReportMatchesGolden()
    {
        using var run = FixtureRun.Standard();
        var r = AuditReport.Build(run.Dir, Info());
        AssertGolden("networked.md", ReportWriter.Markdown(r));
        AssertGolden("networked.json", System.Text.Encoding.UTF8.GetString(ReportWriter.Json(r)));
    }

    [Fact]
    public void IsolatedReportSaysNoNetworkDevice()
    {
        using var run = FixtureRun.Standard();
        var r = AuditReport.Build(run.Dir, Info(mode: "isolated"));
        string md = ReportWriter.Markdown(r);
        Assert.Contains("the VM had no network device", md);
        Assert.DoesNotContain("www.youtube.com", md);
        using var doc = JsonDocument.Parse(ReportWriter.Json(r));
        Assert.Equal("isolated", doc.RootElement.GetProperty("network").GetProperty("status").GetString());
    }

    [Fact]
    public void JsonHoldsTheSameFactsAsMarkdown()
    {
        using var run = FixtureRun.Standard();
        var r = AuditReport.Build(run.Dir, Info());
        using var doc = JsonDocument.Parse(ReportWriter.Json(r));
        var root = doc.RootElement;
        Assert.Equal("20261123-200123-acfd", root.GetProperty("paired_run_id").GetString());
        Assert.Equal(1, root.GetProperty("program").GetProperty("exit_code").GetInt32());
        var dests = root.GetProperty("network").GetProperty("destinations");
        Assert.Equal(2, dests.GetArrayLength());
        Assert.Equal(2, dests[0].GetProperty("attempts").GetInt32());
        Assert.Equal(4524, dests[0].GetProperty("bytes_up").GetInt64());
        var created = root.GetProperty("files").GetProperty("created").EnumerateArray().Select(e => e.GetString()).ToList();
        Assert.Contains(@"C:\Users\Public\x.dll", created);
        Assert.DoesNotContain(created, p => p!.StartsWith(@"C:\work", StringComparison.OrdinalIgnoreCase));
        var hkcu = root.GetProperty("registry")[1];
        Assert.Contains(hkcu.GetProperty("added").EnumerateArray(), e => e.GetProperty("name").GetString() == "\"Updater\"");
        var hklm = root.GetProperty("registry")[0];
        Assert.True(hklm.GetProperty("changed")[0].GetProperty("background").GetBoolean());
        Assert.Equal(@"out\page.html", root.GetProperty("outputs").GetProperty("files")[0].GetProperty("path").GetString());
        Assert.Equal(AuditReport.Limits.Count, root.GetProperty("limits").GetArrayLength());
    }

    [Fact]
    public void ProgramThatDidNotFinishIsRecorded()
    {
        using var run = FixtureRun.Standard();
        var r = AuditReport.Build(run.Dir, Info(finished: false, exit: null));
        Assert.Contains("**did not finish** within the 300s limit", ReportWriter.Markdown(r));
        using var doc = JsonDocument.Parse(ReportWriter.Json(r));
        var p = doc.RootElement.GetProperty("program");
        Assert.True(p.GetProperty("did_not_finish").GetBoolean());
        Assert.Equal(JsonValueKind.Null, p.GetProperty("exit_code").ValueKind);
        Assert.False(p.GetProperty("stopped").GetBoolean());
        Assert.Contains("could not be stopped", ReportWriter.Markdown(r));
    }

    [Fact]
    public void ProgramStoppedAtTheLimitIsRecorded()
    {
        using var run = FixtureRun.Standard();
        var r = AuditReport.Build(run.Dir, Info(finished: false, exit: null, stopped: true));
        Assert.Contains("it was stopped there, then the after snapshots were taken", ReportWriter.Markdown(r));
        using var doc = JsonDocument.Parse(ReportWriter.Json(r));
        Assert.True(doc.RootElement.GetProperty("program").GetProperty("stopped").GetBoolean());
    }

    [Fact]
    public void InfoJsonProgramStoppedIsOptional()
    {
        string dir = Directory.CreateTempSubdirectory("fc-audit-info-").FullName;
        try
        {
            string p = Path.Combine(dir, "info.json");
            const string common = "\"run_id\":\"r\",\"mode\":\"isolated\",\"sample_path\":\"s\",\"entry\":\"e.exe\",\"sha256\":\"x\",\"program_finished\":false";
            File.WriteAllText(p, "{" + common + "}");
            Assert.False(AuditInfo.Load(p).ProgramStopped);
            File.WriteAllText(p, "{" + common + ",\"program_stopped\":true}");
            Assert.True(AuditInfo.Load(p).ProgramStopped);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void MissingSnapshotsAreReportedAsMissingNotAsNoChanges()
    {
        using var run = new FixtureRun();
        run.Txt("fs-before.txt", @"C:\a");
        var r = AuditReport.Build(run.Dir, Info());
        string md = ReportWriter.Markdown(r);
        Assert.Contains("Not compared: the before listing is ok and the after listing is missing.", md);
        Assert.Contains("Not compared: the before export is missing and the after export is missing.", md);
        Assert.Contains("`net.log` is missing", md);
        Assert.DoesNotContain("Created: 0", md);
    }

    [Fact]
    public void OversizedSnapshotIsReportedAsTooLarge()
    {
        using var run = FixtureRun.Standard();
        var r = AuditReport.Build(run.Dir, Info(), maxInputBytes: 100);
        Assert.Contains("too large to compare", ReportWriter.Markdown(r));
    }

    [Fact]
    public void LongListsAreTruncatedWithANote()
    {
        using var run = new FixtureRun();
        run.Txt("fs-before.txt", @"C:\x");
        run.Txt("fs-after.txt", Enumerable.Range(0, 250).Select(i => $@"C:\Users\Public\f{i}.txt").Prepend(@"C:\x").ToArray());
        var r = AuditReport.Build(run.Dir, Info(mode: "isolated"));
        string md = ReportWriter.Markdown(r);
        Assert.Contains(@"Showing 200 of 250; the full list is in `audit\files-created.txt`.", md);
        Assert.DoesNotContain(@"C:\Users\Public\f249.txt", md);
    }

    [Fact]
    public void WriteAllProducesReportsAndFullLists()
    {
        using var run = FixtureRun.Standard();
        string outDir = Path.Combine(run.Dir, "report-staging");
        Directory.CreateDirectory(outDir);
        ReportWriter.WriteAll(AuditReport.Build(run.Dir, Info()), outDir);
        Assert.True(File.Exists(Path.Combine(outDir, "audit-report.md")));
        Assert.True(File.Exists(Path.Combine(outDir, "audit-report.json")));
        Assert.Contains(@"C:\Users\Public\x.dll", File.ReadAllLines(Path.Combine(outDir, "audit", "files-created.txt")));
        Assert.Contains(File.ReadAllLines(Path.Combine(outDir, "audit", "registry-changes.txt")), l => l.StartsWith("+ [HKEY_CURRENT_USER\\Software\\FcAuditProbe]"));
    }

    [Fact]
    public void LimitsSectionStatesEveryLimit()
    {
        using var run = FixtureRun.Standard();
        string md = ReportWriter.Markdown(AuditReport.Build(run.Dir, Info()));
        Assert.Contains("## Limits of this evidence", md);
        foreach (var needle in new[] { "administrator", "Modified files are not detected", "host names and ports", "HTTP_PROXY", "untrusted" })
            Assert.Contains(needle, md);
    }
}

public sealed class MdTests
{
    [Theory]
    [InlineData("plain", "`plain`")]
    [InlineData("a`b", "``a`b``")]
    [InlineData("`x", "`` `x ``")]
    [InlineData("", "``")]
    [InlineData("line1\nline2", "`line1\\u000aline2`")]
    public void CodeSpansSurviveBackticksAndNewlines(string input, string expected) => Assert.Equal(expected, Md.Code(input));

    [Fact]
    public void CellEscapesPipes() => Assert.Equal("`a\\|b`", Md.Cell("a|b"));

    [Fact]
    public void BlockFenceIsLongerThanAnyBacktickRunInside()
    {
        var b = Md.Block(new[] { "````" }).ToList();
        Assert.Equal("`````text", b[0]);
        Assert.Equal("`````", b[^1]);
    }

    [Fact]
    public void InjectedMarkdownStaysInsideCode()
    {
        string evil = "x](http://evil) <img src=x> # heading";
        string code = Md.Code(evil);
        Assert.StartsWith("`", code);
        Assert.EndsWith("`", code);
    }
}
