using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.Logging;

namespace FcGateway;

public sealed record GatewayOptions(string SocketPath, string LogPath, string? TotalsPath);

/// <summary>Builds the gateway app: Kestrel on one Unix socket with explicit limits (spec: Hardened against the guest).</summary>
public static class GatewayApp
{
    public const int MaxHeaderBytes = 32 * 1024;
    public const int MaxHeaderCount = 64;
    public const int MaxRequestLineBytes = 8 * 1024;
    public const int MaxConnections = 16;

    public static WebApplication Build(GatewayOptions o, Profile profile, string key, RunState state, CallLog log, HttpMessageHandler? upstreamHandler = null)
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(k =>
        {
            k.AddServerHeader = false;
            k.ListenUnixSocket(o.SocketPath, l => l.Protocols = HttpProtocols.Http1);
            k.Limits.MaxRequestBodySize = profile.Limits.MaxRequestBytes;
            k.Limits.MaxRequestHeadersTotalSize = MaxHeaderBytes;
            k.Limits.MaxRequestHeaderCount = MaxHeaderCount;
            k.Limits.MaxRequestLineSize = MaxRequestLineBytes;
            k.Limits.MaxConcurrentConnections = MaxConnections;
            k.Limits.MaxConcurrentUpgradedConnections = 0;
            k.Limits.KeepAliveTimeout = TimeSpan.FromMinutes(2);
            k.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(15);
        });
        var app = builder.Build();

        var handler = upstreamHandler ?? new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            UseProxy = false,
            ConnectTimeout = TimeSpan.FromSeconds(30),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        };
        var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        var proxy = new Proxy(profile, key, client, state, log);
        app.Run(proxy.Handle);
        app.Lifetime.ApplicationStarted.Register(() =>
        {
            // Only the VM's Firecracker (the socket's group) may connect (design D2).
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(o.SocketPath, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.GroupWrite);
            log.Event($"listening profile={profile.Name} upstream={profile.Upstream.Host}");
        });
        app.Lifetime.ApplicationStopped.Register(() => log.Event("stopped"));
        return app;
    }
}
