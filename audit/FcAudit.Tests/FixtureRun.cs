using System.Text;

namespace FcAudit.Tests;

/// <summary>
/// A run folder shaped like a real Windows audit run (runs\&lt;id&gt; with net.log, exit_code and
/// out\_audit\), built in a temp folder so the UTF-16 exports never pass through git's text handling.
/// </summary>
internal sealed class FixtureRun : IDisposable
{
    public string Dir { get; } = Directory.CreateTempSubdirectory("fc-audit-run-").FullName;
    public string Audit => Path.Combine(Dir, "out", "_audit");

    private const string RegHeader = "Windows Registry Editor Version 5.00\r\n\r\n";

    public FixtureRun()
    {
        Directory.CreateDirectory(Audit);
        File.WriteAllText(Path.Combine(Dir, "exit_code"), "1\n");
    }

    public void Dispose() => Directory.Delete(Dir, recursive: true);

    public FixtureRun Txt(string name, params string[] lines)
    {
        File.WriteAllText(Path.Combine(Audit, name), string.Join("\r\n", lines) + "\r\n", new UTF8Encoding(false));
        return this;
    }

    public FixtureRun Reg(string name, string body)
    {
        File.WriteAllText(Path.Combine(Audit, name), RegHeader + body.Replace("\n", "\r\n"), new UnicodeEncoding(false, true));
        return this;
    }

    public FixtureRun NetLog(params string[] lines)
    {
        File.WriteAllText(Path.Combine(Dir, "net.log"), string.Join("\n", lines) + "\n", new UTF8Encoding(false));
        return this;
    }

    public FixtureRun Output(string rel, string content)
    {
        string p = Path.Combine(Dir, "out", rel);
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.WriteAllText(p, content);
        return this;
    }

    /// <summary>The standard fixture: a program that downloads a page, drops a DLL and adds a Run key.</summary>
    public static FixtureRun Standard()
    {
        var f = new FixtureRun();
        f.Txt("fs-before.txt", @"C:\Users", @"C:\Users\Public", @"C:\Windows", @"C:\work", @"C:\work\in", @"C:\Users\Public\old.log");
        f.Txt("fs-after.txt", @"C:\Users", @"C:\Users\Public", @"C:\Windows", @"C:\work", @"C:\work\in", @"C:\work\out\page.html",
            @"C:\Users\Public\x.dll", @"C:\Users\Public\we`ird|name.txt");
        f.Reg("hklm-before.reg",
            "[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Notifications\\Data]\n" +
            "\"418A073AA3BC1C75\"=hex:50,00,00,00,\\\n  01,02\n\n");
        f.Reg("hklm-after.reg",
            "[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Notifications\\Data]\n" +
            "\"418A073AA3BC1C75\"=hex:51,00,00,00,\\\n  01,02\n\n");
        f.Reg("hkcu-before.reg",
            "[HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run]\n\n");
        f.Reg("hkcu-after.reg",
            "[HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run]\n" +
            "\"Updater\"=\"C:\\\\Users\\\\Public\\\\x.dll\"\n\n" +
            "[HKEY_CURRENT_USER\\Software\\FcAuditProbe]\n\"x\"=\"1\"\n\n");
        f.NetLog(
            "2026-11-23T20:03:28.040Z event=start detail=run_id=20261123-200325-dc3b_allow=",
            "2026-11-23T20:03:28.565Z decision=denied host=fc-egress.invalid port=80 ip=- reason=sentinel bytes_up=0 bytes_down=0",
            "2026-11-23T20:03:33.815Z decision=allowed host=www.youtube.com port=443 ip=142.251.150.4 reason=public bytes_up=4424 bytes_down=107912",
            "2026-11-23T20:03:34.100Z decision=denied host=192.168.1.1 port=80 ip=192.168.1.1 reason=private bytes_up=0 bytes_down=0",
            "2026-11-23T20:03:35.000Z decision=allowed host=www.youtube.com port=443 ip=142.251.150.5 reason=public bytes_up=100 bytes_down=200",
            "2026-11-23T20:03:36.023Z event=stop detail=channel_closed");
        f.Output("page.html", "<html>hi</html>");
        return f;
    }
}
