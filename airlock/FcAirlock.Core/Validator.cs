using System.Formats.Tar;
using System.Security.Cryptography;

namespace FcAirlock.Core;

/// <summary>
/// Runs inside the airlock VM (design D2): reads a guest-produced tar stream entry by entry,
/// applies <see cref="Rules"/>, and streams accepted file data into the airlock output format.
/// Nothing is extracted to disk.
/// </summary>
public static class Validator
{
    public static ValidationResult Run(Stream tarInput, Stream output, Limits limits)
    {
        var input = new CappedReadStream(tarInput, limits.StreamCap);
        var checker = new TransferChecker(limits);
        var entries = new List<ManifestEntry>();
        long offset = 0;
        byte[] buffer = new byte[81920];

        try
        {
            using var reader = new TarReader(input, leaveOpen: true);
            TarEntry? entry;
            while ((entry = reader.GetNextEntry(copyData: false)) is not null)
            {
                EntryKind kind = Classify(entry);
                string? path = Normalize(entry.Name, kind);
                if (path is null) continue; // the archive root ("." or "./")

                checker.Add(path, kind, kind == EntryKind.File ? entry.Length : 0);
                if (kind == EntryKind.Directory)
                {
                    entries.Add(new ManifestEntry(path, kind, 0, 0, null));
                    continue;
                }

                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                long copied = 0;
                if (entry.DataStream is { } data)
                {
                    int n;
                    while ((n = data.Read(buffer)) > 0)
                    {
                        copied += n;
                        if (copied > entry.Length) throw new MalformedInputException($"entry data longer than its header: '{Rules.Printable(path)}'");
                        hash.AppendData(buffer, 0, n);
                        output.Write(buffer, 0, n);
                    }
                }
                if (copied != entry.Length) throw new MalformedInputException($"archive ends inside '{Rules.Printable(path)}'");
                entries.Add(new ManifestEntry(path, kind, offset, copied, AirlockFormat.ToHex(hash.GetHashAndReset())));
                offset += copied;
            }
        }
        catch (NotSupportedException ex)
        {
            // TarReader rejects some entry types (e.g. GNU sparse 'S') itself, before we see the entry.
            throw new RuleViolationException($"unsupported tar entry type (such as a GNU sparse file): {ex.Message}");
        }
        catch (Exception ex) when (ex is EndOfStreamException or InvalidDataException or FormatException or ArgumentException)
        {
            throw new MalformedInputException($"archive is malformed: {ex.Message}", ex);
        }

        byte[] manifest = AirlockFormat.WriteManifest(entries);
        if (manifest.Length > limits.MaxManifestBytes) throw new RuleViolationException($"manifest larger than {limits.MaxManifestBytes} bytes");
        AirlockFormat.WriteTrailer(output, manifest);
        output.Flush();
        return new ValidationResult(checker.Files, checker.TotalBytes);
    }

    private static EntryKind Classify(TarEntry entry)
    {
        // GNU sparse files can also hide inside pax headers of a "regular" entry.
        if (entry is PaxTarEntry pax && pax.ExtendedAttributes.Keys.Any(k => k.StartsWith("GNU.sparse.", StringComparison.Ordinal)))
        {
            throw Rules.Refuse(entry.Name, "sparse file is not allowed");
        }
        return entry.EntryType switch
        {
            TarEntryType.RegularFile or TarEntryType.V7RegularFile => EntryKind.File,
            TarEntryType.Directory => EntryKind.Directory,
            TarEntryType.SymbolicLink => throw Rules.Refuse(entry.Name, "symbolic link is not allowed"),
            TarEntryType.HardLink => throw Rules.Refuse(entry.Name, "hard link is not allowed"),
            TarEntryType.CharacterDevice => throw Rules.Refuse(entry.Name, "character device is not allowed"),
            TarEntryType.BlockDevice => throw Rules.Refuse(entry.Name, "block device is not allowed"),
            TarEntryType.Fifo => throw Rules.Refuse(entry.Name, "FIFO is not allowed"),
            TarEntryType.SparseFile => throw Rules.Refuse(entry.Name, "sparse file is not allowed"),
            _ => throw Rules.Refuse(entry.Name, $"entry type '{entry.EntryType}' is not allowed"),
        };
    }

    /// <summary>
    /// Archives made with <c>tar -C dir -cf - .</c> name entries "./a/b" and directories "./a/".
    /// Returns null for the archive root. Anything else is passed to the rules unchanged.
    /// </summary>
    internal static string? Normalize(string name, EntryKind kind)
    {
        string p = name;
        while (p.StartsWith("./", StringComparison.Ordinal)) p = p[2..];
        if (kind == EntryKind.Directory && p.EndsWith('/')) p = p[..^1];
        return p is "" or "." ? null : p;
    }
}

public sealed record ValidationResult(int Files, long Bytes);
