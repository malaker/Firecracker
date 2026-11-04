using System.Buffers.Binary;
using FcEgress.Protocol;

namespace FcEgress.Tests;

public class FrameTests
{
    private static byte[] Raw(byte type, uint id, byte[] payload, uint? declaredLength = null)
    {
        var b = new byte[Limits.HeaderSize + payload.Length];
        b[0] = type;
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(1), id);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(5), declaredLength ?? (uint)payload.Length);
        payload.CopyTo(b, Limits.HeaderSize);
        return b;
    }

    private static async Task<Frame?> ReadOne(byte[] bytes) => await new FrameReader(new MemoryStream(bytes)).ReadAsync();

    public static TheoryData<FrameType, byte[]> ValidFrames => new()
    {
        { FrameType.Open, OpenPayload.Encode("example.com", 443) },
        { FrameType.OpenOk, [] },
        { FrameType.OpenFail, [(byte)OpenFailReason.Denied] },
        { FrameType.Data, [1, 2, 3] },
        { FrameType.Window, [0, 0, 4, 0] },
        { FrameType.Close, [] },
    };

    [Theory]
    [MemberData(nameof(ValidFrames))]
    public async Task Writer_and_reader_round_trip_each_type(FrameType type, byte[] payload)
    {
        var ms = new MemoryStream();
        await new FrameWriter(ms).WriteAsync(type, 7, payload);
        ms.Position = 0;
        var f = await new FrameReader(ms).ReadAsync();
        Assert.NotNull(f);
        Assert.Equal(type, f.Value.Type);
        Assert.Equal(7u, f.Value.Stream);
        Assert.Equal(payload, f.Value.Payload);
        Assert.Null(await new FrameReader(ms).ReadAsync());
    }

    [Fact]
    public async Task Open_payload_decodes_host_and_port()
    {
        var f = await ReadOne(Raw((byte)FrameType.Open, 1, OpenPayload.Encode("1.1.1.1", 8443)));
        Assert.True(OpenPayload.TryDecode(f!.Value.Payload, out var host, out var port));
        Assert.Equal("1.1.1.1", host);
        Assert.Equal(8443, port);
    }

    [Fact]
    public async Task Clean_eof_returns_null() => Assert.Null(await ReadOne([]));

    [Fact]
    public async Task Unknown_type_is_protocol_error() =>
        await Assert.ThrowsAsync<ProtocolException>(() => ReadOne(Raw(99, 1, [])));

    [Fact]
    public async Task Oversize_length_is_protocol_error_without_reading_payload() =>
        await Assert.ThrowsAsync<ProtocolException>(() => ReadOne(Raw((byte)FrameType.Data, 1, [], Limits.MaxPayload + 1)));

    [Theory]
    [InlineData(0u)]
    [InlineData(Limits.MaxStreamId + 1)]
    public async Task Out_of_range_stream_is_protocol_error(uint id) =>
        await Assert.ThrowsAsync<ProtocolException>(() => ReadOne(Raw((byte)FrameType.Close, id, [])));

    [Fact]
    public async Task Truncated_header_at_eof_is_protocol_error() =>
        await Assert.ThrowsAsync<ProtocolException>(() => ReadOne(Raw((byte)FrameType.Close, 1, [])[..5]));

    [Fact]
    public async Task Truncated_payload_at_eof_is_protocol_error() =>
        await Assert.ThrowsAsync<ProtocolException>(() => ReadOne(Raw((byte)FrameType.Data, 1, [1, 2, 3, 4], 8)));

    [Theory]
    [InlineData((byte)FrameType.OpenOk, 1)]
    [InlineData((byte)FrameType.Close, 1)]
    [InlineData((byte)FrameType.OpenFail, 0)]
    [InlineData((byte)FrameType.Window, 3)]
    [InlineData((byte)FrameType.Data, 0)]
    public async Task Wrong_payload_size_is_protocol_error(byte type, int size) =>
        await Assert.ThrowsAsync<ProtocolException>(() => ReadOne(Raw(type, 1, new byte[size])));

    public static TheoryData<byte[]> BadOpenPayloads => new()
    {
        new byte[] { 0xBB, 0x01, 0 },                              // empty name
        new byte[] { 0xBB, 0x01, 5, (byte)'a', (byte)'b' },        // declared length longer than payload
        new byte[] { 0xBB, 0x01, 1, (byte)'a', (byte)'b' },        // trailing bytes
        new byte[] { 0xBB, 0x01, 3, (byte)'a', (byte)' ', (byte)'b' }, // non-printable / space
        new byte[] { 0xBB, 0x01, 254 }.Concat(Enumerable.Repeat((byte)'a', 254)).ToArray(), // 254 chars
    };

    [Theory]
    [MemberData(nameof(BadOpenPayloads))]
    public async Task Malformed_open_is_protocol_error(byte[] payload) =>
        await Assert.ThrowsAsync<ProtocolException>(() => ReadOne(Raw((byte)FrameType.Open, 1, payload)));

    [Fact]
    public void Duplicate_open_is_protocol_error()
    {
        var reg = new StreamRegistry();
        reg.Register(5);
        Assert.Throws<ProtocolException>(() => reg.Register(5));
        reg.Release(5);
        reg.Register(5);
    }
}
