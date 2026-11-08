using FcAirlock.Core;

// fc-airlock <command> [options]
//   --version    print the tool version
//   validate     (inside the airlock) read a guest tar stream on stdin, write the airlock
//                output format on stdout. Output is only meaningful when the exit code is 0.
//   unpack --in FILE --staging DIR
//                (on the host) re-validate an airlock output file and write its files into the
//                empty folder DIR; prints {"files":N,"bytes":M} on stdout. DIR is emptied on failure.
//   launch-unpack --in FILE --staging DIR
//                (Windows, elevated controller) run 'unpack' as a non-admin, Medium-integrity child
//                in a kill-on-close job (1 process, 512 MiB, 180 s) and return its exit code.
// Exit codes: 0 ok, 2 usage, 3 refused (rule violation), 4 malformed input, 5 internal error.
// Errors are one line on stderr: "refused: <reason>", "malformed: <reason>" or "error: <reason>".
return FcAirlock.Cli.Run(args);

namespace FcAirlock
{
    internal static class Cli
    {
        private const string Usage = "usage: fc-airlock --version | validate | unpack --in FILE --staging DIR | launch-unpack --in FILE --staging DIR";
        private static readonly TimeSpan UnpackTimeout = TimeSpan.FromSeconds(180);
        private const ulong UnpackMemoryLimit = 512UL * 1024 * 1024;

        public static int Run(string[] args)
        {
            if (args.Length == 0)
            {
                Console.Error.WriteLine(Usage);
                return ExitCodes.Usage;
            }
            try
            {
                switch (args[0])
                {
                    case "--version" when args.Length == 1:
                        Console.Out.WriteLine($"fc-airlock {typeof(Cli).Assembly.GetName().Version?.ToString(3)}");
                        return ExitCodes.Ok;
                    case "validate" when args.Length == 1:
                        return Validate();
                    case "unpack" when args.Length == 5:
                        return Unpack(args);
                    case "launch-unpack" when args.Length == 5 && OperatingSystem.IsWindows():
                        return LaunchUnpack(args);
                    default:
                        Console.Error.WriteLine(Usage);
                        return ExitCodes.Usage;
                }
            }
            catch (RuleViolationException ex)
            {
                Console.Error.WriteLine($"refused: {ex.Message}");
                return ExitCodes.Refused;
            }
            catch (MalformedInputException ex)
            {
                Console.Error.WriteLine($"malformed: {ex.Message}");
                return ExitCodes.Malformed;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"error: {ex.GetType().Name}: {ex.Message}");
                return ExitCodes.Internal;
            }
        }

        private static int Validate()
        {
            using var stdin = Console.OpenStandardInput();
            using var stdout = new BufferedStream(Console.OpenStandardOutput(), 1 << 16);
            var result = Validator.Run(stdin, stdout, Limits.FromEnvironment());
            Console.Error.WriteLine($"ok: {result.Files} files, {result.Bytes} bytes");
            return ExitCodes.Ok;
        }

        // The elevated Windows controller must not parse airlock output with admin rights (design D7):
        // re-run this exe's 'unpack' with a restricted token. The child writes straight to our stdout
        // and stderr; nothing it starts outlives it.
        [System.Runtime.Versioning.SupportedOSPlatform("windows")]
        private static int LaunchUnpack(string[] args)
        {
            var (input, staging) = UnpackArgs(args);
            if (input is null || staging is null)
            {
                Console.Error.WriteLine(Usage);
                return ExitCodes.Usage;
            }
            string self = Environment.ProcessPath ?? throw new InvalidOperationException("cannot locate fc-airlock.exe");
            string cmd = $"\"{self}\" unpack --in \"{Path.GetFullPath(input)}\" --staging \"{Path.GetFullPath(staging)}\"";
            Console.Out.Flush();
            using var nul = File.OpenHandle("NUL", FileMode.Open, FileAccess.Read);
            using var stdout = StdHandle(-11);
            using var stderr = StdHandle(-12);
            uint? code = FcWin.RestrictedLaunch.RunToCompletion(cmd, nul, stdout ?? nul, stderr ?? nul, UnpackTimeout, 1, UnpackMemoryLimit);
            if (code is null)
            {
                Console.Error.WriteLine($"error: the host check did not finish within {UnpackTimeout.TotalSeconds:0}s");
                return ExitCodes.Internal;
            }
            return (int)code.Value;
        }

        [System.Runtime.Versioning.SupportedOSPlatform("windows")]
        private static Microsoft.Win32.SafeHandles.SafeFileHandle? StdHandle(int which)
        {
            IntPtr h = FcWin.Native.GetStdHandle(which);
            return h == IntPtr.Zero || h == new IntPtr(-1) ? null : new Microsoft.Win32.SafeHandles.SafeFileHandle(h, ownsHandle: false);
        }

        private static (string? Input, string? Staging) UnpackArgs(string[] args)
        {
            string? input = null, staging = null;
            for (int i = 1; i + 1 < args.Length; i += 2)
            {
                switch (args[i])
                {
                    case "--in": input = args[i + 1]; break;
                    case "--staging": staging = args[i + 1]; break;
                    default: return (null, null);
                }
            }
            return (input, staging);
        }

        private static int Unpack(string[] args)
        {
            string? input = null, staging = null;
            for (int i = 1; i + 1 < args.Length; i += 2)
            {
                switch (args[i])
                {
                    case "--in": input = args[i + 1]; break;
                    case "--staging": staging = args[i + 1]; break;
                    default:
                        Console.Error.WriteLine(Usage);
                        return ExitCodes.Usage;
                }
            }
            if (input is null || staging is null)
            {
                Console.Error.WriteLine(Usage);
                return ExitCodes.Usage;
            }
            var result = Unpacker.Run(input, staging, Limits.FromEnvironment());
            Console.Out.WriteLine($"{{\"files\":{result.Files},\"bytes\":{result.Bytes}}}");
            return ExitCodes.Ok;
        }
    }
}
