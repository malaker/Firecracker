using System.Buffers.Binary;
using System.Text;

namespace FcEgress.Protocol;

// Frame layout (little-endian): u8 type | u32 stream | u32 length | payload.
// The host only ever parses this binary format; HTTP is parsed by the guest relay.
public enum FrameType : byte
{
    Open = 1,      // guest -> host: u16 port | u8 name length | ASCII name
    OpenOk = 2,    // host -> guest
    OpenFail = 3,  // host -> guest: u8 reason
    Data = 4,
    Window = 5,    // u32 credit granted to the peer
    Close = 6,
}

public enum OpenFailReason : byte
{
    Denied = 1,
    ConnectFailed = 2,
    LimitReached = 3,
}

public static class Limits
{
    public const int HeaderSize = 9;
    public const int MaxPayload = 64 * 1024;
    public const int MaxHostLength = 253;
    public const uint MaxStreamId = 1 << 20;
    public const int MaxStreams = 64;
    public const int StreamWindow = 256 * 1024;
}

public sealed class ProtocolException(string message) : Exception(message);

public readonly record struct Frame(FrameType Type, uint Stream, byte[] Payload);

public sealed class FrameReader(Stream stream)
{
    private readonly byte[] _header = new byte[Limits.HeaderSize];

    // Returns null on a clean EOF between frames; throws ProtocolException on anything malformed.
    public async ValueTask<Frame?> ReadAsync(CancellationToken ct = default)
    {
        int got = await ReadFullyAsync(_header, ct);
        if (got == 0) return null;
        if (got < Limits.HeaderSize) throw new ProtocolException("truncated frame header");

        byte rawType = _header[0];
        if (!Enum.IsDefined(typeof(FrameType), rawType)) throw new ProtocolException($"unknown frame type {rawType}");
        var type = (FrameType)rawType;
        uint id = BinaryPrimitives.ReadUInt32LittleEndian(_header.AsSpan(1));
        uint length = BinaryPrimitives.ReadUInt32LittleEndian(_header.AsSpan(5));
        if (id == 0 || id > Limits.MaxStreamId) throw new ProtocolException($"stream id {id} out of range");
        if (length > Limits.MaxPayload) throw new ProtocolException($"frame length {length} exceeds {Limits.MaxPayload}");

        var payload = length == 0 ? Array.Empty<byte>() : new byte[length];
        if (length > 0 && await ReadFullyAsync(payload, ct) < length) throw new ProtocolException("truncated frame payload");
        ValidatePayload(type, payload);
        return new Frame(type, id, payload);
    }

    private static void ValidatePayload(FrameType type, byte[] payload)
    {
        bool ok = type switch
        {
            FrameType.OpenOk or FrameType.Close => payload.Length == 0,
            FrameType.OpenFail => payload.Length == 1,
            FrameType.Window => payload.Length == 4,
            FrameType.Data => payload.Length > 0,
            FrameType.Open => OpenPayload.TryDecode(payload, out _, out _),
            _ => false,
        };
        if (!ok) throw new ProtocolException($"malformed {type} payload ({payload.Length} bytes)");
    }

    private async ValueTask<int> ReadFullyAsync(byte[] buffer, CancellationToken ct)
    {
        int total = 0;
        while (total < buffer.Length)
        {
            int n = await stream.ReadAsync(buffer.AsMemory(total), ct);
            if (n == 0) break;
            total += n;
        }
        return total;
    }
}

public sealed class FrameWriter(Stream stream)
{
    private readonly SemaphoreSlim _lock = new(1, 1);

    // ct only cancels waiting for the channel. Once a frame starts it is written whole: a
    // header without its payload would desynchronise the channel and kill every stream on it.
    public async ValueTask WriteAsync(FrameType type, uint id, ReadOnlyMemory<byte> payload, CancellationToken ct = default)
    {
        if (payload.Length > Limits.MaxPayload) throw new ArgumentOutOfRangeException(nameof(payload));
        var frame = new byte[Limits.HeaderSize + payload.Length];
        frame[0] = (byte)type;
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(1), id);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(5), (uint)payload.Length);
        payload.CopyTo(frame.AsMemory(Limits.HeaderSize));
        await _lock.WaitAsync(ct);
        try
        {
            await stream.WriteAsync(frame, CancellationToken.None);
            await stream.FlushAsync(CancellationToken.None);
        }
        finally
        {
            _lock.Release();
        }
    }

    public ValueTask WriteWindowAsync(uint id, uint credit, CancellationToken ct = default)
    {
        var p = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(p, credit);
        return WriteAsync(FrameType.Window, id, p, ct);
    }
}

public static class OpenPayload
{
    public static byte[] Encode(string host, ushort port)
    {
        byte[] name = Encoding.ASCII.GetBytes(host);
        if (name.Length is 0 or > Limits.MaxHostLength) throw new ArgumentException("host name length must be 1-253", nameof(host));
        var p = new byte[3 + name.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(p, port);
        p[2] = (byte)name.Length;
        name.CopyTo(p, 3);
        return p;
    }

    // Accepts only printable ASCII names; whether the name is acceptable is the policy's decision.
    public static bool TryDecode(ReadOnlySpan<byte> payload, out string host, out ushort port)
    {
        host = "";
        port = 0;
        if (payload.Length < 4) return false;
        int len = payload[2];
        if (len is 0 or > Limits.MaxHostLength || payload.Length != 3 + len) return false;
        var name = payload.Slice(3, len);
        foreach (byte b in name)
        {
            if (b is < 0x21 or > 0x7E) return false;
        }
        port = BinaryPrimitives.ReadUInt16LittleEndian(payload);
        host = Encoding.ASCII.GetString(name);
        return true;
    }
}

// Tracks which stream ids are open so a duplicate OPEN is a protocol error.
public sealed class StreamRegistry
{
    private readonly HashSet<uint> _open = [];
    private readonly Lock _gate = new();

    public int Count { get { lock (_gate) return _open.Count; } }

    public void Register(uint id)
    {
        lock (_gate)
        {
            if (!_open.Add(id)) throw new ProtocolException($"duplicate OPEN for stream {id}");
        }
    }

    public void Release(uint id)
    {
        lock (_gate) _open.Remove(id);
    }
}
