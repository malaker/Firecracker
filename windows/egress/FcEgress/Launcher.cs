using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using static FcEgress.Native;

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
            job = LimitingJob();
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

    // Each child inherits exactly its own three handles. The explicit handle list matters:
    // with plain inheritance a child also gets every inheritable handle launch itself
    // inherited (e.g. a caller's stderr pipe), and since the children live as long as the VM,
    // that caller would wait for EOF until the VM is destroyed.
    private static PROCESS_INFORMATION Spawn(IntPtr token, string commandLine, SafeHandle stdin, SafeHandle stdout, SafeHandle stderr, bool suspended)
    {
        var handles = new[] { stdin, stdout, stderr };
        foreach (var h in handles) Check(SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT), "SetHandleInformation");
        IntPtr attrList = IntPtr.Zero, handleArray = IntPtr.Zero;
        try
        {
            var distinct = handles.Select(h => h.DangerousGetHandle()).Distinct().ToArray();
            handleArray = Marshal.AllocHGlobal(IntPtr.Size * distinct.Length);
            Marshal.Copy(distinct, 0, handleArray, distinct.Length);

            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attrList = Marshal.AllocHGlobal(size);
            Check(InitializeProcThreadAttributeList(attrList, 1, 0, ref size), "InitializeProcThreadAttributeList");
            Check(UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handleArray,
                (IntPtr)(IntPtr.Size * distinct.Length), IntPtr.Zero, IntPtr.Zero), "UpdateProcThreadAttribute");

            var si = new STARTUPINFOEX
            {
                StartupInfo = new STARTUPINFO
                {
                    cb = Marshal.SizeOf<STARTUPINFOEX>(),
                    dwFlags = STARTF_USESTDHANDLES,
                    hStdInput = stdin.DangerousGetHandle(),
                    hStdOutput = stdout.DangerousGetHandle(),
                    hStdError = stderr.DangerousGetHandle(),
                },
                lpAttributeList = attrList,
            };
            uint flags = CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT | (suspended ? CREATE_SUSPENDED : 0);
            var cmd = new StringBuilder(commandLine);
            PROCESS_INFORMATION pi;
            bool ok = token == IntPtr.Zero
                ? CreateProcessW(null, cmd, IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, null, ref si, out pi)
                : CreateProcessAsUserW(token, null, cmd, IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, null, ref si, out pi);
            Check(ok, token == IntPtr.Zero ? "CreateProcess" : "CreateProcessAsUser");
            return pi;
        }
        finally
        {
            if (attrList != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(attrList);
                Marshal.FreeHGlobal(attrList);
            }
            if (handleArray != IntPtr.Zero) Marshal.FreeHGlobal(handleArray);
            foreach (var h in handles) SetHandleInformation(h, HANDLE_FLAG_INHERIT, 0);
        }
    }

    // Same restriction as 'runas /trustlevel:0x20000' (Administrators becomes deny-only and
    // privileges are dropped), then lowered from High to Medium integrity.
    private static IntPtr RestrictedToken()
    {
        Check(SaferCreateLevel(SAFER_SCOPEID_USER, SAFER_LEVELID_NORMALUSER, SAFER_LEVEL_OPEN, out var level, IntPtr.Zero), "SaferCreateLevel");
        IntPtr token;
        try
        {
            Check(SaferComputeTokenFromLevel(level, IntPtr.Zero, out token, 0, IntPtr.Zero), "SaferComputeTokenFromLevel");
        }
        finally
        {
            SaferCloseLevel(level);
        }

        Check(ConvertStringSidToSidW("S-1-16-8192", out var medium), "ConvertStringSidToSid");
        try
        {
            var label = new TOKEN_MANDATORY_LABEL { Label = new SID_AND_ATTRIBUTES { Sid = medium, Attributes = SE_GROUP_INTEGRITY } };
            int size = Marshal.SizeOf<TOKEN_MANDATORY_LABEL>() + GetLengthSid(medium);
            if (!SetTokenInformation(token, TokenIntegrityLevelClass, ref label, size))
            {
                int err = Marshal.GetLastWin32Error();
                CloseHandle(token);
                throw new Win32Exception(err, "SetTokenInformation(TokenIntegrityLevel)");
            }
        }
        finally
        {
            LocalFree(medium);
        }
        return token;
    }

    // No child processes, bounded memory. Not kill-on-close: serve must outlive launch.
    private static IntPtr LimitingJob()
    {
        var job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject");
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION
            {
                LimitFlags = JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
                ActiveProcessLimit = 1,
            },
            ProcessMemoryLimit = (UIntPtr)ServeMemoryLimit,
        };
        Check(SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()), "SetInformationJobObject");
        return job;
    }

    private static SafeFileHandle OpenLog(string path) =>
        File.OpenHandle(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite);

    private static string Quote(string s) => s.Contains(' ') || s.Contains('"') ? "\"" + s.Replace("\"", "\\\"") + "\"" : s;

    private static void Check(bool ok, string what)
    {
        if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), what);
    }
}
