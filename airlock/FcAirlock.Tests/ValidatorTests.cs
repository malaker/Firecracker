using System.Formats.Tar;
using System.Security.Cryptography;
using System.Text;
using FcAirlock.Core;

namespace FcAirlock.Tests;

public class ValidatorTests
{
    private static (ValidationResult Result, byte[] Output) Validate(byte[] tar, Limits? limits = null)
    {
        var output = new MemoryStream();
        var r = Validator.Run(new MemoryStream(tar), output, limits ?? Limits.Default);
        return (r, output.ToArray());
    }

    private static List<ManifestEntry> Manifest(byte[] output, out long blobLength)
    {
        var (entries, blob) = AirlockFormat.ReadManifest(new MemoryStream(output), output.Length, Limits.Default);
        blobLength = blob;
        return entries;
    }

    [Theory]
    [InlineData(TarEntryFormat.V7)]
    [InlineData(TarEntryFormat.Ustar)]
    [InlineData(TarEntryFormat.Pax)]
    [InlineData(TarEntryFormat.Gnu)]
    public void RegularFilesAndDirectoriesPassInEveryFormat(TarEntryFormat format)
    {
        var b = new TarBuilder(format);
        if (format != TarEntryFormat.V7) b.Dir("./").Dir("./sub/");
        byte[] tar = b.File("./a.txt", "hello").File("./sub/b.bin", new byte[] { 1, 2, 3 }).Build();

        var (result, output) = Validate(tar);

        Assert.Equal(2, result.Files);
        Assert.Equal(8, result.Bytes);
        var entries = Manifest(output, out long blob);
        Assert.Equal(8, blob);
        var a = Assert.Single(entries, e => e.Path == "a.txt");
        Assert.Equal(0, a.Offset);
        Assert.Equal(5, a.Size);
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData("hello"u8)), a.Sha256);
        var bfile = Assert.Single(entries, e => e.Path == "sub/b.bin");
        Assert.Equal(5, bfile.Offset);
        Assert.Equal("hello\u0001\u0002\u0003", Encoding.Latin1.GetString(output, 0, 8));
        if (format != TarEntryFormat.V7) Assert.Contains(entries, e => e.Path == "sub" && e.Kind == EntryKind.Directory);
        Assert.DoesNotContain(entries, e => e.Path is "" or ".");
    }

    [Fact]
    public void LongNamesThroughPaxAndGnuExtensions()
    {
        string longName = string.Join('/', Enumerable.Repeat("directory-name", 12)) + "/file.txt";
        foreach (var format in new[] { TarEntryFormat.Pax, TarEntryFormat.Gnu })
        {
            var (_, output) = Validate(new TarBuilder(format).File(longName, "x").Build());
            Assert.Contains(Manifest(output, out _), e => e.Path == longName);
        }
    }

    [Fact]
    public void EmptyArchiveGivesEmptyManifest()
    {
        var (result, output) = Validate(new TarBuilder().Dir("./").Build());
        Assert.Equal(0, result.Files);
        Assert.Empty(Manifest(output, out long blob));
        Assert.Equal(0, blob);
    }

    public static TheoryData<string, Func<byte[]>, string> Refusals => new()
    {
        { "symlink", () => new TarBuilder().Link(TarEntryType.SymbolicLink, "./out/link", "/etc").Build(), "symbolic link is not allowed: './out/link'" },
        { "hardlink", () => new TarBuilder().File("./a", "x").Link(TarEntryType.HardLink, "./b", "./a").Build(), "hard link is not allowed: './b'" },
        { "char device", () => new TarBuilder(TarEntryFormat.Ustar).Special(TarEntryType.CharacterDevice, "./tty").Build(), "character device" },
        { "block device", () => new TarBuilder(TarEntryFormat.Ustar).Special(TarEntryType.BlockDevice, "./sda").Build(), "block device" },
        { "fifo", () => new TarBuilder(TarEntryFormat.Ustar).Special(TarEntryType.Fifo, "./pipe").Build(), "FIFO is not allowed: './pipe'" },
        { "gnu sparse", () => new TarBuilder().Raw('S', "./sparse", gnuMagic: true).BuildRaw(), "GNU sparse file" },
        { "pax sparse", () => new TarBuilder().PaxFile("./GNUSparseFile.0/s", [0], new() { ["GNU.sparse.major"] = "1", ["GNU.sparse.minor"] = "0" }).Build(), "sparse file is not allowed" },
        { "absolute path", () => new TarBuilder().Raw('0', "/etc/cron.d/evil", "x"u8.ToArray()).BuildRaw(), "absolute path: '/etc/cron.d/evil'" },
        { "parent path", () => new TarBuilder().File("../x", "x").Build(), "'..' path component: '../x'" },
        { "nested parent", () => new TarBuilder().File("./a/../../x", "x").Build(), "'..' path component" },
        { "reserved name", () => new TarBuilder().File("./con.txt", "x").Build(), "reserved device name 'con': 'con.txt'" },
        { "case collision", () => new TarBuilder().File("./Report.txt", "a").File("./report.txt", "b").Build(), "'Report.txt' and 'report.txt'" },
        { "global pax header", () => new TarBuilder().Raw('g', "./pax_global_header").BuildRaw(), "is not allowed" },
    };

    [Theory]
    [MemberData(nameof(Refusals))]
    public void HostileEntriesAreRefused(string _, Func<byte[]> tar, string reason)
    {
        var ex = Assert.Throws<RuleViolationException>(() => Validate(tar()));
        Assert.Contains(reason, ex.Message);
    }

    [Fact]
    public void OversizeFileIsRefused()
    {
        var limits = Limits.Default with { MaxFileBytes = 10, MaxTotalBytes = 100 };
        var ex = Assert.Throws<RuleViolationException>(() => Validate(new TarBuilder().File("./big", new byte[11]).Build(), limits));
        Assert.Contains("file larger than 10 bytes: 'big'", ex.Message);
    }

    [Fact]
    public void TooManyEntriesAreRefused()
    {
        var b = new TarBuilder();
        for (int i = 0; i < 4; i++) b.File($"./f{i}", "");
        var ex = Assert.Throws<RuleViolationException>(() => Validate(b.Build(), Limits.Default with { MaxEntries = 3 }));
        Assert.Contains("more than 3 entries", ex.Message);
    }

    [Fact]
    public void InputStreamCapIsEnforced()
    {
        // A tiny cap: total 10 bytes + 1536 per entry (1 entry) + 1 MiB is still far below a 2 MiB file.
        var limits = Limits.Default with { MaxTotalBytes = 10, MaxFileBytes = 10, MaxEntries = 1 };
        byte[] tar = new TarBuilder().File("./big", new byte[2 * 1024 * 1024]).Build();
        Assert.ThrowsAny<RuleViolationException>(() => Validate(tar, limits));
    }

    [Fact]
    public void TruncatedArchiveIsMalformed()
    {
        byte[] tar = new TarBuilder().File("./a.bin", new byte[4096]).Build();
        Assert.Throws<MalformedInputException>(() => Validate(tar[..(512 + 1000)]));
    }

    [Fact]
    public void GarbageIsMalformed()
    {
        var junk = new byte[1024];
        new Random(1).NextBytes(junk);
        Assert.Throws<MalformedInputException>(() => Validate(junk));
    }

    [Theory]
    [InlineData("./a/b", EntryKind.File, "a/b")]
    [InlineData("././a", EntryKind.File, "a")]
    [InlineData("./dir/", EntryKind.Directory, "dir")]
    [InlineData("./", EntryKind.Directory, null)]
    [InlineData(".", EntryKind.Directory, null)]
    [InlineData("plain", EntryKind.File, "plain")]
    public void NormalizesTarNames(string name, EntryKind kind, string? expected) =>
        Assert.Equal(expected, Validator.Normalize(name, kind));
}
