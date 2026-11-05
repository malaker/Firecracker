using System.Globalization;

namespace FcEgress.Host;

// runs\<run-id>\net.log: one line per connection attempt, flushed as it is written so a
// timeout or teardown never loses what was already logged.
public sealed class NetLog : IDisposable
{
    private readonly StreamWriter _writer;
    private readonly Lock _gate = new();

    public NetLog(string path)
    {
        var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        _writer = new StreamWriter(fs) { AutoFlush = true, NewLine = "\n" };
    }

    public void Connection(string decision, string host, ushort port, string ip, string reason, long bytesUp, long bytesDown) =>
        Write($"decision={decision} host={host} port={port} ip={ip} reason={reason} bytes_up={bytesUp} bytes_down={bytesDown}");

    public void Event(string kind, string detail) => Write($"event={kind} detail={Sanitize(detail)}");

    private void Write(string fields)
    {
        string line = $"{DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture)} {fields}";
        lock (_gate)
        {
            try
            {
                _writer.WriteLine(line);
            }
            catch (IOException)
            {
            }
        }
    }

    private static string Sanitize(string s) => new(s.Select(c => char.IsControl(c) || c == ' ' ? '_' : c).Take(200).ToArray());

    public void Dispose()
    {
        lock (_gate) _writer.Dispose();
    }
}
