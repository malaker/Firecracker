using System.Text;
using System.Text.Json;

namespace FcGateway;

/// <summary>
/// Reads token usage out of a response as it streams past (spec: Run limits, Call log), for plain JSON
/// bodies and server-sent events, in Anthropic and OpenAI shapes. Only usage is read; the body is not kept.
/// </summary>
public sealed class UsageScanner(UsageStyle style, bool sse)
{
    private const int MaxBuffer = 4 * 1024 * 1024;
    private readonly MemoryStream _buf = new();
    private bool _overflow;

    public long InputTokens { get; private set; }
    public long OutputTokens { get; private set; }
    public long Total => InputTokens + OutputTokens;

    public void Feed(ReadOnlySpan<byte> data)
    {
        if (_overflow) return;
        if (!sse)
        {
            if (_buf.Length + data.Length > MaxBuffer) { _overflow = true; return; }
            _buf.Write(data);
            return;
        }
        // SSE: handle complete lines, keep the partial tail.
        foreach (byte b in data)
        {
            if (b == (byte)'\n')
            {
                Line(_buf.GetBuffer().AsSpan(0, (int)_buf.Length));
                _buf.SetLength(0);
            }
            else if (_buf.Length < MaxBuffer)
            {
                _buf.WriteByte(b);
            }
        }
    }

    /// <summary>Call once the response has ended.</summary>
    public void Complete()
    {
        if (sse)
        {
            if (_buf.Length > 0) Line(_buf.GetBuffer().AsSpan(0, (int)_buf.Length));
        }
        else if (!_overflow && _buf.Length > 0)
        {
            Json(_buf.GetBuffer().AsSpan(0, (int)_buf.Length));
        }
        _buf.SetLength(0);
    }

    private void Line(ReadOnlySpan<byte> line)
    {
        if (line.Length > 0 && line[^1] == (byte)'\r') line = line[..^1];
        ReadOnlySpan<byte> prefix = "data:"u8;
        if (!line.StartsWith(prefix)) return;
        var payload = line[prefix.Length..];
        while (payload.Length > 0 && payload[0] == (byte)' ') payload = payload[1..];
        if (payload.SequenceEqual("[DONE]"u8)) return;
        Json(payload);
    }

    private void Json(ReadOnlySpan<byte> json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json.ToArray(), new JsonDocumentOptions { MaxDepth = 64 });
            Take(doc.RootElement);
        }
        catch (JsonException)
        {
            // Not JSON (or cut off): nothing to count.
        }
    }

    private void Take(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) return;
        if (style == UsageStyle.Anthropic)
        {
            // message_start: {message:{usage:{input_tokens,...}}}; message_delta: {usage:{output_tokens}}; plain: {usage:{...}}
            if (e.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.Object && m.TryGetProperty("usage", out var mu)) AddAnthropic(mu);
            if (e.TryGetProperty("usage", out var u)) AddAnthropic(u);
        }
        else
        {
            // Responses API: {type:"response.completed", response:{usage:{input_tokens,output_tokens}}}; chat: {usage:{prompt_tokens,completion_tokens}}
            if (e.TryGetProperty("response", out var r) && r.ValueKind == JsonValueKind.Object && r.TryGetProperty("usage", out var ru)) AddOpenAI(ru);
            else if (e.TryGetProperty("usage", out var u)) AddOpenAI(u);
        }
    }

    // Anthropic streams report usage in message_start and again, cumulatively, in message_delta:
    // keep the largest value seen instead of adding them up.
    private void AddAnthropic(JsonElement u)
    {
        if (u.ValueKind != JsonValueKind.Object) return;
        InputTokens = Math.Max(InputTokens, Num(u, "input_tokens") + Num(u, "cache_creation_input_tokens") + Num(u, "cache_read_input_tokens"));
        OutputTokens = Math.Max(OutputTokens, Num(u, "output_tokens"));
    }

    private void AddOpenAI(JsonElement u)
    {
        if (u.ValueKind != JsonValueKind.Object) return;
        InputTokens += Num(u, "input_tokens") + Num(u, "prompt_tokens");
        OutputTokens += Num(u, "output_tokens") + Num(u, "completion_tokens");
    }

    private static long Num(JsonElement o, string name) =>
        o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out long n) && n > 0 ? n : 0;
}
