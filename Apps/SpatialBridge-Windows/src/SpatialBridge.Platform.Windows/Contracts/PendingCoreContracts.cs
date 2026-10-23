using SpatialBridge.Core;

// Lane WU's best guess at the platform seams Lane N is adding to SpatialBridge.Core.
// They live here, in their own namespace, so nothing collides while Core is in flux.
// XP2b reconciliation: delete this file, switch the usings to SpatialBridge.Core and
// adapt the Windows implementations to Core's final shapes.
namespace SpatialBridge.Platform.Windows.Contracts;

/// <summary>The two DNS-SD instances a receiver advertises (PROTOCOL.md, Transport). TXT <c>role</c> values.</summary>
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
public sealed record AdvertisedDevice(string PeerID, string DisplayName, DevicePlatform Platform);

/// <summary>Publishes one DNS-SD instance per role. Advertising the pairing role only while pairing is allowed is the caller's job.</summary>
public interface IServiceAdvertiser : IAsyncDisposable
{
    /// <summary>Starts (or replaces) the instance for <paramref name="role"/> on <paramref name="port"/>. Completes when the registration is confirmed.</summary>
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

/// <summary>Durably moves a fully verified staged file into the destination (Swift <c>DestinationStore.commit</c>).</summary>
public interface IFileCommitter
{
    /// <summary>
    /// Flushes <paramref name="stagedPath"/>, then moves it to <paramref name="destinationFolder"/> as
    /// <paramref name="saveName"/> (already a valid Windows save name), adding " 2", " 3"… on collision.
    /// Never overwrites. Returns the final full path. Throws <see cref="BridgeException"/>.
    /// </summary>
    Task<string> CommitAsync(string stagedPath, string destinationFolder, string saveName, CancellationToken cancellationToken = default);
}
