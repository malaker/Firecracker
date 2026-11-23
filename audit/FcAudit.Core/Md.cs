using System.Text;

namespace FcAudit.Core;

/// <summary>
/// Markdown quoting for untrusted text. Guest strings only ever appear inside code spans or fenced
/// blocks, so they cannot add links, images, HTML or headings to the report.
/// </summary>
public static class Md
{
    /// <summary>Control characters (including CR/LF) become visible escapes, so one value stays one line.</summary>
    public static string Visible(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char c in s)
        {
            if (char.IsControl(c) || c == (char)0x2028 || c == (char)0x2029) sb.Append($"\\u{(int)c:x4}");
            else sb.Append(c);
        }
        return sb.ToString();
    }

    /// <summary>An inline code span that survives any backticks inside <paramref name="s"/>.</summary>
    public static string Code(string s)
    {
        s = Visible(s);
        if (s.Length == 0) return "``";
        int longest = LongestRun(s, '`');
        string fence = new('`', longest + 1);
        // A leading or trailing backtick (or space) needs padding; CommonMark strips one space each side.
        bool pad = s.StartsWith('`') || s.EndsWith('`') || s.StartsWith(' ') || s.EndsWith(' ');
        return pad ? $"{fence} {s} {fence}" : $"{fence}{s}{fence}";
    }

    /// <summary>A code span for a table cell: '|' would end the cell even inside a code span.</summary>
    public static string Cell(string s) => Code(s).Replace("|", "\\|");

    /// <summary>A fenced block that no line of <paramref name="lines"/> can close early.</summary>
    public static IEnumerable<string> Block(IEnumerable<string> lines)
    {
        var visible = lines.Select(Visible).ToList();
        int longest = visible.Count == 0 ? 0 : visible.Max(l => LongestRun(l, '`'));
        string fence = new('`', Math.Max(3, longest + 1));
        yield return fence + "text";
        foreach (var l in visible) yield return l;
        yield return fence;
    }

    private static int LongestRun(string s, char c)
    {
        int best = 0, run = 0;
        foreach (char ch in s)
        {
            run = ch == c ? run + 1 : 0;
            if (run > best) best = run;
        }
        return best;
    }
}
