using System.Xml;

namespace FcRelay;

// .NET Framework ignores HTTP_PROXY/HTTPS_PROXY, so on the iis-netfx flavours the relay is
// set as <system.net><defaultProxy> in both machine.config files (32- and 64-bit).
internal static class NetfxProxyConfig
{
    private static readonly string[] MachineConfigs =
    [
        @"Microsoft.NET\Framework\v4.0.30319\Config\machine.config",
        @"Microsoft.NET\Framework64\v4.0.30319\Config\machine.config",
    ];

    public static int Apply(string proxyUrl)
    {
        if (!Uri.TryCreate(proxyUrl, UriKind.Absolute, out var uri) || uri.Scheme != "http")
        {
            Console.Error.WriteLine($"fc-relay: invalid proxy URL '{proxyUrl}'");
            return 2;
        }
        string windir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        int updated = 0;
        foreach (var rel in MachineConfigs)
        {
            string path = Path.Combine(windir, rel);
            if (!File.Exists(path)) continue;
            Update(path, uri.ToString().TrimEnd('/'));
            Console.WriteLine($"fc-relay: proxy set in {path}");
            updated++;
        }
        if (updated == 0) Console.WriteLine("fc-relay: no .NET Framework machine.config found; nothing to do");
        return 0;
    }

    private static void Update(string path, string proxyUrl)
    {
        var doc = new XmlDocument { PreserveWhitespace = true };
        doc.Load(path);
        var configuration = doc.DocumentElement ?? throw new InvalidDataException($"{path} has no root element");
        var systemNet = configuration["system.net"] ?? (XmlElement)configuration.AppendChild(doc.CreateElement("system.net"))!;
        if (systemNet["defaultProxy"] is { } old) systemNet.RemoveChild(old);

        var defaultProxy = doc.CreateElement("defaultProxy");
        defaultProxy.SetAttribute("enabled", "true");
        defaultProxy.SetAttribute("useDefaultCredentials", "false");
        var proxy = doc.CreateElement("proxy");
        proxy.SetAttribute("usesystemdefault", "False");
        proxy.SetAttribute("proxyaddress", proxyUrl);
        proxy.SetAttribute("bypassonlocal", "True");
        defaultProxy.AppendChild(proxy);
        systemNet.AppendChild(defaultProxy);
        doc.Save(path);
    }
}
