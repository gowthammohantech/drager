using System.Globalization;
using System.Text;
using SpatialBridge.Core;
using SpatialBridge.Platform.Windows.Contracts;

namespace SpatialBridge.Platform.Windows.Discovery;

/// <summary>
/// Builds the TXT record and instance names for <c>_spatialbridge._tcp</c>, matching the Mac's
/// <c>ServiceAdvertiser</c>: keys <c>pid</c>, <c>name</c> (48 characters), <c>plat</c>, <c>pv</c>, <c>role</c>.
/// Pure logic, so it is tested on every host.
/// </summary>
public static class TxtRecord
{
    public const string ServiceType = "_spatialbridge._tcp";
    public const string Domain = "local";
    public const int ProtocolVersion = 1;

    /// <summary>Same as Swift <c>String(displayName.prefix(48))</c>, counted in user-perceived characters.</summary>
    public const int MaxDisplayNameCharacters = 48;

    /// <summary>Swift uses <c>prefix(40)</c> for the instance name base.</summary>
    public const int MaxInstanceBaseCharacters = 40;

    /// <summary>One DNS label (RFC 1035) and one TXT string are both capped in bytes.</summary>
    public const int MaxLabelBytes = 63;
    public const int MaxTxtEntryBytes = 255;

    public static class Keys
    {
        public const string PeerID = "pid";
        public const string DisplayName = "name";
        public const string Platform = "plat";
        public const string ProtocolVersion = "pv";
        public const string Role = "role";
    }

    /// <summary>The TXT entries, in a stable order.</summary>
    public static IReadOnlyList<KeyValuePair<string, string>> Build(AdvertisedDevice device, ServiceRole role)
    {
        ArgumentNullException.ThrowIfNull(device);
        var name = TruncateCharacters(device.DisplayName, MaxDisplayNameCharacters);
        // "name=" + value must fit one TXT string.
        name = TruncateUtf8(name, MaxTxtEntryBytes - Keys.DisplayName.Length - 1);
        var platform = string.IsNullOrEmpty(device.Platform.Raw) ? DevicePlatform.Windows.Raw : device.Platform.Raw;
        return
        [
            new(Keys.PeerID, device.PeerID),
            new(Keys.DisplayName, name),
            new(Keys.Platform, platform),
            new(Keys.ProtocolVersion, ProtocolVersion.ToString(CultureInfo.InvariantCulture)),
            new(Keys.Role, role.ToWire()),
        ];
    }

    /// <summary>
    /// Instance label: the display name (40 characters) and " (pairing)" for the pairing role, like the Mac.
    /// Dots and backslashes would split or escape the DNS name, so they become '-'. Capped at 63 UTF-8 bytes.
    /// </summary>
    public static string InstanceName(string displayName, ServiceRole role)
    {
        var cleaned = new StringBuilder(displayName.Length);
        foreach (var ch in displayName.Trim())
        {
            cleaned.Append(ch is '.' or '\\' || char.IsControl(ch) ? '-' : ch);
        }
        var name = cleaned.ToString();
        if (name.Length == 0)
        {
            name = "Windows PC";
        }
        const string pairingSuffix = " (pairing)";
        var suffix = role == ServiceRole.Pairing ? pairingSuffix : string.Empty;
        var stem = TruncateCharacters(name, MaxInstanceBaseCharacters);
        stem = TruncateUtf8(stem, MaxLabelBytes - Encoding.UTF8.GetByteCount(suffix)).TrimEnd();
        return stem + suffix;
    }

    /// <summary><c>Instance._spatialbridge._tcp.local</c>, the form <c>DnsServiceConstructInstance</c> expects.</summary>
    public static string FullServiceName(string instanceName) => $"{instanceName}.{ServiceType}.{Domain}";

    /// <summary>Keeps at most <paramref name="max"/> grapheme clusters (Swift <c>Character</c>s).</summary>
    public static string TruncateCharacters(string value, int max)
    {
        ArgumentNullException.ThrowIfNull(value);
        var info = new StringInfo(value);
        return info.LengthInTextElements <= max ? value : info.SubstringByTextElements(0, max);
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
