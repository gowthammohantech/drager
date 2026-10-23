using System.Globalization;
using System.Text;
using SpatialBridge.Core;
using SpatialBridge.Core.Services;

namespace SpatialBridge.Platform.Windows.Discovery;

/// <summary>
/// DNS-SD wire shapes for <c>_spatialbridge._tcp</c>. The values come from Core's
/// <see cref="AdvertisedDevice.Txt"/> and <see cref="AdvertisedDevice.InstanceName"/> (the Mac's
/// <c>ServiceAdvertiser</c>); this class only adds what dnsapi needs on top: a stable key order,
/// byte caps (one TXT string, one DNS label) and DNS-safe instance labels.
/// Pure logic, so it is tested on every host.
/// </summary>
public static class TxtRecord
{
    public const string ServiceType = "_spatialbridge._tcp";
    public const string Domain = "local";
    public const int ProtocolVersion = BridgeProtocol.Version;

    /// <summary>Same as Swift <c>String(displayName.prefix(48))</c>, counted in user-perceived characters.</summary>
    public const int MaxDisplayNameCharacters = 48;

    /// <summary>Swift uses <c>prefix(40)</c> for the instance name base.</summary>
    public const int MaxInstanceBaseCharacters = 40;

    /// <summary>One DNS label (RFC 1035) and one TXT string are both capped in bytes.</summary>
    public const int MaxLabelBytes = 63;
    public const int MaxTxtEntryBytes = 255;

    private const string PairingSuffix = " (pairing)";
    private const string FallbackInstanceName = "Windows PC";

    public static class Keys
    {
        public const string PeerID = BridgeProtocol.TxtKey.PeerID;
        public const string DisplayName = BridgeProtocol.TxtKey.DisplayName;
        public const string Platform = BridgeProtocol.TxtKey.Platform;
        public const string ProtocolVersion = BridgeProtocol.TxtKey.ProtocolVersion;
        public const string Role = BridgeProtocol.TxtKey.Role;
    }

    private static readonly string[] KeyOrder = [Keys.PeerID, Keys.DisplayName, Keys.Platform, Keys.ProtocolVersion, Keys.Role];

    /// <summary>The TXT entries from Core's <see cref="AdvertisedDevice.Txt"/>, in a stable order, each fitting one TXT string.</summary>
    public static IReadOnlyList<KeyValuePair<string, string>> Build(AdvertisedDevice device, ServiceRole role)
    {
        ArgumentNullException.ThrowIfNull(device);
        if (string.IsNullOrEmpty(device.Platform.Raw))
        {
            device = device with { Platform = DevicePlatform.Windows };
        }
        var txt = device.Txt(role);
        var entries = new List<KeyValuePair<string, string>>(txt.Count);
        foreach (var key in KeyOrder.Where(txt.ContainsKey).Concat(txt.Keys.Except(KeyOrder, StringComparer.Ordinal).Order(StringComparer.Ordinal)))
        {
            // "key=" + value must fit one TXT string.
            entries.Add(new(key, TruncateUtf8(txt[key], MaxTxtEntryBytes - Encoding.UTF8.GetByteCount(key) - 1)));
        }
        return entries;
    }

    /// <summary>
    /// Instance label: Core's <see cref="AdvertisedDevice.InstanceName"/> (40 characters, " (pairing)" for the
    /// pairing role). Dots and backslashes would split or escape the DNS name, so they become '-'. Capped at 63 UTF-8 bytes.
    /// </summary>
    public static string InstanceName(AdvertisedDevice device, ServiceRole role)
    {
        ArgumentNullException.ThrowIfNull(device);
        return InstanceName(device.DisplayName, role);
    }

    /// <inheritdoc cref="InstanceName(AdvertisedDevice, ServiceRole)"/>
    public static string InstanceName(string displayName, ServiceRole role)
    {
        ArgumentNullException.ThrowIfNull(displayName);
        var cleaned = new StringBuilder(displayName.Length);
        foreach (var ch in displayName.Trim())
        {
            cleaned.Append(ch is '.' or '\\' || char.IsControl(ch) ? '-' : ch);
        }
        var name = cleaned.Length == 0 ? FallbackInstanceName : cleaned.ToString();
        // The session form is the bare (≤ 40 character) base; the pairing suffix is added after the byte cap.
        var stem = new AdvertisedDevice(string.Empty, name, DevicePlatform.Windows).InstanceName(ServiceRole.Session);
        var suffix = role == ServiceRole.Pairing ? PairingSuffix : string.Empty;
        stem = TruncateUtf8(stem, MaxLabelBytes - Encoding.UTF8.GetByteCount(suffix)).TrimEnd();
        return stem + suffix;
    }

    /// <summary><c>Instance._spatialbridge._tcp.local</c>, the form <c>DnsServiceConstructInstance</c> expects.</summary>
    public static string FullServiceName(string instanceName) => $"{instanceName}.{ServiceType}.{Domain}";

    /// <summary>Keeps at most <paramref name="max"/> grapheme clusters (Swift <c>Character</c>s).</summary>
    public static string TruncateCharacters(string value, int max)
    {
        ArgumentNullException.ThrowIfNull(value);
        return Text.PrefixGraphemes(value, max);
    }

    /// <summary>Drops whole grapheme clusters from the end until the UTF-8 form fits in <paramref name="maxBytes"/>.</summary>
    public static string TruncateUtf8(string value, int maxBytes)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (Encoding.UTF8.GetByteCount(value) <= maxBytes)
        {
            return value;
        }
        var builder = new StringBuilder();
        var bytes = 0;
        var enumerator = StringInfo.GetTextElementEnumerator(value);
        while (enumerator.MoveNext())
        {
            var element = enumerator.GetTextElement();
            var count = Encoding.UTF8.GetByteCount(element);
            if (bytes + count > maxBytes)
            {
                break;
            }
            builder.Append(element);
            bytes += count;
        }
        return builder.ToString();
    }
}
