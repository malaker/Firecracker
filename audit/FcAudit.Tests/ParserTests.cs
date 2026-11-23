using System.Text;
using FcAudit.Core;

namespace FcAudit.Tests;

public sealed class ParserTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("fc-audit-parse-").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private string Write(string name, string text, Encoding enc)
    {
        string p = Path.Combine(_dir, name);
        File.WriteAllText(p, text, enc);
        return p;
    }

    private static InputText Lines(params string[] lines) => new(InputStatus.Ok, lines, 0);

    // ---------- input files ----------

    [Fact]
    public void MissingFileIsReportedAsMissing()
    {
        var t = InputText.Read(Path.Combine(_dir, "nope.txt"), InputText.Utf8);
        Assert.Equal(InputStatus.Missing, t.Status);
    }

    [Fact]
    public void OversizedFileIsRefusedNotTruncated()
    {
        string p = Write("big.txt", new string('x', 2000), InputText.Utf8);
        var t = InputText.Read(p, InputText.Utf8, maxBytes: 1000);
        Assert.Equal(InputStatus.TooLarge, t.Status);
        Assert.Empty(t.Lines);
        Assert.Equal(2000, t.Bytes);
    }

    [Fact]
    public void Utf16RegExportIsDecodedFromItsBom()
    {
        string p = Write("r.reg", "Windows Registry Editor Version 5.00\r\n\r\n[HKEY_CURRENT_USER\\Ünï]\r\n", new UnicodeEncoding(false, true));
        var t = InputText.Read(p, InputText.Utf16);
        Assert.Contains("[HKEY_CURRENT_USER\\Ünï]", t.Lines);
    }

    // ---------- file listings ----------

    [Fact]
    public void FileDiffFindsCreatedAndDeletedAndIgnoresWorkAndCase()
    {
        var before = Lines(@"C:\Windows", @"C:\Users\Public\old.txt", @"C:\Users");
        var after = Lines(@"C:\WINDOWS", @"C:\Users", @"C:\Users\Public\x.dll", @"C:\work\out\video.mp4", @"C:\work");
        var c = FileSnapshot.Compare(before, after);
        Assert.True(c.Compared);
        Assert.Equal(new[] { @"C:\Users\Public\x.dll" }, c.Created);
        Assert.Equal(new[] { @"C:\Users\Public\old.txt" }, c.Deleted);
    }

    [Fact]
    public void WorkPrefixDoesNotSwallowSimilarNames()
    {
        var c = FileSnapshot.Compare(Lines(), Lines(@"C:\workspace\a.txt"));
        Assert.Equal(new[] { @"C:\workspace\a.txt" }, c.Created);
    }

    [Fact]
    public void MissingListingMeansNotCompared()
    {
        var c = FileSnapshot.Compare(Lines(@"C:\a"), InputText.Missing);
        Assert.False(c.Compared);
        Assert.Equal(InputStatus.Missing, c.After);
        Assert.Null(c.Created);
    }

    // ---------- registry ----------

    private const string Header = "Windows Registry Editor Version 5.00";

    [Fact]
    public void MultiLineHexValueIsJoined()
    {
        var entries = RegistrySnapshot.Parse(new[]
        {
            Header, "",
            @"[HKEY_LOCAL_MACHINE\SOFTWARE\X]",
            "\"Blob\"=hex:51,00,00,\\",
            "  f2,3f,7e,\\",
            "  01",
            "\"After\"=dword:00000001",
        });
        Assert.Equal(3, entries.Count);
        Assert.Equal("hex:51,00,00,f2,3f,7e,01", entries[1].Data);
        Assert.Equal("\"After\"", entries[2].Name);
    }

    [Fact]
    public void StringEndingInEscapedBackslashIsNotAContinuation()
    {
        var entries = RegistrySnapshot.Parse(new[] { @"[HKEY_CURRENT_USER\K]", "\"Path\"=\"C:\\\\dir\\\\\"", "\"Next\"=\"v\"" });
        Assert.Equal(3, entries.Count);
        Assert.Equal("\"C:\\\\dir\\\\\"", entries[1].Data);
    }

    [Fact]
    public void KeyWithNoValuesIsKeptAsAKey()
    {
        var entries = RegistrySnapshot.Parse(new[] { Header, @"[HKEY_CURRENT_USER\Empty]", "", @"[HKEY_CURRENT_USER\Other]" });
        Assert.Equal(2, entries.Count);
        Assert.True(entries[0].IsKey);
        Assert.Equal(@"HKEY_CURRENT_USER\Empty", entries[0].Key);
    }

    [Fact]
    public void ValueNamesWithEscapedQuotesAndDefaultValueParse()
    {
        var entries = RegistrySnapshot.Parse(new[] { @"[HKEY_CURRENT_USER\K]", "\"a \\\"q\\\" b\"=\"1\"", "@=\"default\"" });
        Assert.Equal("\"a \"q\" b\"", entries[1].Name);
        Assert.Equal("@", entries[2].Name);
        Assert.Equal("\"default\"", entries[2].Data);
    }

    [Fact]
    public void RunKeyValueIsAddedAndChangedValueIsAChange()
    {
        var before = Lines(Header, @"[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run]",
            @"[HKEY_CURRENT_USER\Soft]", "\"a\"=\"1\"", "\"gone\"=\"x\"");
        var after = Lines(Header, @"[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run]",
            "\"evil\"=\"C:\\\\Users\\\\Public\\\\x.exe\"",
            @"[HKEY_CURRENT_USER\Soft]", "\"A\"=\"2\"", @"[HKEY_CURRENT_USER\New]");
        var c = RegistrySnapshot.Compare("HKCU", before, after);
        Assert.True(c.Compared);
        Assert.Collection(c.Added!,
            e => Assert.Equal("\"evil\"", e.Name),
            e => { Assert.True(e.IsKey); Assert.Equal(@"HKEY_CURRENT_USER\New", e.Key); });
        var ch = Assert.Single(c.Changed!);
        Assert.Equal("\"1\"", ch.OldData);
        Assert.Equal("\"2\"", ch.NewData);
        Assert.Equal("\"gone\"", Assert.Single(c.Removed!).Name);
        Assert.Equal(4, c.Count);
    }

    [Fact]
    public void MissingExportMeansNotCompared()
    {
        var c = RegistrySnapshot.Compare("HKLM\\SOFTWARE", InputText.Missing, Lines(Header));
        Assert.False(c.Compared);
        Assert.Equal(InputStatus.Missing, c.Before);
    }

    // ---------- net.log ----------

    [Fact]
    public void NetLogGroupsByHostPortDecisionInFirstSeenOrder()
    {
        var log = Lines(
            "2026-11-04T21:17:45.495Z event=start detail=run_id=x_allow=",
            "2026-11-04T21:17:46.082Z decision=denied host=fc-egress.invalid port=80 ip=- reason=sentinel bytes_up=0 bytes_down=0",
            "2026-11-04T21:17:47Z decision=allowed host=example.com port=443 ip=93.184.216.34 reason=public bytes_up=1200 bytes_down=50000",
            "2026-11-04T21:17:48Z decision=denied host=192.168.1.1 port=80 ip=192.168.1.1 reason=private bytes_up=0 bytes_down=0",
            "2026-11-04T21:17:49Z decision=allowed host=EXAMPLE.com port=443 ip=93.184.216.35 reason=public bytes_up=800 bytes_down=10000",
            "2026-11-04T21:17:50Z event=stop detail=channel_closed");
        var s = NetLog.Summarize(log);
        Assert.Equal(2, s.Destinations.Count);
        var ex = s.Destinations[0];
        Assert.Equal(("example.com", 443, "allowed", 2), (ex.Host, ex.Port, ex.Decision, ex.Attempts));
        Assert.Equal(new[] { "93.184.216.34", "93.184.216.35" }, ex.Addresses);
        Assert.Equal((2000L, 60000L), (ex.BytesUp, ex.BytesDown));
        Assert.Equal("2026-11-04T21:17:47Z", ex.FirstSeen);
        var lan = s.Destinations[1];
        Assert.Equal(("192.168.1.1", 80, "denied", 1), (lan.Host, lan.Port, lan.Decision, lan.Attempts));
        Assert.Equal(new[] { "private" }, lan.Reasons);
    }

    [Fact]
    public void MalformedNetLogLinesAreCountedNotFatal()
    {
        var s = NetLog.Summarize(Lines("t decision=allowed host=a port=notanumber", "t decision=allowed port=1", "garbage"));
        Assert.Empty(s.Destinations);
        Assert.Equal(2, s.SkippedLines);
    }

    [Fact]
    public void MissingNetLogIsReported()
    {
        Assert.Equal(InputStatus.Missing, NetLog.Summarize(InputText.Missing).Status);
    }
}
