using System.Net;
using System.Net.Sockets;

namespace FcEgress.Tests;

internal static class Loopback
{
    // A connected TCP pair standing in for the docker exec stdin/stdout channel.
    public static async Task<(NetworkStream A, NetworkStream B)> PairAsync()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var client = new TcpClient();
        var connect = client.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
        var server = await listener.AcceptTcpClientAsync();
        await connect;
        listener.Stop();
        return (client.GetStream(), server.GetStream());
    }
}

// Endless source of bytes; never reaches EOF.
internal sealed class InfiniteSource : Stream
{
    public override int Read(byte[] buffer, int offset, int count)
    {
        buffer.AsSpan(offset, count).Fill((byte)'x');
        return count;
    }

    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        buffer.Span.Fill((byte)'x');
        return ValueTask.FromResult(buffer.Length);
    }

    public override void Write(byte[] buffer, int offset, int count) { }
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => 0; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
}

// Counts what is written to it; reads block until cancelled, so it never signals EOF.
internal sealed class CountingSink : Stream
{
    private long _written;
    public long Written => Interlocked.Read(ref _written);

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        await Task.Delay(Timeout.Infinite, ct);
        return 0;
    }

    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
    {
        Interlocked.Add(ref _written, buffer.Length);
        return ValueTask.CompletedTask;
    }

    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => Interlocked.Add(ref _written, count);
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => 0; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
}
