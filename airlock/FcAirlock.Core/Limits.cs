using System.Globalization;

namespace FcAirlock.Core;

/// <summary>Transfer limits (spec: Transfer limits, Host-safe file names; design D9).</summary>
public sealed record Limits
{
    public const long GiB = 1024L * 1024 * 1024;
    public const string TestOverrideVariable = "FC_AIRLOCK_TEST_MAX_BYTES";

    public static Limits Default { get; } = new();

    public long MaxTotalBytes { get; init; } = GiB;
    public long MaxFileBytes { get; init; } = GiB;
    public int MaxEntries { get; init; } = 10_000;
    public int MaxPathChars { get; init; } = 512;
    public int MaxDepth { get; init; } = 64;
    public int MaxComponentChars { get; init; } = 255;
    public int MaxManifestBytes { get; init; } = 16 * 1024 * 1024;

    /// <summary>
    /// Cap for a raw byte stream (the guest's tar or the airlock output): file content plus
    /// tar headers/padding (at most 3 blocks per entry) or manifest overhead, plus 1 MiB.
    /// </summary>
    public long StreamCap => MaxTotalBytes + 1536L * MaxEntries + 1024 * 1024;

    /// <summary>
    /// Limits for this process. <see cref="TestOverrideVariable"/> may only lower the byte
    /// limits (for tests); a value that is not a positive integer below the default is ignored.
    /// </summary>
    public static Limits FromEnvironment(Func<string, string?>? getEnv = null)
    {
        getEnv ??= Environment.GetEnvironmentVariable;
        string? raw = getEnv(TestOverrideVariable);
        if (raw is null
            || !long.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out long v)
            || v <= 0 || v >= Default.MaxTotalBytes)
        {
            return Default;
        }
        return Default with { MaxTotalBytes = v, MaxFileBytes = Math.Min(v, Default.MaxFileBytes) };
    }
}
