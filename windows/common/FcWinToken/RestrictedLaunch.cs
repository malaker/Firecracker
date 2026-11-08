using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32.SafeHandles;
using static FcWin.Native;

namespace FcWin;

/// <summary>
/// Starting a child with a restricted token from an elevated parent. Moved out of fc-egress's
/// launcher unchanged so fc-airlock can run its host-side unpack the same way.
/// </summary>
[SupportedOSPlatform("windows")]
public static class RestrictedLaunch
{
    // Each child inherits exactly its own three handles. The explicit handle list matters:
    // with plain inheritance a child also gets every inheritable handle the parent itself
    // inherited (e.g. a caller's stderr pipe), and a long-lived child would keep that caller
    // waiting for EOF.
    public static PROCESS_INFORMATION Spawn(IntPtr token, string commandLine, SafeHandle stdin, SafeHandle stdout, SafeHandle stderr, bool suspended)
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
    public static IntPtr RestrictedToken()
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

    /// <summary>A job with an active-process limit and a per-process memory limit; optionally kill-on-close.</summary>
    public static IntPtr LimitingJob(uint activeProcessLimit, ulong memoryLimit, bool killOnClose)
    {
        var job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject");
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION
            {
                LimitFlags = JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION
                    | (killOnClose ? JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE : 0),
                ActiveProcessLimit = activeProcessLimit,
            },
            ProcessMemoryLimit = (UIntPtr)memoryLimit,
        };
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()))
        {
            int err = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(err, "SetInformationJobObject");
        }
        return job;
    }

    /// <summary>
    /// Runs <paramref name="commandLine"/> to completion under the restricted token, inside a
    /// kill-on-close job, with the given std handles. Returns the child's exit code, or
    /// <c>null</c> when it exceeded <paramref name="timeout"/> (the job is then terminated).
    /// Nothing the child started survives the return: closing the job kills it.
    /// </summary>
    public static uint? RunToCompletion(string commandLine, SafeHandle stdin, SafeHandle stdout, SafeHandle stderr,
        TimeSpan timeout, uint activeProcessLimit, ulong memoryLimit)
    {
        PROCESS_INFORMATION pi = default;
        IntPtr token = IntPtr.Zero, job = IntPtr.Zero;
        try
        {
            token = RestrictedToken();
            job = LimitingJob(activeProcessLimit, memoryLimit, killOnClose: true);
            pi = Spawn(token, commandLine, stdin, stdout, stderr, suspended: true);
            if (!AssignProcessToJobObject(job, pi.hProcess))
            {
                int err = Marshal.GetLastWin32Error();
                TerminateProcess(pi.hProcess, 1);
                throw new Win32Exception(err, "AssignProcessToJobObject");
            }
            if (ResumeThread(pi.hThread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(), "ResumeThread");

            uint ms = (uint)Math.Clamp(timeout.TotalMilliseconds, 1, uint.MaxValue - 1);
            if (WaitForSingleObject(pi.hProcess, ms) == WAIT_TIMEOUT)
            {
                TerminateJobObject(job, 1);
                WaitForSingleObject(pi.hProcess, 5000);
                return null;
            }
            Check(GetExitCodeProcess(pi.hProcess, out uint code), "GetExitCodeProcess");
            return code;
        }
        finally
        {
            foreach (var h in new[] { pi.hProcess, pi.hThread, token, job })
            {
                if (h != IntPtr.Zero) CloseHandle(h);
            }
        }
    }

    public static void Check(bool ok, string what)
    {
        if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), what);
    }
}
