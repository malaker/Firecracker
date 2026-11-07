namespace FcAirlock.Core;

/// <summary>Process exit codes shared by every fc-airlock command (design D10).</summary>
public static class ExitCodes
{
    public const int Ok = 0;
    public const int Usage = 2;
    public const int Refused = 3;
    public const int Malformed = 4;
    public const int Internal = 5;
}
