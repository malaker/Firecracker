using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace FcEgress;

internal static partial class Native
{
    public const uint HANDLE_FLAG_INHERIT = 1;
    public const int STARTF_USESTDHANDLES = 0x100;
    public const uint CREATE_SUSPENDED = 0x4;
    public const uint CREATE_NO_WINDOW = 0x08000000;
    public const uint CREATE_UNICODE_ENVIRONMENT = 0x400;
    public const int SAFER_SCOPEID_USER = 2;
    public const int SAFER_LEVELID_NORMALUSER = 0x20000;
    public const int SAFER_LEVEL_OPEN = 1;
    public const int TokenIntegrityLevelClass = 25;
    public const uint SE_GROUP_INTEGRITY = 0x20;
    public const int JobObjectExtendedLimitInformation = 9;
    public const uint JOB_OBJECT_LIMIT_ACTIVE_PROCESS = 0x8;
    public const uint JOB_OBJECT_LIMIT_PROCESS_MEMORY = 0x100;
    public const uint JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION = 0x400;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SID_AND_ATTRIBUTES
    {
        public IntPtr Sid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_MANDATORY_LABEL
    {
        public SID_AND_ATTRIBUTES Label;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetHandleInformation(SafeHandle handle, uint mask, uint flags);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetHandleInformation")]
    public static extern bool SetRawHandleInformation(IntPtr handle, uint mask, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int stdHandle);

    public const uint EXTENDED_STARTUPINFO_PRESENT = 0x80000;
    public static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST = new(0x20002);

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessW(string? app, System.Text.StringBuilder cmdLine, IntPtr procAttr, IntPtr threadAttr,
        bool inherit, uint flags, IntPtr env, string? cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessAsUserW(IntPtr token, string? app, System.Text.StringBuilder cmdLine, IntPtr procAttr,
        IntPtr threadAttr, bool inherit, uint flags, IntPtr env, string? cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size,
        IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    public static extern void DeleteProcThreadAttributeList(IntPtr list);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool SaferCreateLevel(int scopeId, int levelId, int openFlags, out IntPtr level, IntPtr reserved);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool SaferComputeTokenFromLevel(IntPtr level, IntPtr inToken, out IntPtr outToken, int flags, IntPtr reserved);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool SaferCloseLevel(IntPtr level);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool SetTokenInformation(IntPtr token, int infoClass, ref TOKEN_MANDATORY_LABEL info, int length);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returned);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ConvertStringSidToSidW(string sid, out IntPtr psid);

    [DllImport("advapi32.dll")]
    public static extern int GetLengthSid(IntPtr sid);

    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr mem);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateJobObjectW(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int length);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
}
