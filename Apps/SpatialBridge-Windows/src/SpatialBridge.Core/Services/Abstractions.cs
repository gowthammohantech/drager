using SpatialBridge.Core.Crypto;
using SpatialBridge.Core.Pairing;

namespace SpatialBridge.Core.Services;

/// <summary>The two DNS-SD instances a receiver advertises (TXT <c>role</c>).</summary>
public enum ServiceRole
{
    Session,
    Pairing,
}

public static class ServiceRoleExtensions
{
    public static string ToWire(this ServiceRole role) => role == ServiceRole.Pairing ? "pairing" : "session";
}

/// <summary>What a receiver says about itself in TXT. TXT data is an untrusted hint for the sender's UI.</summary>
public sealed record AdvertisedDevice(string PeerID, string DisplayName, DevicePlatform Platform)
{
    /// <summary>TXT keys and values (Swift ServiceAdvertiser): pid, name (≤48 chars), plat, pv, role.</summary>
    public IReadOnlyDictionary<string, string> Txt(ServiceRole role) => new Dictionary<string, string>
    {
        [BridgeProtocol.TxtKey.PeerID] = PeerID,
        [BridgeProtocol.TxtKey.DisplayName] = Text.PrefixGraphemes(DisplayName, 48),
        [BridgeProtocol.TxtKey.Platform] = Platform.Raw,
        [BridgeProtocol.TxtKey.ProtocolVersion] = BridgeProtocol.Version.ToString(System.Globalization.CultureInfo.InvariantCulture),
        [BridgeProtocol.TxtKey.Role] = role.ToWire(),
    };

    /// <summary>Instance name: the display name (≤40 chars), with " (pairing)" for the pairing role.</summary>
    public string InstanceName(ServiceRole role)
    {
        var name = Text.PrefixGraphemes(DisplayName, 40);
        return role == ServiceRole.Session ? name : name + " (pairing)";
    }
}

/// <summary>Publishes one DNS-SD instance per role. The receiver advertises the pairing role only while pairing is allowed.</summary>
public interface IServiceAdvertiser : IAsyncDisposable
{
    /// <summary>Starts (or replaces) the instance for <paramref name="role"/> on <paramref name="port"/>.</summary>
    Task AdvertiseAsync(ServiceRole role, AdvertisedDevice device, int port, CancellationToken cancellationToken = default);

    /// <summary>Removes the instance for <paramref name="role"/>. Idempotent.</summary>
    Task WithdrawAsync(ServiceRole role, CancellationToken cancellationToken = default);
}

/// <summary>Keychain-like storage for small secrets (Swift <c>SecretStore</c>). Implementations never log values.</summary>
public interface ISecretStore
{
    byte[]? Read(string key);

    void Write(string key, ReadOnlySpan<byte> value);

    void Delete(string key);

    /// <summary>Keys beginning with <paramref name="prefix"/>.</summary>
    IReadOnlyList<string> Keys(string prefix);
}

/// <summary>Public metadata of paired peers. PSKs live in <see cref="ISecretStore"/>.</summary>
public interface ITrustedPeerStore
{
    IReadOnlyList<TrustedPeer> All();

    TrustedPeer? Find(string peerID);

    void Upsert(TrustedPeer peer);

    void Remove(string peerID);
}

/// <summary>Advertises nothing (loopback tests and the CLI).</summary>
public sealed class NullServiceAdvertiser : IServiceAdvertiser
{
    public Task AdvertiseAsync(ServiceRole role, AdvertisedDevice device, int port, CancellationToken cancellationToken = default) => Task.CompletedTask;

    public Task WithdrawAsync(ServiceRole role, CancellationToken cancellationToken = default) => Task.CompletedTask;

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

public static class SecretStoreExtensions
{
    /// <summary>Loads the Ed25519 identity seed, creating and storing one on first use.</summary>
    public static DeviceIdentity LoadOrCreateIdentity(this ISecretStore secrets)
    {
        if (secrets.Read(BridgeProtocol.SecretKey.IdentitySeed) is { Length: 32 } seed) return new DeviceIdentity(seed);
        var identity = DeviceIdentity.Generate();
        secrets.Write(BridgeProtocol.SecretKey.IdentitySeed, identity.ExportSeed());
        return identity;
    }

    public static byte[]? ReadPsk(this ISecretStore secrets, string peerID) => secrets.Read(BridgeProtocol.SecretKey.PairPsk(peerID));

    public static void WritePsk(this ISecretStore secrets, string peerID, ReadOnlySpan<byte> psk)
    {
        if (psk.Length != 32) throw new ArgumentException("PSK must be 32 bytes", nameof(psk));
        secrets.Write(BridgeProtocol.SecretKey.PairPsk(peerID), psk);
    }

    public static void DeletePsk(this ISecretStore secrets, string peerID) => secrets.Delete(BridgeProtocol.SecretKey.PairPsk(peerID));
}
