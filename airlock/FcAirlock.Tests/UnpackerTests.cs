using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using FcAirlock.Core;

namespace FcAirlock.Tests;

public sealed class UnpackerTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("fc-airlock-test-").FullName;
    private string Staging => Path.Combine(_dir, "staging");
    private string Input => Path.Combine(_dir, "airlock.out");

    public UnpackerTests() => Directory.CreateDirectory(Staging);

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private static string Sha(byte[] b) => Convert.ToHexStringLower(SHA256.HashData(b));

    private void WriteOutput(byte[] blob, IReadOnlyList<ManifestEntry> entries)
    {
        using var fs = File.Create(Input);
        fs.Write(blob);
        AirlockFormat.WriteTrailer(fs, AirlockFormat.WriteManifest(entries));
    }

    private ValidationResult Unpack(Limits? limits = null) => Unpacker.Run(Input, Staging, limits ?? Limits.Default);

    private void AssertStagingEmpty() => Assert.Empty(Directory.EnumerateFileSystemEntries(Staging));

    [Fact]
    public void RoundTripFromValidator()
    {
        byte[] tar = new TarBuilder().Dir("./").Dir("./sub/").Dir("./empty/")
            .File("./a.txt", "hello").File("./sub/b.bin", new byte[] { 0, 255 }).File("./zero", "").Build();
        using (var fs = File.Create(Input)) Validator.Run(new MemoryStream(tar), fs, Limits.Default);

        var r = Unpack();

        Assert.Equal(3, r.Files);
        Assert.Equal(7, r.Bytes);
        Assert.Equal("hello", File.ReadAllText(Path.Combine(Staging, "a.txt")));
        Assert.Equal(new byte[] { 0, 255 }, File.ReadAllBytes(Path.Combine(Staging, "sub", "b.bin")));
        Assert.Equal(0, new FileInfo(Path.Combine(Staging, "zero")).Length);
        Assert.True(Directory.Exists(Path.Combine(Staging, "empty")));
    }

    [Fact]
    public void HashMismatchIsRefusedAndNothingSurvives()
    {
        byte[] a = "aaaa"u8.ToArray(), b = "bbbb"u8.ToArray();
        WriteOutput([.. a, .. b], [
            new("a", EntryKind.File, 0, 4, Sha(a)),
            new("b", EntryKind.File, 4, 4, Sha("tampered"u8.ToArray())),
        ]);
        Assert.Contains("hash mismatch for 'b'", Assert.Throws<RuleViolationException>(() => Unpack()).Message);
        AssertStagingEmpty();
    }

    [Fact]
    public void OverlappingRangesAreRefused()
    {
        byte[] blob = "abcdef"u8.ToArray();
        WriteOutput(blob, [
            new("x", EntryKind.File, 0, 4, Sha(blob[..4])),
            new("y", EntryKind.File, 2, 4, Sha(blob[2..])),
        ]);
        Assert.Contains("overlapping", Assert.Throws<RuleViolationException>(() => Unpack()).Message);
        AssertStagingEmpty();
    }

    [Fact]
    public void RangePastTheEndIsRefused()
    {
        byte[] blob = "abc"u8.ToArray();
        WriteOutput(blob, [new("x", EntryKind.File, 0, 30, Sha(blob))]);
        Assert.Contains("past the end", Assert.Throws<RuleViolationException>(() => Unpack()).Message);
        AssertStagingEmpty();
    }

    [Fact]
    public void UndescribedBlobDataIsRefused()
    {
        byte[] blob = "abcdef"u8.ToArray();
        WriteOutput(blob, [new("x", EntryKind.File, 0, 3, Sha(blob[..3]))]);
        Assert.Contains("not described", Assert.Throws<RuleViolationException>(() => Unpack()).Message);
    }

    [Fact]
    public void UnsafePathInOtherwiseValidManifestIsRefused()
    {
        byte[] blob = "x"u8.ToArray();
        WriteOutput(blob, [new("../escape.txt", EntryKind.File, 0, 1, Sha(blob))]);
        Assert.Contains("'..' path component", Assert.Throws<RuleViolationException>(() => Unpack()).Message);
        AssertStagingEmpty();
        Assert.False(File.Exists(Path.Combine(_dir, "escape.txt")));
    }

    [Theory]
    [InlineData("con.txt")]
    [InlineData("/abs")]
    [InlineData("a:stream")]
    public void HostRulesApplyToManifestPaths(string path)
    {
        byte[] blob = "x"u8.ToArray();
        WriteOutput(blob, [new(path, EntryKind.File, 0, 1, Sha(blob))]);
        Assert.Throws<RuleViolationException>(() => Unpack());
        AssertStagingEmpty();
    }

    [Fact]
    public void CaseCollisionInManifestIsRefused()
    {
        byte[] blob = "xy"u8.ToArray();
        WriteOutput(blob, [
            new("Report.txt", EntryKind.File, 0, 1, Sha(blob[..1])),
            new("report.txt", EntryKind.File, 1, 1, Sha(blob[1..])),
        ]);
        Assert.Throws<RuleViolationException>(() => Unpack());
        AssertStagingEmpty();
    }

    [Fact]
    public void BadMagicIsMalformed()
    {
        WriteOutput("abc"u8.ToArray(), []);
        byte[] all = File.ReadAllBytes(Input);
        all[^1] = (byte)'X';
        File.WriteAllBytes(Input, all);
        Assert.Contains("trailer", Assert.Throws<MalformedInputException>(() => Unpack()).Message);
    }

    [Fact]
    public void TooShortIsMalformed()
    {
        File.WriteAllBytes(Input, [1, 2, 3]);
        Assert.Throws<MalformedInputException>(() => Unpack());
    }

    [Fact]
    public void OversizedManifestLengthIsMalformed()
    {
        var trailer = new byte[16];
        BinaryPrimitives.WriteUInt64LittleEndian(trailer, 17UL * 1024 * 1024);
        Encoding.ASCII.GetBytes("FCALOCK1").CopyTo(trailer, 8);
        File.WriteAllBytes(Input, trailer);
        Assert.Contains("manifest larger than", Assert.Throws<MalformedInputException>(() => Unpack()).Message);
    }

    [Fact]
    public void ManifestLengthBeyondFileIsMalformed()
    {
        var trailer = new byte[16];
        BinaryPrimitives.WriteUInt64LittleEndian(trailer, 1000);
        Encoding.ASCII.GetBytes("FCALOCK1").CopyTo(trailer, 8);
        File.WriteAllBytes(Input, trailer);
        Assert.Throws<MalformedInputException>(() => Unpack());
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("{\"version\":2,\"entries\":[]}")]
    [InlineData("{\"version\":1}")]
    [InlineData("{\"version\":1,\"entries\":[{\"path\":\"a\",\"type\":\"file\",\"offset\":0,\"size\":0,\"sha256\":\"zz\"}]}")]
    [InlineData("{\"version\":1,\"entries\":[{\"path\":\"a\",\"type\":\"file\",\"offset\":\"0\",\"size\":0,\"sha256\":\"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\"}]}")]
    [InlineData("{\"version\":1,\"entries\":[[[[[]]]]]}")]
    public void BrokenManifestsAreMalformed(string json)
    {
        byte[] m = Encoding.UTF8.GetBytes(json);
        using (var fs = File.Create(Input)) AirlockFormat.WriteTrailer(fs, m);
        Assert.Throws<MalformedInputException>(() => Unpack());
    }

    [Fact]
    public void LinkTypeInManifestIsRefused()
    {
        byte[] m = Encoding.UTF8.GetBytes("{\"version\":1,\"entries\":[{\"path\":\"l\",\"type\":\"symlink\"}]}");
        using (var fs = File.Create(Input)) AirlockFormat.WriteTrailer(fs, m);
        Assert.Contains("entry type 'symlink' is not allowed", Assert.Throws<RuleViolationException>(() => Unpack()).Message);
    }

    [Fact]
    public void OutputOverStreamCapIsRefused()
    {
        var limits = Limits.Default with { MaxTotalBytes = 1, MaxEntries = 1 };
        File.WriteAllBytes(Input, new byte[limits.StreamCap + 1]);
        Assert.Throws<RuleViolationException>(() => Unpack(limits));
    }

    [Fact]
    public void NonEmptyStagingIsRejected()
    {
        WriteOutput([], []);
        File.WriteAllText(Path.Combine(Staging, "left-over"), "x");
        Assert.Throws<InvalidOperationException>(() => Unpack());
    }
}
