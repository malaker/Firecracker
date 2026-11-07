namespace FcAirlock.Core;

/// <summary>Read-only pass-through that refuses to deliver more than <c>cap</c> bytes.</summary>
internal sealed class CappedReadStream(Stream inner, long cap) : Stream
{
    public long BytesRead { get; private set; }

    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));

    public override int Read(Span<byte> buffer)
    {
        int n = inner.Read(buffer);
        BytesRead += n;
        if (BytesRead > cap) throw new RuleViolationException($"input stream is larger than the {cap}-byte cap");
        return n;
    }

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => BytesRead; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
