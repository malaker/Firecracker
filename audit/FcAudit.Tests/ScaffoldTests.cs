namespace FcAudit.Tests;

public class ScaffoldTests
{
    [Fact]
    public void CoreAssemblyLoads() => Assert.NotNull(typeof(FcAudit.Core.ExitCodes).Assembly);
}
