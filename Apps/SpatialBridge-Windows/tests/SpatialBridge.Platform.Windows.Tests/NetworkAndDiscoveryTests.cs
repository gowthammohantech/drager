using System.Net;
using System.Net.Sockets;
using SpatialBridge.Core;
using SpatialBridge.Core.Services;
using SpatialBridge.Platform.Windows.Discovery;
using SpatialBridge.Platform.Windows.Interop;
using SpatialBridge.Platform.Windows.Network;

namespace SpatialBridge.Platform.Windows.Tests;

public class FirewallStatusTests
{
    [Fact]
    public void PublicNetworkProducesWarning()
    {
        var result = FirewallStatus.Evaluate([NetworkCategory.Private, NetworkCategory.Public]);
        Assert.True(result.OnPublicNetwork);
        Assert.Equal(FirewallStatus.PublicNetworkWarning, result.Warning);
    }

    [Fact]
    public void PrivateOrNoNetworkHasNoWarning()
    {
        Assert.Null(FirewallStatus.Evaluate([NetworkCategory.Private, NetworkCategory.DomainAuthenticated]).Warning);
        Assert.Null(FirewallStatus.Evaluate([]).Warning);
    }

    [Fact]
    public void NonWindowsHostIsUnknown()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }
        Assert.False(FirewallStatus.Check().Known);
        Assert.False(PackageIdentity.IsPackaged());
    }

    [WindowsFact]
    public void ChecksTheRealProfileReadOnly()
    {
        var result = FirewallStatus.Check();
        if (result.Known)
        {
            Assert.Equal(result.OnPublicNetwork, result.Warning is not null);
        }
    }
}

public class DnsSdServiceAdvertiserTests
{
    [WindowsFact]
    public async Task AdvertisesAndWithdrawsBothRoles()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var device = new AdvertisedDevice("0123456789abcdef0123456789abcdef", "SB CI " + Guid.NewGuid().ToString("N")[..6], DevicePlatform.Windows);

        await using var advertiser = new DnsSdServiceAdvertiser();
        await advertiser.AdvertiseAsync(ServiceRole.Session, device, port);
        await advertiser.AdvertiseAsync(ServiceRole.Pairing, device, port);
        Assert.Equal(2, advertiser.ActiveRoles.Count);

        await advertiser.WithdrawAsync(ServiceRole.Pairing);
        Assert.Equal([ServiceRole.Session], advertiser.ActiveRoles);
        await advertiser.WithdrawAsync(ServiceRole.Pairing); // idempotent
    }

    [Fact]
    public async Task RejectsInvalidPorts()
    {
        await using var advertiser = new DnsSdServiceAdvertiser("host");
        var device = new AdvertisedDevice("0123456789abcdef0123456789abcdef", "PC", DevicePlatform.Windows);
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => advertiser.AdvertiseAsync(ServiceRole.Session, device, 0));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => advertiser.AdvertiseAsync(ServiceRole.Session, device, 70000));
    }
}
