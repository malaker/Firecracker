using FcAudit.Core;

// fc-audit <command> [options]
//   --version    print the tool version
//   report --run DIR --info FILE --out DIR
//                build the audit report for the run folder DIR (runs\<run-id>) from the guest's
//                snapshots in DIR\out\_audit and DIR\net.log, using the controller's trusted facts in
//                FILE (info.json). Writes audit-report.md, audit-report.json and audit\*.txt into the
//                empty folder given by --out. Reads guest-derived data, so it refuses to run with
//                administrator rights: an elevated caller uses launch-report (design D4).
//   launch-report --run DIR --info FILE --out DIR
//                (Windows, elevated controller) run 'report' as a non-admin, Medium-integrity child in
//                a kill-on-close job (1 process, 1 GiB, 120 s) and return its exit code. On any
//                failure the --out folder is emptied, so no partial report is left behind.
//   kill --image NAME
//                (inside a guest, Windows) stop every process whose image is NAME (e.g. tool.exe),
//                together with the processes it started. Uploaded into the guest only when an audited
//                program outlives -Timeout and the guest has no taskkill.exe (Nano Server has none).
//                Prints the number of processes stopped; exit 0 also when none was running.
// Exit codes: 0 ok, 2 usage, 5 internal error (including timeout). Errors are one line on stderr.
return FcAudit.Cli.Run(args);

namespace FcAudit
{
    internal static class Cli
    {
        private const string Usage = "usage: fc-audit --version | report --run DIR --info FILE --out DIR | launch-report --run DIR --info FILE --out DIR | kill --image NAME";
        private static readonly TimeSpan ReportTimeout = TimeSpan.FromSeconds(120);
        private const ulong ReportMemoryLimit = 1024UL * 1024 * 1024;

        // Tests only: FC_AUDIT_TEST_TIMEOUT_MS may lower the launch timeout, and
        // FC_AUDIT_TEST_REPORT_DELAY_MS slows 'report' down, to exercise the timeout path.
        private const string TestTimeoutVariable = "FC_AUDIT_TEST_TIMEOUT_MS";
        private const string TestDelayVariable = "FC_AUDIT_TEST_REPORT_DELAY_MS";

        public static int Run(string[] args)
        {
            if (args.Length == 0)
            {
                Console.Error.WriteLine(Usage);
                return ExitCodes.Usage;
            }
            try
            {
                switch (args[0])
                {
                    case "--version" when args.Length == 1:
                        Console.Out.WriteLine($"fc-audit {typeof(Cli).Assembly.GetName().Version?.ToString(3)}");
                        return ExitCodes.Ok;
                    case "report" when args.Length == 7:
                        return Report(args);
                    case "launch-report" when args.Length == 7 && OperatingSystem.IsWindows():
                        return LaunchReport(args);
                    case "kill" when args.Length == 3 && args[1] == "--image":
                        return Kill(args[2]);
                    default:
                        Console.Error.WriteLine(Usage);
                        return ExitCodes.Usage;
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"error: {ex.GetType().Name}: {ex.Message}");
                return ExitCodes.Internal;
            }
        }

        // Stops every process with image NAME and the processes each one started. Its own process is
        // never matched (NAME would be fc-audit.exe only when fc-audit itself is being audited).
        private static int Kill(string image)
        {
            string name = Path.GetFileNameWithoutExtension(image);
            if (name.Length == 0 || image.IndexOfAny(new[] { '\\', '/', ':' }) >= 0)
            {
                Console.Error.WriteLine(Usage);
                return ExitCodes.Usage;
            }
            int self = Environment.ProcessId, stopped = 0, failed = 0;
            foreach (var p in System.Diagnostics.Process.GetProcessesByName(name))
            {
                using (p)
                {
                    if (p.Id == self) continue;
                    try
                    {
                        p.Kill(entireProcessTree: true);
                        p.WaitForExit(10_000);
                        stopped++;
                    }
                    catch (InvalidOperationException)
                    {
                        // It ended on its own in the meantime.
                    }
                    catch (Exception ex)
                    {
                        failed++;
                        Console.Error.WriteLine($"error: could not stop {name} (pid {p.Id}): {ex.Message}");
                    }
                }
            }
            Console.Out.WriteLine($"stopped {stopped}");
            return failed == 0 ? ExitCodes.Ok : ExitCodes.Internal;
        }

        private sealed record Paths(string Run, string Info, string Out);

        private static Paths? ParseArgs(string[] args)
        {
            string? run = null, info = null, output = null;
            for (int i = 1; i + 1 < args.Length; i += 2)
            {
                switch (args[i])
                {
                    case "--run": run = args[i + 1]; break;
                    case "--info": info = args[i + 1]; break;
                    case "--out": output = args[i + 1]; break;
                    default: return null;
                }
            }
            return run is null || info is null || output is null
                ? null
                : new Paths(Path.GetFullPath(run), Path.GetFullPath(info), Path.GetFullPath(output));
        }

        private static int Report(string[] args)
        {
            var p = ParseArgs(args);
            if (p is null)
            {
                Console.Error.WriteLine(Usage);
                return ExitCodes.Usage;
            }
            // Guest-derived data is never parsed with admin rights (spec: unprivileged report building).
            if (OperatingSystem.IsWindows() && FcWin.TokenInfo.HasAdminRights(out string why))
            {
                Console.Error.WriteLine($"error: refusing to read guest data with administrator rights ({why}); use launch-report");
                return ExitCodes.Internal;
            }
            if (!Directory.Exists(p.Run)) throw new DirectoryNotFoundException($"run folder not found: {p.Run}");
            if (!Directory.Exists(p.Out) || Directory.EnumerateFileSystemEntries(p.Out).Any())
                throw new IOException($"--out must be an existing, empty folder: {p.Out}");
            if (int.TryParse(Environment.GetEnvironmentVariable(TestDelayVariable), out int delay) && delay > 0) Thread.Sleep(delay);

            var info = AuditInfo.Load(p.Info);
            var report = AuditReport.Build(p.Run, info);
            ReportWriter.WriteAll(report, p.Out);
            Console.Out.WriteLine("ok");
            return ExitCodes.Ok;
        }

        // The elevated Windows controller must not parse guest-derived data with admin rights
        // (design D4, like fc-airlock's launch-unpack): re-run this exe's 'report' with a restricted
        // token. The child writes straight to our stdout and stderr; nothing it starts outlives it.
        [System.Runtime.Versioning.SupportedOSPlatform("windows")]
        private static int LaunchReport(string[] args)
        {
            var p = ParseArgs(args);
            if (p is null)
            {
                Console.Error.WriteLine(Usage);
                return ExitCodes.Usage;
            }
            TimeSpan timeout = ReportTimeout;
            if (int.TryParse(Environment.GetEnvironmentVariable(TestTimeoutVariable), out int ms) && ms > 0 && ms < timeout.TotalMilliseconds)
                timeout = TimeSpan.FromMilliseconds(ms);

            string self = Environment.ProcessPath ?? throw new InvalidOperationException("cannot locate fc-audit.exe");
            string cmd = $"\"{self}\" report --run \"{p.Run}\" --info \"{p.Info}\" --out \"{p.Out}\"";
            Console.Out.Flush();
            using var nul = File.OpenHandle("NUL", FileMode.Open, FileAccess.Read);
            using var stdout = StdHandle(-11);
            using var stderr = StdHandle(-12);
            uint? code = FcWin.RestrictedLaunch.RunToCompletion(cmd, nul, stdout ?? nul, stderr ?? nul, timeout, 1, ReportMemoryLimit);
            if (code == 0) return ExitCodes.Ok;

            EmptyFolder(p.Out);
            if (code is null)
            {
                Console.Error.WriteLine($"error: the report was not built within {timeout.TotalSeconds:0}s");
                return ExitCodes.Internal;
            }
            return code.Value == ExitCodes.Usage ? ExitCodes.Usage : ExitCodes.Internal;
        }

        private static void EmptyFolder(string dir)
        {
            if (!Directory.Exists(dir)) return;
            foreach (var d in Directory.EnumerateDirectories(dir)) Directory.Delete(d, recursive: true);
            foreach (var f in Directory.EnumerateFiles(dir)) File.Delete(f);
        }

        [System.Runtime.Versioning.SupportedOSPlatform("windows")]
        private static Microsoft.Win32.SafeHandles.SafeFileHandle? StdHandle(int which)
        {
            IntPtr h = FcWin.Native.GetStdHandle(which);
            return h == IntPtr.Zero || h == new IntPtr(-1) ? null : new Microsoft.Win32.SafeHandles.SafeFileHandle(h, ownsHandle: false);
        }
    }
}
