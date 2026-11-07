namespace FcAirlock.Tests;

public class ScaffoldTests
{
    [Fact]
    public void CoreAssemblyLoads() => Assert.NotNull(typeof(FcAirlock.Core.ExitCodes).Assembly);
}
