using System.Diagnostics;
using System.Text;

namespace FcMcp;

public sealed record CliResult(int ExitCode, bool TimedOut);

/// <summary>Runs one fc.ps1 command (design D2). Implementations must never let the child touch the server's stdio.</summary>
public interface ICliRunner
{
    /// <param name="command">fc.ps1 command (run, start, ssh, put, get, stop, ...).</param>
    /// <param name="positional">Positional values after the command (run id, paths, guest command).</param>
    /// <param name="named">Named parameters; a value of <c>true</c> passes a switch.</param>
    Task<CliResult> RunAsync(string command, IReadOnlyList<string> positional, IReadOnlyDictionary<string, object> named,
        string stdoutPath, string stderrPath, TimeSpan? timeout, CancellationToken cancel);
}

/// <summary>
/// Starts <c>powershell.exe -EncodedCommand</c> with a generated script that calls fc.ps1. Every value is
/// embedded as a single-quoted PowerShell literal, so quotes and spaces in guest commands survive
/// (Windows PowerShell 5.1 strips embedded double quotes from -File arguments). The child's stdin
/// is an empty pipe and its stdout/stderr go to files: it can never read or write the MCP stream.
/// </summary>
public sealed class PowerShellCliRunner(string scriptPath, string powershellExe = "powershell.exe") : ICliRunner
{
    public async Task<CliResult> RunAsync(string command, IReadOnlyList<string> positional, IReadOnlyDictionary<string, object> named,
        string stdoutPath, string stderrPath, TimeSpan? timeout, CancellationToken cancel)
    {
        var psi = new ProcessStartInfo(powershellExe)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (string a in new[] { "-NoProfile", "-NonInteractive", "-OutputFormat", "Text", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Encode(BuildScript(scriptPath, command, positional, named)) })
        {
            psi.ArgumentList.Add(a);
        }

        using var proc = new Process { StartInfo = psi };
        proc.Start();
        proc.StandardInput.Close();

        await using var outFile = new FileStream(stdoutPath, FileMode.Create, FileAccess.Write, FileShare.Read);
        await using var errFile = new FileStream(stderrPath, FileMode.Create, FileAccess.Write, FileShare.Read);
        Task pumpOut = proc.StandardOutput.BaseStream.CopyToAsync(outFile, CancellationToken.None);
        Task pumpErr = proc.StandardError.BaseStream.CopyToAsync(errFile, CancellationToken.None);

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        if (timeout is { } t) cts.CancelAfter(t);
        bool timedOut = false;
        try
        {
            await proc.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            timedOut = !cancel.IsCancellationRequested;
            try { proc.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            await proc.WaitForExitAsync(CancellationToken.None);
            if (!timedOut) throw;
        }
        await Task.WhenAll(pumpOut, pumpErr);
        return new CliResult(timedOut ? 124 : proc.ExitCode, timedOut);
    }

    internal static string Literal(string s) => "'" + s.Replace("'", "''") + "'";

    internal static string BuildScript(string scriptPath, string command, IReadOnlyList<string> positional, IReadOnlyDictionary<string, object> named)
    {
        var sb = new StringBuilder();
        // Progress records would otherwise reach stderr as "#< CLIXML" blocks.
        sb.Append("$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; [Console]::OutputEncoding = [Text.Encoding]::UTF8; ");
        sb.Append("$n = @{");
        foreach (var (k, v) in named)
        {
            if (!IsName(k)) throw new ArgumentException($"invalid parameter name '{k}'");
            sb.Append(k).Append(" = ");
            sb.Append(v switch
            {
                true => "$true",
                string s => Literal(s),
                string[] arr => "@(" + string.Join(",", arr.Select(Literal)) + ")",
                int i => i.ToString(System.Globalization.CultureInfo.InvariantCulture),
                _ => throw new ArgumentException($"unsupported value for '{k}'"),
            });
            sb.Append("; ");
        }
        sb.Append("}; ");
        sb.Append("& ").Append(Literal(scriptPath)).Append(' ').Append(Literal(command));
        foreach (string p in positional) sb.Append(' ').Append(Literal(p));
        sb.Append(" @n; exit $LASTEXITCODE");
        return sb.ToString();
    }

    private static bool IsName(string k) => k.Length > 0 && k.All(char.IsAsciiLetterOrDigit);

    private static string Encode(string script) => Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
}
