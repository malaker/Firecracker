using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace FcMcp;

/// <summary>A tool call was refused by server policy. The message is shown to the agent.</summary>
public sealed class PolicyException(string message) : Exception(message);

/// <summary>
/// Host path confinement (spec: Host path confinement; design D7). A path is accepted only when its
/// final path (after junctions and symbolic links) lies inside an allowed root, and neither it nor
/// anything below it is a reparse point.
/// </summary>
public sealed class PathPolicy
{
    private readonly List<string> _roots;

    public PathPolicy(IEnumerable<string> roots)
    {
        _roots = roots.Select(r => FinalPath(Path.GetFullPath(r))).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (_roots.Count == 0) throw new ArgumentException("at least one allowed root is required");
    }

    public IReadOnlyList<string> Roots => _roots;

    /// <summary>Returns the final path of <paramref name="path"/> or throws <see cref="PolicyException"/>.</summary>
    public string Check(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new PolicyException("a host path is required");
        string full = Path.GetFullPath(path);
        if (!File.Exists(full) && !Directory.Exists(full)) throw new PolicyException($"host path '{path}' does not exist");

        string final = FinalPath(full);
        if (!_roots.Any(r => IsInside(final, r)))
        {
            throw new PolicyException($"host path '{path}' is outside the allowed roots ({string.Join(", ", _roots)})");
        }
        if (IsReparsePoint(full)) throw new PolicyException($"host path '{path}' is a link or junction");
        if (Directory.Exists(full)) WalkForReparsePoints(full, path);
        return final;
    }

    internal static bool IsInside(string path, string root)
    {
        string r = root.TrimEnd(Path.DirectorySeparatorChar);
        return path.Equals(r, StringComparison.OrdinalIgnoreCase)
            || path.StartsWith(r + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsReparsePoint(string p) => File.GetAttributes(p).HasFlag(FileAttributes.ReparsePoint);

    private static void WalkForReparsePoints(string dir, string shown)
    {
        var pending = new Stack<string>();
        pending.Push(dir);
        var options = new EnumerationOptions { RecurseSubdirectories = false, AttributesToSkip = 0, IgnoreInaccessible = false };
        while (pending.Count > 0)
        {
            string d = pending.Pop();
            foreach (var info in new DirectoryInfo(d).EnumerateFileSystemInfos("*", options))
            {
                if (info.Attributes.HasFlag(FileAttributes.ReparsePoint))
                {
                    throw new PolicyException($"'{shown}' contains a link or junction: '{Path.GetRelativePath(dir, info.FullName)}'");
                }
                if (info is DirectoryInfo) pending.Push(info.FullName);
            }
        }
    }

    /// <summary>The path with every junction and symbolic link resolved (GetFinalPathNameByHandle).</summary>
    internal static string FinalPath(string full)
    {
        using SafeFileHandle h = CreateFileW(full, 0, FileShare.ReadWrite | FileShare.Delete, IntPtr.Zero, FileMode.Open, FileFlagBackupSemantics, IntPtr.Zero);
        if (h.IsInvalid) throw new PolicyException($"cannot open host path '{full}': {new Win32Exception(Marshal.GetLastWin32Error()).Message}");
        var buf = new char[32768];
        uint n = GetFinalPathNameByHandleW(h, buf, (uint)buf.Length, 0);
        if (n == 0 || n >= buf.Length) throw new Win32Exception(Marshal.GetLastWin32Error());
        string s = new(buf, 0, (int)n);
        if (s.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + s[8..];
        if (s.StartsWith(@"\\?\", StringComparison.Ordinal)) return s[4..];
        return s;
    }

    private const int FileFlagBackupSemantics = 0x02000000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, FileShare share, IntPtr security,
        FileMode mode, int flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, [Out] char[] buf, uint len, uint flags);
}
