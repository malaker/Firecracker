using System.Security.Cryptography;

namespace FcAirlock.Core;

/// <summary>
/// Runs on the host (design D3/D4 step 7): reads an airlock output file, applies every rule again
/// independently of the airlock, checks byte ranges and SHA-256 hashes, and writes the files into
/// an empty staging folder. On any failure the staging folder is emptied again, so nothing of a
/// refused transfer survives. Moving staging into the destination is the controller's job.
/// </summary>
public static class Unpacker
{
    public static ValidationResult Run(string inputPath, string stagingDir, Limits limits)
    {
        string staging = Path.GetFullPath(stagingDir);
        if (!Directory.Exists(staging)) throw new InvalidOperationException($"staging folder '{staging}' does not exist");
        if (Directory.EnumerateFileSystemEntries(staging).Any()) throw new InvalidOperationException($"staging folder '{staging}' is not empty");

        try
        {
            using var input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
            long length = input.Length;
            if (length > limits.StreamCap) throw new RuleViolationException($"airlock output is larger than the {limits.StreamCap}-byte cap");

            var (entries, blobLength) = AirlockFormat.ReadManifest(input, length, limits);
            var checker = CheckEntries(entries, blobLength, limits);
            Write(input, entries, staging);
            return new ValidationResult(checker.Files, checker.TotalBytes);
        }
        catch
        {
            Empty(staging);
            throw;
        }
    }

    /// <summary>Rules plus range checks: file data must be contiguous, in manifest order, and end where the manifest starts.</summary>
    internal static TransferChecker CheckEntries(IReadOnlyList<ManifestEntry> entries, long blobLength, Limits limits)
    {
        var checker = new TransferChecker(limits);
        long expected = 0;
        foreach (var e in entries)
        {
            checker.Add(e.Path, e.Kind, e.Size);
            if (e.Kind != EntryKind.File) continue;
            if (e.Offset != expected) throw new RuleViolationException($"file data out of order or overlapping at '{Rules.Printable(e.Path)}'");
            if (e.Size > blobLength - expected) throw new RuleViolationException($"file data past the end of the blob: '{Rules.Printable(e.Path)}'");
            expected += e.Size;
        }
        if (expected != blobLength) throw new RuleViolationException("blob contains data not described by the manifest");
        return checker;
    }

    private static void Write(FileStream input, IReadOnlyList<ManifestEntry> entries, string staging)
    {
        byte[] buffer = new byte[81920];
        string root = staging.EndsWith(Path.DirectorySeparatorChar) ? staging : staging + Path.DirectorySeparatorChar;
        foreach (var e in entries)
        {
            string target = Path.GetFullPath(Path.Combine(staging, e.Path.Replace('/', Path.DirectorySeparatorChar)));
            // Defence in depth: the rules already exclude anything that could leave staging.
            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new RuleViolationException($"path leaves the destination: '{Rules.Printable(e.Path)}'");

            if (e.Kind == EntryKind.Directory)
            {
                Directory.CreateDirectory(target);
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16))
            {
                input.Position = e.Offset;
                long left = e.Size;
                while (left > 0)
                {
                    int n = input.Read(buffer, 0, (int)Math.Min(buffer.Length, left));
                    if (n == 0) throw new MalformedInputException($"airlock output ends inside '{Rules.Printable(e.Path)}'");
                    hash.AppendData(buffer, 0, n);
                    output.Write(buffer, 0, n);
                    left -= n;
                }
            }
            if (AirlockFormat.ToHex(hash.GetHashAndReset()) != e.Sha256) throw new RuleViolationException($"hash mismatch for '{Rules.Printable(e.Path)}'");
        }
    }

    private static void Empty(string staging)
    {
        if (!Directory.Exists(staging)) return;
        foreach (string d in Directory.EnumerateDirectories(staging)) Directory.Delete(d, recursive: true);
        foreach (string f in Directory.EnumerateFiles(staging)) File.Delete(f);
    }
}
