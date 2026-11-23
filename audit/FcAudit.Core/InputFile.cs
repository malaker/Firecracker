using System.Text;

namespace FcAudit.Core;

public enum InputStatus
{
    Ok,
    Missing,
    TooLarge,
}

/// <summary>One guest-derived input file, read whole or not at all (design D4: capped per input).</summary>
public sealed record InputText(InputStatus Status, IReadOnlyList<string> Lines, long Bytes)
{
    /// <summary>Per-input cap. A larger file is reported as too large to compare, never truncated.</summary>
    public const long DefaultMaxBytes = 64L * 1024 * 1024;

    public static InputText Missing { get; } = new(InputStatus.Missing, Array.Empty<string>(), 0);

    public bool IsOk => Status == InputStatus.Ok;

    /// <summary>Reads <paramref name="path"/> as text. The encoding's BOM, if present, wins.</summary>
    public static InputText Read(string path, Encoding encoding, long maxBytes = DefaultMaxBytes)
    {
        var info = new FileInfo(path);
        // A link planted in place of a snapshot is not followed: the airlock never produces one,
        // so finding one means something is wrong.
        if (!info.Exists || info.LinkTarget is not null) return Missing;
        if (info.Length > maxBytes) return new InputText(InputStatus.TooLarge, Array.Empty<string>(), info.Length);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var reader = new StreamReader(stream, encoding, detectEncodingFromByteOrderMarks: true);
        var lines = new List<string>();
        while (reader.ReadLine() is { } line) lines.Add(line);
        return new InputText(InputStatus.Ok, lines, info.Length);
    }

    /// <summary>Strict UTF-8 would throw on odd bytes from the guest; replace them instead.</summary>
    public static Encoding Utf8 { get; } = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: false);

    /// <summary>reg.exe exports are UTF-16 LE with a BOM.</summary>
    public static Encoding Utf16 { get; } = new UnicodeEncoding(bigEndian: false, byteOrderMark: true, throwOnInvalidBytes: false);
}
