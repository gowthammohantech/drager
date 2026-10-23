using System.Text;
using SpatialBridge.Core;
using SpatialBridge.Platform.Windows.Contracts;
using SpatialBridge.Platform.Windows.Discovery;

namespace SpatialBridge.Platform.Windows.Tests;

public class TxtRecordTests
{
    private const string PeerID = "0123456789abcdef0123456789abcdef";

    [Fact]
    public void SessionRecordHasAllKeysInOrder()
    {
        var txt = TxtRecord.Build(new AdvertisedDevice(PeerID, "Gowtham's PC", DevicePlatform.Windows), ServiceRole.Session);
        Assert.Equal(["pid", "name", "plat", "pv", "role"], txt.Select(e => e.Key));
        Assert.Equal([PeerID, "Gowtham's PC", "windows", "1", "session"], txt.Select(e => e.Value));
    }

    [Fact]
    public void PairingRoleIsAdvertised()
    {
        var txt = TxtRecord.Build(new AdvertisedDevice(PeerID, "PC", DevicePlatform.Windows), ServiceRole.Pairing);
        Assert.Equal("pairing", txt.Single(e => e.Key == "role").Value);
    }

    [Fact]
    public void NameIsTruncatedTo48Characters()
    {
        var txt = TxtRecord.Build(new AdvertisedDevice(PeerID, new string('a', 80), DevicePlatform.Windows), ServiceRole.Session);
        Assert.Equal(new string('a', 48), txt.Single(e => e.Key == "name").Value);
    }

    [Fact]
    public void TruncationKeepsGraphemeClusters()
    {
        // 47 ASCII letters then a family emoji (one Character in Swift, 11 UTF-16 units) then more.
        const string family = "\U0001F468\u200D\U0001F469\u200D\U0001F467";
        var name = new string('b', 47) + family + "tail";
        var truncated = TxtRecord.TruncateCharacters(name, 48);
        Assert.Equal(new string('b', 47) + family, truncated);
    }

    [Fact]
    public void NameFitsOneTxtString()
    {
        const string family = "\U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F466"; // 25 UTF-8 bytes
        var name = string.Concat(Enumerable.Repeat(family, 48));
        var value = TxtRecord.Build(new AdvertisedDevice(PeerID, name, DevicePlatform.Windows), ServiceRole.Session).Single(e => e.Key == "name").Value;
        Assert.True(Encoding.UTF8.GetByteCount("name=" + value) <= 255);
        Assert.Equal(0, value.Length % family.Length);
    }

    [Fact]
    public void InstanceNamesFollowTheMac()
    {
        Assert.Equal("Desk PC", TxtRecord.InstanceName("Desk PC", ServiceRole.Session));
        Assert.Equal("Desk PC (pairing)", TxtRecord.InstanceName("Desk PC", ServiceRole.Pairing));
        Assert.Equal(new string('x', 40), TxtRecord.InstanceName(new string('x', 70), ServiceRole.Session));
    }

    [Fact]
    public void InstanceNameAvoidsDnsSeparators()
    {
        Assert.Equal("my-pc-lan", TxtRecord.InstanceName("my.pc\\lan", ServiceRole.Session));
        Assert.Equal("Windows PC", TxtRecord.InstanceName("   ", ServiceRole.Session));
    }

    [Fact]
    public void InstanceNameFitsOneDnsLabel()
    {
        var name = string.Concat(Enumerable.Repeat("\u00E9", 40)); // 80 UTF-8 bytes
        var label = TxtRecord.InstanceName(name, ServiceRole.Pairing);
        Assert.EndsWith(" (pairing)", label, StringComparison.Ordinal);
        Assert.True(Encoding.UTF8.GetByteCount(label) <= 63);
    }

    [Fact]
    public void FullServiceNameUsesLocalDomain()
    {
        Assert.Equal("Desk PC._spatialbridge._tcp.local", TxtRecord.FullServiceName("Desk PC"));
    }
}
