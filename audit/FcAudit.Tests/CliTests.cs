using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;

namespace FcAudit.Tests;

/// <summary>Runs only on Windows from an elevated prompt (the case launch-report exists for).</summary>
public sealed class ElevatedWindowsFactAttribute : FactAttribute
{
    public ElevatedWindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindows()) { Skip = "Windows only"; return; }
#pragma warning disable CA1416
        using var id = WindowsIdentity.GetCurrent();
        if (!new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator)) Skip = "needs an elevated prompt";
#pragma warning restore CA1416
    }
}

/// <summary>Runs only when the prompt is NOT elevated ('report' refuses admin rights).</summary>
public sealed class NonElevatedFactAttribute : FactAttribute
{
    public NonElevatedFactAttribute()
    {
        if (!OperatingSystem.IsWindows()) return;
#pragma warning disable CA1416
        using var id = WindowsIdentity.GetCurrent();
        if (new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator)) Skip = "needs a non-elevated prompt";
#pragma warning restore CA1416
    }
}

public sealed class CliTests : IDisposable
{
    private readonly FixtureRun _run = FixtureRun.Standard();
    private readonly string _work = Directory.CreateTempSubdirectory("fc-audit-cli-").FullName;

    public void Dispose()
    {
        _run.Dispose();
        Directory.Delete(_work, recursive: true);
    }

    private static string Exe => Path.Combine(AppContext.BaseDirectory, OperatingSystem.IsWindows() ? "fc-audit.exe" : "fc-audit");

    private string Info()
    {
        string p = Path.Combine(_work, "info.json");
        File.WriteAllText(p, JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["run_id"] = "20261123-200325-dc3b",
            ["paired_run_id"] = null,
            ["mode"] = "networked",
            ["sample_path"] = @"C:\q\tool.exe",
            ["entry"] = "tool.exe",
            ["sha256"] = new string('0', 64),
            ["arguments"] = "--version",
            ["program_exit_code"] = 0,
            ["program_finished"] = true,
            ["timeout_sec"] = 300,
        }));
        return p;
    }

    private string NewOut()
    {
        string d = Path.Combine(_work, "out-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(d);
        return d;
    }

    private static (int Code, string Out, string Err) Run(Dictionary<string, string>? env, params string[] args)
    {
        var psi = new ProcessStartInfo(Exe) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in args) psi.ArgumentList.Add(a);
        if (env is not null) foreach (var (k, v) in env) psi.Environment[k] = v;
        using var p = Process.Start(psi)!;
        string o = p.StandardOutput.ReadToEnd(), e = p.StandardError.ReadToEnd();
        Assert.True(p.WaitForExit(60_000), "fc-audit did not exit");
        return (p.ExitCode, o, e);
    }

    [Fact]
    public void VersionPrints() => Assert.StartsWith("fc-audit 1.0.0", Run(null, "--version").Out);

    [Fact]
    public void BadArgumentsAreAUsageError() => Assert.Equal(2, Run(null, "report", "--run", "x").Code);

    [Fact]
    public void KillRefusesPathsAsImageNames() => Assert.Equal(2, Run(null, "kill", "--image", @"C:\Windows\x.exe").Code);

    [Fact]
    public void KillWithNothingRunningSucceeds()
    {
        var r = Run(null, "kill", "--image", $"fc-audit-none-{Guid.NewGuid():N}.exe");
        Assert.Equal(0, r.Code);
        Assert.Contains("stopped 0", r.Out);
    }

    // The case it exists for: a program (here a uniquely named copy of cmd.exe) that started a child
    // (ping) and is still running; both must be gone afterwards.
    [Fact]
    public void KillStopsTheProgramAndTheProcessesItStarted()
    {
        if (!OperatingSystem.IsWindows()) return;
        string image = $"fcaudit-kill-{Guid.NewGuid():N}"[..24] + ".exe";
        string copy = Path.Combine(_work, image);
        File.Copy(Path.Combine(Environment.SystemDirectory, "cmd.exe"), copy);
        var pingsBefore = Process.GetProcessesByName("PING").Select(p => p.Id).ToHashSet();
        using var prog = Process.Start(new ProcessStartInfo(copy, "/c ping -n 120 127.0.0.1 >nul") { UseShellExecute = false, CreateNoWindow = true })!;
        // Wait for the child ping to appear.
        var sw = Stopwatch.StartNew();
        int[] newPings = Array.Empty<int>();
        while (sw.Elapsed < TimeSpan.FromSeconds(10))
        {
            newPings = Process.GetProcessesByName("PING").Select(p => p.Id).Where(id => !pingsBefore.Contains(id)).ToArray();
            if (newPings.Length > 0) break;
            Thread.Sleep(100);
        }
        try
        {
            Assert.NotEmpty(newPings);
            var r = Run(null, "kill", "--image", image);
            Assert.True(r.Code == 0, r.Err);
            Assert.Contains("stopped 1", r.Out);
            Assert.True(prog.WaitForExit(10_000), "the program is still running");
            sw.Restart();
            while (newPings.Any(Alive) && sw.Elapsed < TimeSpan.FromSeconds(10)) Thread.Sleep(100);
            Assert.False(newPings.Any(Alive), "the program's child is still running");
        }
        finally
        {
            if (!prog.HasExited) prog.Kill(entireProcessTree: true);
            foreach (var id in newPings.Where(Alive)) Process.GetProcessById(id).Kill();
        }

        static bool Alive(int id)
        {
            try { using var p = Process.GetProcessById(id); return !p.HasExited; } catch (ArgumentException) { return false; }
        }
    }

    [NonElevatedFact]
    public void ReportWritesFilesIntoTheEmptyOutFolder()
    {
        string o = NewOut();
        var r = Run(null, "report", "--run", _run.Dir, "--info", Info(), "--out", o);
        Assert.True(r.Code == 0, r.Err);
        Assert.True(File.Exists(Path.Combine(o, "audit-report.md")));
        Assert.True(File.Exists(Path.Combine(o, "audit-report.json")));
        Assert.True(File.Exists(Path.Combine(o, "audit", "files-created.txt")));
    }

    [NonElevatedFact]
    public void ReportRefusesANonEmptyOutFolder()
    {
        string o = NewOut();
        File.WriteAllText(Path.Combine(o, "x"), "");
        Assert.Equal(5, Run(null, "report", "--run", _run.Dir, "--info", Info(), "--out", o).Code);
    }

    [ElevatedWindowsFact]
    public void ReportRefusesToRunWithAdminRights()
    {
        string o = NewOut();
        var r = Run(null, "report", "--run", _run.Dir, "--info", Info(), "--out", o);
        Assert.Equal(5, r.Code);
        Assert.Contains("refusing to read guest data with administrator rights", r.Err);
        Assert.Empty(Directory.EnumerateFileSystemEntries(o));
    }

    // 'report' refuses admin rights, so a report from an elevated launch-report proves the child ran without them.
    [ElevatedWindowsFact]
    public void LaunchReportBuildsTheReportWithoutAdminRights()
    {
        string o = NewOut();
        var r = Run(null, "launch-report", "--run", _run.Dir, "--info", Info(), "--out", o);
        Assert.True(r.Code == 0, r.Err);
        Assert.True(File.Exists(Path.Combine(o, "audit-report.md")));
    }

    [ElevatedWindowsFact]
    public void LaunchReportTimeoutLeavesNoReport()
    {
        string o = NewOut();
        var env = new Dictionary<string, string> { ["FC_AUDIT_TEST_TIMEOUT_MS"] = "1500", ["FC_AUDIT_TEST_REPORT_DELAY_MS"] = "20000" };
        var sw = Stopwatch.StartNew();
        var r = Run(env, "launch-report", "--run", _run.Dir, "--info", Info(), "--out", o);
        Assert.Equal(5, r.Code);
        Assert.Contains("not built within", r.Err);
        Assert.Empty(Directory.EnumerateFileSystemEntries(o));
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(15), $"took {sw.Elapsed}");
    }
}
