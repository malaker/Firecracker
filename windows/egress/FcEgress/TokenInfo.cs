using System.Runtime.InteropServices;
using System.Security.Principal;

namespace FcEgress;

// Describes the current process token, so 'serve' can report (and refuse to run with) admin rights.
internal static class TokenInfo
{
    private const int TokenElevation = 20;
    private const int TokenIntegrityLevel = 25;

    public static bool IsElevated()
    {
        using var id = WindowsIdentity.GetCurrent();
        var buf = Marshal.AllocHGlobal(4);
        try
        {
            return Native.GetTokenInformation(id.Token, TokenElevation, buf, 4, out _) && Marshal.ReadInt32(buf) != 0;
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    public static bool IsAdministrator()
    {
        using var id = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }

    public static string IntegrityLevel()
    {
        using var id = WindowsIdentity.GetCurrent();
        Native.GetTokenInformation(id.Token, TokenIntegrityLevel, IntPtr.Zero, 0, out int size);
        var buf = Marshal.AllocHGlobal(size);
        try
        {
            if (!Native.GetTokenInformation(id.Token, TokenIntegrityLevel, buf, size, out _)) return "unknown";
            var sid = new SecurityIdentifier(Marshal.ReadIntPtr(buf));
            return sid.Value switch
            {
                "S-1-16-4096" => "Low",
                "S-1-16-8192" => "Medium",
                "S-1-16-8448" => "MediumPlus",
                "S-1-16-12288" => "High",
                "S-1-16-16384" => "System",
                var v => v,
            };
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    // Names of the privileges present in the token (enabled or not).
    public static IReadOnlyList<string> Privileges()
    {
        using var id = WindowsIdentity.GetCurrent();
        Native.GetTokenInformation(id.Token, TokenPrivileges, IntPtr.Zero, 0, out int size);
        var buf = Marshal.AllocHGlobal(size);
        try
        {
            if (!Native.GetTokenInformation(id.Token, TokenPrivileges, buf, size, out _)) return [];
            int count = Marshal.ReadInt32(buf);
            var names = new List<string>(count);
            for (int i = 0; i < count; i++)
            {
                // LUID_AND_ATTRIBUTES is 12 bytes, after the 4-byte count.
                long luid = Marshal.ReadInt64(buf, 4 + i * 12);
                var sb = new System.Text.StringBuilder(64);
                int len = sb.Capacity;
                names.Add(LookupPrivilegeNameW(null, ref luid, sb, ref len) ? sb.ToString() : $"luid:{luid}");
            }
            return names;
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    private const int TokenPrivileges = 3;

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeNameW(string? system, ref long luid, System.Text.StringBuilder name, ref int length);

    // Privileges a standard (non-admin) user token may hold.
    private static readonly HashSet<string> StandardUserPrivileges = new(StringComparer.Ordinal)
    {
        "SeChangeNotifyPrivilege", "SeShutdownPrivilege", "SeUndockPrivilege", "SeIncreaseWorkingSetPrivilege", "SeTimeZonePrivilege",
    };

    // TokenElevation stays "elevated" for a Safer NORMALUSER token derived from an elevated
    // one, so judge by what the token can actually do instead.
    public static bool HasAdminRights(out string why)
    {
        if (IsAdministrator())
        {
            why = "Administrators group is enabled";
            return true;
        }
        string integrity = IntegrityLevel();
        if (integrity is not ("Low" or "Medium"))
        {
            why = $"integrity level is {integrity}";
            return true;
        }
        var extra = Privileges().Where(p => !StandardUserPrivileges.Contains(p)).ToArray();
        if (extra.Length > 0)
        {
            why = $"token holds {string.Join(',', extra)}";
            return true;
        }
        why = "";
        return false;
    }

    public static string Describe() =>
        $"user={WindowsIdentity.GetCurrent().Name} elevated={IsElevated()} administrator={IsAdministrator()} " +
        $"integrity={IntegrityLevel()} privileges={string.Join(',', Privileges())}";
}
