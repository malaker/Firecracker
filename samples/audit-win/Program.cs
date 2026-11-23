// fc-audit-probe: does one of each thing an audit report should show, all harmless.
//   (no --hang)  writes out-file.txt and args.txt in its working directory, creates
//                C:\Users\Public\fc-audit-probe.txt, sets HKCU\Software\FcAuditProbe value x=1,
//                and fetches http://example.com/ (through HTTP_PROXY when set). Exits 0.
//   --hang       prints a line and then waits forever (for the timeout check).
//   --hang-write keeps appending to grow.txt in its working directory until it is stopped.
// args.txt holds the raw command line after the program path, exactly as the process received it
// (GetCommandLineW: on .NET, Environment.CommandLine is rebuilt from the parsed arguments and drops
// quotes, e.g. "c|d" becomes c|d).
using System.Runtime.InteropServices;
using Microsoft.Win32;

if (args.Length > 0 && args[0] == "--hang")
{
    Console.WriteLine("fc-audit-probe: hanging");
    Thread.Sleep(Timeout.Infinite);
}
if (args.Length > 0 && args[0] == "--hang-write")
{
    // Keeps writing to its working directory until it is stopped, like a download that never ends.
    Console.WriteLine("fc-audit-probe: writing forever");
    using var grow = new FileStream("grow.txt", FileMode.Append, FileAccess.Write, FileShare.Read);
    var line = System.Text.Encoding.ASCII.GetBytes(new string('x', 1023) + "\n");
    while (true)
    {
        grow.Write(line);
        grow.Flush();
        Thread.Sleep(50);
    }
}

File.WriteAllText("args.txt", RawArguments(Marshal.PtrToStringUni(GetCommandLineW()) ?? ""));
File.WriteAllText("out-file.txt", "written by fc-audit-probe\n");
File.WriteAllText(@"C:\Users\Public\fc-audit-probe.txt", "dropped by fc-audit-probe\n");
using (var key = Registry.CurrentUser.CreateSubKey(@"Software\FcAuditProbe"))
{
    key.SetValue("x", "1");
}
try
{
    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
    var body = await http.GetStringAsync("http://example.com/");
    Console.WriteLine($"fc-audit-probe: fetched {body.Length} characters");
}
catch (Exception ex)
{
    // Expected in the isolated run.
    Console.Error.WriteLine($"fc-audit-probe: fetch failed: {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine("fc-audit-probe: done");
return 0;

[DllImport("kernel32.dll")]
static extern IntPtr GetCommandLineW();

// The command line minus the program path (quoted or not) and the spaces after it (cmd.exe puts
// two there when it starts a quoted program from a batch file).
static string RawArguments(string cmd)
{
    int i = 0;
    if (cmd.StartsWith('"'))
    {
        int end = cmd.IndexOf('"', 1);
        i = end < 0 ? cmd.Length : end + 1;
    }
    else
    {
        while (i < cmd.Length && cmd[i] != ' ') i++;
    }
    while (i < cmd.Length && cmd[i] == ' ') i++;
    return cmd[i..];
}
