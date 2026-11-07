using FcAirlock.Core;

namespace FcAirlock.Tests;

public class RulesTests
{
    private static readonly Limits L = Limits.Default;

    [Theory]
    [InlineData("report.txt")]
    [InlineData("sub/dir/file.bin")]
    [InlineData("console.txt")]       // starts with "con" but is not the device name
    [InlineData("COM10")]             // only COM1-COM9 are reserved
    [InlineData(".hidden")]
    [InlineData("name with spaces.txt")]
    [InlineData("été.txt")]
    public void SafePathsPass(string path) => Rules.CheckPath(path, L);

    [Theory]
    [InlineData("con.txt", "reserved device name")]
    [InlineData("CON", "reserved device name")]
    [InlineData("dir/COM1", "reserved device name")]
    [InlineData("lpt9.log", "reserved device name")]
    [InlineData("NUL .txt", "reserved device name")]
    [InlineData("com¹", "reserved device name")]
    [InlineData("CONOUT$", "reserved device name")]
    [InlineData("file.", "dot or space")]
    [InlineData("file ", "dot or space")]
    [InlineData("a:b", "':'")]
    [InlineData("a\\b", "'\\'")]
    [InlineData("what?", "'?'")]
    [InlineData("tab\there", "control character")]
    [InlineData("/etc/passwd", "absolute path")]
    [InlineData("../escape.txt", "'..' path component")]
    [InlineData("a/../b", "'..' path component")]
    [InlineData("a/./b", "'.' path component")]
    [InlineData("a//b", "empty path component")]
    [InlineData("", "empty path")]
    public void UnsafePathsAreRefused(string path, string reason)
    {
        var ex = Assert.Throws<RuleViolationException>(() => Rules.CheckPath(path, L));
        Assert.Contains(reason, ex.Message);
    }

    [Fact]
    public void DepthLimit()
    {
        string ok = string.Join('/', Enumerable.Repeat("d", 64));
        Rules.CheckPath(ok, L);
        string tooDeep = string.Join('/', Enumerable.Repeat("d", 65));
        Assert.Contains("deeper than 64", Assert.Throws<RuleViolationException>(() => Rules.CheckPath(tooDeep, L)).Message);
    }

    [Fact]
    public void PathLengthLimit()
    {
        string tooLong = string.Join('/', Enumerable.Repeat(new string('x', 100), 6));
        Assert.Contains("longer than 512", Assert.Throws<RuleViolationException>(() => Rules.CheckPath(tooLong, L)).Message);
    }

    [Fact]
    public void ComponentLengthLimit()
    {
        Assert.Contains("longer than 255", Assert.Throws<RuleViolationException>(() => Rules.CheckPath(new string('x', 256), L)).Message);
    }

    [Fact]
    public void CaseCollisionNamesBothPaths()
    {
        var c = new TransferChecker(L);
        c.Add("Report.txt", EntryKind.File, 1);
        var ex = Assert.Throws<RuleViolationException>(() => c.Add("report.txt", EntryKind.File, 1));
        Assert.Contains("'Report.txt'", ex.Message);
        Assert.Contains("'report.txt'", ex.Message);
    }

    [Fact]
    public void DuplicateFileIsRefused()
    {
        var c = new TransferChecker(L);
        c.Add("a.txt", EntryKind.File, 1);
        Assert.Throws<RuleViolationException>(() => c.Add("a.txt", EntryKind.File, 1));
    }

    [Fact]
    public void FileUnderAFileIsRefused()
    {
        var c = new TransferChecker(L);
        c.Add("a", EntryKind.File, 1);
        Assert.Throws<RuleViolationException>(() => c.Add("A/b", EntryKind.File, 1));
    }

    [Fact]
    public void FileOverADirectoryIsRefused()
    {
        var c = new TransferChecker(L);
        c.Add("dir/x", EntryKind.File, 1);
        Assert.Throws<RuleViolationException>(() => c.Add("DIR", EntryKind.File, 1));
    }

    [Fact]
    public void RepeatedDirectoriesAreFine()
    {
        var c = new TransferChecker(L);
        c.Add("dir", EntryKind.Directory, 0);
        c.Add("dir/x", EntryKind.File, 1);
        c.Add("Dir", EntryKind.Directory, 0);
        Assert.Equal(1, c.Files);
    }

    [Fact]
    public void EntryLimit()
    {
        var c = new TransferChecker(L with { MaxEntries = 3 });
        c.Add("a", EntryKind.File, 0);
        c.Add("b", EntryKind.File, 0);
        c.Add("c", EntryKind.Directory, 0);
        Assert.Contains("more than 3 entries", Assert.Throws<RuleViolationException>(() => c.Add("d", EntryKind.File, 0)).Message);
    }

    [Fact]
    public void FileAndTotalByteLimits()
    {
        var c = new TransferChecker(L with { MaxFileBytes = 10, MaxTotalBytes = 15 });
        Assert.Contains("file larger than 10", Assert.Throws<RuleViolationException>(() => c.Add("big", EntryKind.File, 11)).Message);
        c.Add("a", EntryKind.File, 10);
        Assert.Contains("transfer larger than 15", Assert.Throws<RuleViolationException>(() => c.Add("b", EntryKind.File, 6)).Message);
    }

    [Fact]
    public void DefaultLimitsMatchTheSpec()
    {
        Assert.Equal(Limits.GiB, L.MaxTotalBytes);
        Assert.Equal(Limits.GiB, L.MaxFileBytes);
        Assert.Equal(10_000, L.MaxEntries);
        Assert.Equal(512, L.MaxPathChars);
        Assert.Equal(64, L.MaxDepth);
    }

    [Fact]
    public void TestOverrideCanLowerByteLimits()
    {
        var l = Limits.FromEnvironment(_ => "4096");
        Assert.Equal(4096, l.MaxTotalBytes);
        Assert.Equal(4096, l.MaxFileBytes);
    }

    [Theory]
    [InlineData("2147483648")]  // 2 GiB, above the default
    [InlineData("1073741824")]  // equal to the default
    [InlineData("0")]
    [InlineData("-5")]
    [InlineData("12k")]
    [InlineData(null)]
    public void TestOverrideCannotRaiseOrBreakLimits(string? value)
    {
        Assert.Equal(Limits.Default, Limits.FromEnvironment(_ => value));
    }

    [Fact]
    public void PrintableEscapesControlCharacters()
    {
        Assert.Equal("a\\x1bb", Rules.Printable("a\u001bb"));
    }
}
