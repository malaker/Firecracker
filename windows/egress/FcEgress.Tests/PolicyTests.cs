using System.Net;
using FcEgress.Policy;

namespace FcEgress.Tests;

public class PolicyTests
{
    private const string HostLan = "192.168.51.85";
    private const string HostNat = "172.31.0.1";

    private static IReadOnlyList<Cidr> FakeHost() =>
        new[] { Cidr.Parse("127.0.0.0/8"), Cidr.Parse("0.0.0.0/8"), Cidr.Parse(HostLan), Cidr.Parse(HostNat), Cidr.Parse("203.0.113.7") };

    private static EgressPolicy Policy(params string[] allow) =>
        new(allow.Select(Cidr.Parse).ToArray(), FakeHost, (h, _) => throw new InvalidOperationException($"unexpected lookup of {h}"));

    private static EgressPolicy Resolving(Dictionary<string, string[]> dns, params string[] allow) =>
        new(allow.Select(Cidr.Parse).ToArray(), FakeHost,
            (h, _) => dns.TryGetValue(h, out var a) ? Task.FromResult(a.Select(IPAddress.Parse).ToArray()) : throw new System.Net.Sockets.SocketException(11001));

    // 2.1 strict parsing and host-name checks
    [Theory]
    [InlineData("0x7f.0.0.1")]
    [InlineData("2130706433")]
    [InlineData("127.1")]
    [InlineData("01.2.3.4")]
    [InlineData("1.2.3.256")]
    [InlineData("1.2.3.4.5")]
    [InlineData("1..3.4")]
    public void Strict_parser_rejects_alternative_ipv4_forms(string s) => Assert.False(Ipv4.TryParseStrict(s, out _));

    [Theory]
    [InlineData("1.1.1.1", 0x01010101u)]
    [InlineData("0.0.0.0", 0u)]
    [InlineData("255.255.255.255", 0xFFFFFFFFu)]
    public void Strict_parser_accepts_dotted_quads(string s, uint expected)
    {
        Assert.True(Ipv4.TryParseStrict(s, out var a));
        Assert.Equal(expected, a);
    }

    [Theory]
    [InlineData("my_host.example")]
    [InlineData("with space.example")]
    [InlineData("")]
    [InlineData("0x7f.0.0.1")]
    [InlineData("2130706433")]
    [InlineData("127.1")]
    [InlineData("-bad.example")]
    [InlineData("a..b")]
    public void Host_name_check_rejects_bad_names(string s) => Assert.False(HostName.IsValid(s));

    [Fact]
    public void Host_name_check_rejects_254_characters()
    {
        string name = string.Join('.', Enumerable.Repeat(new string('a', 63), 3)) + "." + new string('a', 62);
        Assert.Equal(254, name.Length);
        Assert.False(HostName.IsValid(name));
        Assert.True(HostName.IsValid(name[1..]));
    }

    [Theory]
    [InlineData("example.com")]
    [InlineData("one.one.one.one")]
    [InlineData("xn--bcher-kva.example")]
    [InlineData("localhost")]
    public void Host_name_check_accepts_valid_names(string s) => Assert.True(HostName.IsValid(s));

    [Theory]
    [InlineData("0x7f.0.0.1")]
    [InlineData("2130706433")]
    [InlineData("127.1")]
    [InlineData("01.2.3.4")]
    [InlineData("my_host.example")]
    public async Task Policy_denies_invalid_hosts_without_lookup(string host)
    {
        var d = await Policy().DecideAsync(host, 443);
        Assert.False(d.Allowed);
        Assert.Equal("invalid-host", d.Reason);
    }

    // 2.2 always-blocked destinations and the allowlist
    [Theory]
    [InlineData(HostLan)]
    [InlineData(HostNat)]
    [InlineData("127.0.0.1")]
    [InlineData("0.0.0.0")]
    [InlineData("10.1.2.3")]
    [InlineData("172.16.0.1")]
    [InlineData("192.168.51.1")]
    [InlineData("169.254.169.254")]
    [InlineData("100.64.0.1")]
    [InlineData("198.18.0.1")]
    [InlineData("224.0.0.251")]
    [InlineData("255.255.255.255")]
    [InlineData("192.0.0.170")]
    public async Task Always_blocked_destinations_are_denied(string ip) =>
        Assert.False((await Policy().DecideAsync(ip, 443)).Allowed);

    [Fact]
    public async Task Host_listening_port_on_lan_ip_is_denied_as_host_address()
    {
        var d = await Policy().DecideAsync(HostLan, 2179);
        Assert.False(d.Allowed);
        Assert.Equal("host-address", d.Reason);
    }

    [Theory]
    [InlineData("[2606:4700:4700::1111]")]
    [InlineData("2606:4700:4700::1111")]
    [InlineData("::1")]
    public async Task Ipv6_destinations_are_denied(string host)
    {
        var d = await Policy().DecideAsync(host, 443);
        Assert.False(d.Allowed);
        Assert.Equal("ipv6-denied", d.Reason);
    }

    [Fact]
    public async Task Public_destination_is_allowed_without_allowlist() =>
        Assert.True((await Policy().DecideAsync("8.8.8.8", 443)).Allowed);

    [Fact]
    public async Task Destination_outside_allowlist_is_denied()
    {
        var d = await Policy("1.1.1.1/32").DecideAsync("8.8.8.8", 443);
        Assert.False(d.Allowed);
        Assert.Equal("not-allowlisted", d.Reason);
    }

    [Fact]
    public async Task Destination_inside_allowlist_is_allowed() =>
        Assert.True((await Policy("1.1.1.1/32").DecideAsync("1.1.1.1", 443)).Allowed);

    [Fact]
    public async Task Allowlisted_private_range_overrides_blocked_range() =>
        Assert.True((await Policy("10.0.0.0/8").DecideAsync("10.1.2.3", 443)).Allowed);

    [Theory]
    [InlineData(HostLan)]
    [InlineData("127.0.0.1")]
    public async Task Allowlisted_host_address_is_still_denied(string ip)
    {
        var d = await Policy($"{ip}/32", "192.168.0.0/16", "127.0.0.0/8").DecideAsync(ip, 443);
        Assert.False(d.Allowed);
        Assert.Equal("host-address", d.Reason);
    }

    [Fact]
    public async Task Allowlist_documentation_range_example()
    {
        var p = Policy("203.0.113.0/24");
        Assert.True((await p.DecideAsync("203.0.113.10", 443)).Allowed);
        Assert.False((await p.DecideAsync("198.51.100.1", 443)).Allowed);
    }

    [Fact]
    public void Host_addresses_are_read_on_every_decision()
    {
        var current = new List<Cidr>();
        var p = new EgressPolicy([], () => current);
        Assert.True(p.IsPermitted(Ipv4.FromIPAddress(IPAddress.Parse("93.184.215.14")), out _));
        current.Add(Cidr.Parse("93.184.215.14/32"));
        Assert.False(p.IsPermitted(Ipv4.FromIPAddress(IPAddress.Parse("93.184.215.14")), out var reason));
        Assert.Equal("host-address", reason);
    }

    // 2.3 resolution and selection
    [Fact]
    public async Task Name_resolving_to_blocked_address_is_denied_with_that_address()
    {
        var d = await Resolving(new() { ["intranet.example"] = ["10.0.0.5"] }).DecideAsync("intranet.example", 443);
        Assert.False(d.Allowed);
        Assert.Equal("10.0.0.5", d.AddressText);
        Assert.StartsWith("blocked-range", d.Reason);
    }

    [Fact]
    public async Task Name_resolving_to_host_address_is_denied()
    {
        var d = await Resolving(new() { ["rebind.example"] = [HostLan] }).DecideAsync("rebind.example", 443);
        Assert.False(d.Allowed);
        Assert.Equal("host-address", d.Reason);
    }

    [Fact]
    public async Task Mixed_resolution_picks_only_a_permitted_address()
    {
        var d = await Resolving(new() { ["mixed.example"] = ["192.168.1.10", "::1", "93.184.215.14", "10.0.0.1"] }).DecideAsync("mixed.example", 443);
        Assert.True(d.Allowed);
        Assert.Equal("93.184.215.14", d.AddressText);
    }

    [Fact]
    public async Task Allowlist_applies_to_resolved_addresses()
    {
        var dns = new Dictionary<string, string[]> { ["one.one.one.one"] = ["1.0.0.1", "1.1.1.1"], ["dns.google"] = ["8.8.8.8"] };
        var hit = await Resolving(dns, "1.1.1.1/32").DecideAsync("one.one.one.one", 443);
        Assert.True(hit.Allowed);
        Assert.Equal("1.1.1.1", hit.AddressText);
        Assert.False((await Resolving(dns, "1.1.1.1/32").DecideAsync("dns.google", 443)).Allowed);
    }

    [Fact]
    public async Task Ipv6_only_name_is_denied()
    {
        var d = await Resolving(new() { ["v6.example"] = ["2606:4700:4700::1111"] }).DecideAsync("v6.example", 443);
        Assert.False(d.Allowed);
        Assert.Equal("no-ipv4-address", d.Reason);
    }

    [Fact]
    public async Task Unresolvable_name_is_denied() =>
        Assert.Equal("resolve-failed", (await Resolving([]).DecideAsync("nx.example", 443)).Reason);

    [Fact]
    public async Task Sentinel_name_is_denied_without_lookup() =>
        Assert.Equal("sentinel", (await Policy().DecideAsync("fc-egress.invalid", 1)).Reason);
}
