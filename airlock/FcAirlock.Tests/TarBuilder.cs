using System.Formats.Tar;
using System.Text;

namespace FcAirlock.Tests;

/// <summary>Builds test archives, including ones TarWriter refuses to produce (raw headers).</summary>
internal sealed class TarBuilder
{
    private readonly MemoryStream _ms = new();
    private readonly TarWriter _writer;
    private readonly TarEntryFormat _format;

    public TarBuilder(TarEntryFormat format = TarEntryFormat.Pax)
    {
        _format = format;
        _writer = new TarWriter(_ms, format, leaveOpen: true);
    }

    public TarBuilder Dir(string name)
    {
        _writer.WriteEntry(New(TarEntryType.Directory, name));
        return this;
    }

    public TarBuilder File(string name, byte[] data)
    {
        var type = _format == TarEntryFormat.V7 ? TarEntryType.V7RegularFile : TarEntryType.RegularFile;
        var e = New(type, name);
        e.DataStream = new MemoryStream(data);
        _writer.WriteEntry(e);
        return this;
    }

    public TarBuilder File(string name, string text) => File(name, Encoding.UTF8.GetBytes(text));

    public TarBuilder Link(TarEntryType type, string name, string target)
    {
        var e = New(type, name);
        e.LinkName = target;
        _writer.WriteEntry(e);
        return this;
    }

    public TarBuilder Special(TarEntryType type, string name)
    {
        _writer.WriteEntry(New(type, name));
        return this;
    }

    public TarBuilder PaxFile(string name, byte[] data, Dictionary<string, string> attrs)
    {
        var e = new PaxTarEntry(TarEntryType.RegularFile, name, attrs) { DataStream = new MemoryStream(data) };
        _writer.WriteEntry(e);
        return this;
    }

    /// <summary>Appends a hand-made header block with any type flag and name, plus data.</summary>
    public TarBuilder Raw(char typeFlag, string name, byte[]? data = null, bool gnuMagic = false)
    {
        data ??= [];
        var h = new byte[512];
        Encoding.ASCII.GetBytes(name).CopyTo(h, 0);
        Octal(h, 100, 8, 0x1A4);
        Octal(h, 108, 8, 0);
        Octal(h, 116, 8, 0);
        Octal(h, 124, 12, data.Length);
        Octal(h, 136, 12, 0);
        h[156] = (byte)typeFlag;
        Encoding.ASCII.GetBytes(gnuMagic ? "ustar  \0" : "ustar\u000000").CopyTo(h, 257);
        for (int i = 148; i < 156; i++) h[i] = (byte)' ';
        int sum = h.Sum(b => b);
        Encoding.ASCII.GetBytes(Convert.ToString(sum, 8).PadLeft(6, '0') + "\0 ").CopyTo(h, 148);
        _ms.Write(h);
        _ms.Write(data);
        int pad = (512 - data.Length % 512) % 512;
        _ms.Write(new byte[pad]);
        return this;
    }

    public byte[] Build()
    {
        _writer.Dispose();
        return _ms.ToArray();
    }

    /// <summary>Raw archives must end with two zero blocks; Build() via TarWriter adds them.</summary>
    public byte[] BuildRaw()
    {
        _ms.Write(new byte[1024]);
        return _ms.ToArray();
    }

    private TarEntry New(TarEntryType type, string name) => _format switch
    {
        TarEntryFormat.V7 => new V7TarEntry(type, name),
        TarEntryFormat.Ustar => new UstarTarEntry(type, name),
        TarEntryFormat.Gnu => new GnuTarEntry(type, name),
        _ => new PaxTarEntry(type, name),
    };

    private static void Octal(byte[] h, int offset, int len, long value)
    {
        string s = Convert.ToString(value, 8).PadLeft(len - 1, '0');
        Encoding.ASCII.GetBytes(s).CopyTo(h, offset);
        h[offset + len - 1] = 0;
    }
}
