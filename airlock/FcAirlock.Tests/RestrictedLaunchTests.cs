using System.Diagnostics;
using System.Security.Principal;
using FcWin;

namespace FcAirlock.Tests;

/// <summary>Runs only on Windows from an elevated prompt (the case launch-unpack exists for).</summary>
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

#pragma warning disable CA1416 // every test is guarded by ElevatedWindowsFact
public sealed class RestrictedLaunchTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("fc-airlock-launch-").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private uint? Run(string cmd, string outFile, TimeSpan timeout, uint processLimit = 1)
    {
        using var nul = File.OpenHandle("NUL", FileMode.Open, FileAccess.Read);
        using var output = File.OpenHandle(outFile, FileMode.Create, FileAccess.Write, FileShare.ReadWrite);
        return RestrictedLaunch.RunToCompletion(cmd, nul, output, output, timeout, processLimit, 256UL * 1024 * 1024);
    }

    private static string Cmd(string args) => $"\"{Environment.GetEnvironmentVariable("ComSpec") ?? @"C:\Windows\System32\cmd.exe"}\" /c {args}";

    [ElevatedWindowsFact]
    public void ChildTokenIsNotAdministratorAndRunsAtMediumIntegrity()
    {
        string outFile = Path.Combine(_dir, "groups.txt");
        // whoami is a separate process, so this child needs room for one more.
        Assert.Equal(0u, Run(Cmd("whoami /groups /fo csv"), outFile, TimeSpan.FromSeconds(30), processLimit: 2));
        string[] lines = File.ReadAllLines(outFile);
        string admins = Assert.Single(lines, l => l.Contains("S-1-5-32-544"));
        Assert.Contains("Group used for deny only", admins);
        Assert.Contains(lines, l => l.Contains("S-1-16-8192")); // Medium Mandatory Level
        Assert.DoesNotContain(lines, l => l.Contains("S-1-16-12288")); // not High
    }

    [ElevatedWindowsFact]
    public void GrandchildDoesNotOutliveTheCall()
    {
        var before = Process.GetProcessesByName("PING").Select(p => p.Id).ToHashSet();
        // cmd starts a long ping in the background and exits at once, leaving the ping behind.
        uint? code = Run(Cmd("start /b ping -n 60 127.0.0.1 & exit /b 0"), Path.Combine(_dir, "out.txt"), TimeSpan.FromSeconds(30), processLimit: 4);
        Assert.Equal(0u, code);
        // Closing the job kills its processes asynchronously; allow a loaded machine a moment.
        var sw = Stopwatch.StartNew();
        while (Process.GetProcessesByName("PING").Any(p => !before.Contains(p.Id)) && sw.Elapsed < TimeSpan.FromSeconds(5)) Thread.Sleep(100);
        Assert.DoesNotContain(Process.GetProcessesByName("PING"), p => !before.Contains(p.Id));
    }

    [ElevatedWindowsFact]
    public void TimeoutKillsTheChild()
    {
        var sw = Stopwatch.StartNew();
        uint? code = Run(Cmd("ping -n 60 127.0.0.1"), Path.Combine(_dir, "out.txt"), TimeSpan.FromSeconds(2), processLimit: 2);
        Assert.Null(code);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(15), $"took {sw.Elapsed}");
    }

    [ElevatedWindowsFact]
    public void OneProcessLimitStopsAnyGrandchild()
    {
        // The limit launch-unpack uses: cmd itself may run, but it cannot start ping.
        string outFile = Path.Combine(_dir, "out.txt");
        uint? code = Run(Cmd("ping -n 1 127.0.0.1"), outFile, TimeSpan.FromSeconds(30), processLimit: 1);
        Assert.NotEqual(0u, code);
        Assert.DoesNotContain("Reply from", File.ReadAllText(outFile));
    }
}
#pragma warning restore CA1416
