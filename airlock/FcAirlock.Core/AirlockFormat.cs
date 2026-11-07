using System.Buffers.Binary;
using System.Text;
using System.Text.Json;

namespace FcAirlock.Core;

public sealed record ManifestEntry(string Path, EntryKind Kind, long Offset, long Size, string? Sha256);

/// <summary>Input could not be parsed (truncated or corrupt), as opposed to breaking a rule.</summary>
public sealed class MalformedInputException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Airlock output format (design D3):
/// <code>[file bytes, concatenated in entry order][manifest JSON][u64 LE manifest length]["FCALOCK1"]</code>
/// JSON is written and read without reflection so the tool can be trimmed.
/// </summary>
public static class AirlockFormat
{
    public const int Version = 1;
    public static ReadOnlySpan<byte> Magic => "FCALOCK1"u8;
    public const int TrailerLength = 16;

    public static byte[] WriteManifest(IReadOnlyList<ManifestEntry> entries)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteNumber("version", Version);
            w.WriteStartArray("entries");
            foreach (var e in entries)
            {
                w.WriteStartObject();
                w.WriteString("path", e.Path);
                w.WriteString("type", e.Kind == EntryKind.File ? "file" : "dir");
                if (e.Kind == EntryKind.File)
                {
                    w.WriteNumber("offset", e.Offset);
                    w.WriteNumber("size", e.Size);
                    w.WriteString("sha256", e.Sha256);
                }
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        return ms.ToArray();
    }

    public static void WriteTrailer(Stream output, byte[] manifest)
    {
        output.Write(manifest);
        Span<byte> trailer = stackalloc byte[TrailerLength];
        BinaryPrimitives.WriteUInt64LittleEndian(trailer, (ulong)manifest.Length);
        Magic.CopyTo(trailer[8..]);
        output.Write(trailer);
    }

    /// <summary>
    /// Reads the trailer and manifest of an airlock output of <paramref name="length"/> bytes.
    /// Returns the entries and the length of the blob (where the manifest starts).
    /// Only structure is checked here; the rules are applied by the caller.
    /// </summary>
    public static (List<ManifestEntry> Entries, long BlobLength) ReadManifest(Stream input, long length, Limits limits)
    {
        if (length < TrailerLength) throw new MalformedInputException("airlock output is shorter than its trailer");
        Span<byte> trailer = stackalloc byte[TrailerLength];
        input.Position = length - TrailerLength;
        input.ReadExactly(trailer);
        if (!trailer[8..].SequenceEqual(Magic)) throw new MalformedInputException("airlock output has no valid trailer");
        ulong mlen = BinaryPrimitives.ReadUInt64LittleEndian(trailer);
        if (mlen > (ulong)limits.MaxManifestBytes) throw new MalformedInputException($"manifest larger than {limits.MaxManifestBytes} bytes");
        long blobLength = length - TrailerLength - (long)mlen;
        if (blobLength < 0) throw new MalformedInputException("manifest length exceeds the airlock output");

        var json = new byte[(int)mlen];
        input.Position = blobLength;
        input.ReadExactly(json);
        return (ParseManifest(json), blobLength);
    }

    internal static List<ManifestEntry> ParseManifest(byte[] json)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
        }
        catch (JsonException ex)
        {
            throw new MalformedInputException("manifest is not valid JSON", ex);
        }
        using (doc)
        {
            try
            {
                var root = doc.RootElement;
                if (root.ValueKind != JsonValueKind.Object) throw new MalformedInputException("manifest is not an object");
                if (root.GetProperty("version").GetInt32() != Version) throw new MalformedInputException("unsupported manifest version");
                var list = new List<ManifestEntry>();
                foreach (var e in root.GetProperty("entries").EnumerateArray())
                {
                    string path = e.GetProperty("path").GetString() ?? throw new MalformedInputException("entry without path");
                    string type = e.GetProperty("type").GetString() ?? "";
                    switch (type)
                    {
                        case "dir":
                            list.Add(new ManifestEntry(path, EntryKind.Directory, 0, 0, null));
                            break;
                        case "file":
                            string sha = e.GetProperty("sha256").GetString() ?? "";
                            if (sha.Length != 64 || !sha.All(Uri.IsHexDigit)) throw new MalformedInputException($"invalid sha256 for '{Rules.Printable(path)}'");
                            list.Add(new ManifestEntry(path, EntryKind.File, e.GetProperty("offset").GetInt64(), e.GetProperty("size").GetInt64(), sha.ToLowerInvariant()));
                            break;
                        default:
                            throw new RuleViolationException($"entry type '{Rules.Printable(type)}' is not allowed: '{Rules.Printable(path)}'");
                    }
                }
                return list;
            }
            catch (Exception ex) when (ex is KeyNotFoundException or InvalidOperationException or FormatException)
            {
                throw new MalformedInputException("manifest has a missing or mistyped field", ex);
            }
        }
    }

    public static string ToHex(byte[] hash) => Convert.ToHexStringLower(hash);

    internal static string Utf8(ReadOnlySpan<byte> b) => Encoding.UTF8.GetString(b);
}
