using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using FcWin;
using static FcWin.Native;
using static FcWin.RestrictedLaunch;

namespace FcEgress;

// 'launch' runs elevated (the Docker engine pipe requires it). It wires
//   docker exec -i <container> C:\fc\fc-relay.exe   <--pipes-->   fc-egress serve
// with serve under a non-admin, Medium-integrity token in a job object, prints both PIDs
// as JSON and exits; the two children keep the pipes alive on their own.
internal static class Launcher
{
    private const string GuestRelayPath = @"C:\fc\fc-relay.exe";
    private const string GuestUser = "ContainerAdministrator";
    private const ulong ServeMemoryLimit = 512UL * 1024 * 1024;

    public static int Run(Options o)
    {
        string docker = o.Require("docker");
        string container = o.Require("container");
        string policy = o.Require("policy");
        string stderrDir = o.Require("stderr-dir");
        string self = Environment.ProcessPath ?? throw new InvalidOperationException("cannot locate fc-egress.exe");

        // CreateProcess with inheritance passes every inheritable handle, including the pipes
        // the controller gave launch for its own stdio. Children holding those would keep the
        // controller waiting for launch's output forever, so they must not be inheritable.
        foreach (int std in new[] { -10, -11, -12 })
        {
            var h = GetStdHandle(std);
            if (h != IntPtr.Zero && h != new IntPtr(-1)) SetRawHandleInformation(h, HANDLE_FLAG_INHERIT, 0);
        }

        // guestToHost: docker stdout -> serve stdin; hostToGuest: serve stdout -> docker stdin.
        Check(CreatePipe(out var g2hRead, out var g2hWrite, IntPtr.Zero, 0), "CreatePipe");
        Check(CreatePipe(out var h2gRead, out var h2gWrite, IntPtr.Zero, 0), "CreatePipe");
        using var execErr = OpenLog(Path.Combine(stderrDir, "relay-exec.err"));
        using var serveErr = OpenLog(Path.Combine(stderrDir, "egress.err"));

        PROCESS_INFORMATION exec = default, serve = default;
        IntPtr token = IntPtr.Zero, job = IntPtr.Zero;
        try
        {
            exec = Spawn(IntPtr.Zero, $"{Quote(docker)} exec -i -u {GuestUser} {Quote(container)} {GuestRelayPath}",
                h2gRead, g2hWrite, execErr, suspended: false);

            token = RestrictedToken();
            serve = Spawn(token, $"{Quote(self)} serve --policy {Quote(policy)}", g2hRead, h2gWrite, serveErr, suspended: true);
            // No child processes, bounded memory. Not kill-on-close: serve must outlive launch.
            job = LimitingJob(1, ServeMemoryLimit, killOnClose: false);
            Check(AssignProcessToJobObject(job, serve.hProcess), "AssignProcessToJobObject");
            if (ResumeThread(serve.hThread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(), "ResumeThread");

            Console.WriteLine($"{{\"serve_pid\":{serve.dwProcessId},\"exec_pid\":{exec.dwProcessId}}}");
            return 0;
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException)
        {
            if (serve.hProcess != IntPtr.Zero) TerminateProcess(serve.hProcess, 1);
            if (exec.hProcess != IntPtr.Zero) TerminateProcess(exec.hProcess, 1);
            Console.Error.WriteLine($"fc-egress launch: {ex.Message}");
            return 1;
        }
        finally
        {
            foreach (var h in new[] { exec.hProcess, exec.hThread, serve.hProcess, serve.hThread, token, job })
            {
                if (h != IntPtr.Zero) CloseHandle(h);
            }
            foreach (var h in new SafeHandle[] { g2hRead, g2hWrite, h2gRead, h2gWrite }) h.Dispose();
        }
    }

    private static SafeFileHandle OpenLog(string path) =>
        File.OpenHandle(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite);

    private static string Quote(string s) => s.Contains(' ') || s.Contains('"') ? "\"" + s.Replace("\"", "\\\"") + "\"" : s;
}
