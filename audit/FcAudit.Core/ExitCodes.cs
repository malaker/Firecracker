namespace FcAudit.Core;

/// <summary>fc-audit exit codes. The controller treats any non-zero code as "no report".</summary>
public static class ExitCodes
{
    public const int Ok = 0;
    public const int Usage = 2;
    public const int Internal = 5;
}
