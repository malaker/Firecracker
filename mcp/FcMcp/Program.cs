using System.Runtime.InteropServices;
using FcMcp;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// fc-mcp --repo-root DIR [--allow-root DIR]... [--allow-networked] [--max-sessions N]
// Started by 'fc.ps1 mcp'. stdout carries only MCP protocol messages; logs go to stderr.
ServerOptions options;
try
{
    options = ServerOptions.Parse(args, Environment.CurrentDirectory, ServerOptions.IsElevated());
}
catch (ArgumentException ex)
{
    Console.Error.WriteLine($"fc-mcp: {ex.Message}");
    return 2;
}

var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings { Args = [], ContentRootPath = options.RepoRoot });
builder.Logging.ClearProviders();
builder.Logging.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace);
builder.Logging.SetMinimumLevel(LogLevel.Warning);
builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(30));

builder.Services.AddSingleton(options);
builder.Services.AddSingleton<ICliRunner>(new PowerShellCliRunner(options.FcPs1));
builder.Services.AddSingleton(new PathPolicy(options.AllowRoots));
builder.Services.AddSingleton(new SessionTable(options.MaxSessions));
builder.Services.AddSingleton<SandboxTools>();
builder.Services.AddHostedService<SessionReaper>();

builder.Services
    .AddMcpServer(o => o.ServerInfo = new() { Name = "fc-sandbox", Version = "1.0.0" })
    .WithStdioServerTransport()
    .WithTools<SandboxTools>();

using var host = builder.Build();
// A closed console window (CTRL_CLOSE) or logoff must still stop the sessions.
using var hup = PosixSignalRegistration.Create(PosixSignal.SIGHUP, ctx =>
{
    ctx.Cancel = true;
    host.Services.GetRequiredService<IHostApplicationLifetime>().StopApplication();
});
await host.RunAsync();
return 0;

/// <summary>Destroys every session when the server stops (client disconnect, Ctrl+C, console close).</summary>
internal sealed class SessionReaper(SessionTable sessions, SandboxTools tools) : IHostedService
{
    public Task StartAsync(CancellationToken cancel) => Task.CompletedTask;

    public Task StopAsync(CancellationToken cancel) =>
        sessions.StopAllAsync(s => tools.StopSessionAsync(s, CancellationToken.None), TimeSpan.FromSeconds(25));
}
