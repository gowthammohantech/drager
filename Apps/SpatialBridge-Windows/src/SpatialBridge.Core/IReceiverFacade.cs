namespace SpatialBridge.Core;

/// <summary>Platform values carried in HELLO and TXT <c>plat</c> (ADR-015). Unknown values are kept as-is.</summary>
public readonly record struct DevicePlatform(string Raw)
{
    public static readonly DevicePlatform IOS = new("iOS");
    public static readonly DevicePlatform MacOS = new("macOS");
    public static readonly DevicePlatform Android = new("android");
    public static readonly DevicePlatform Windows = new("windows");

    public override string ToString() => Raw;
}

/// <summary>Wire error codes E001–E014 (BridgeError.Code). Never invent new ones.</summary>
public enum BridgeErrorCode
{
    LocalNetworkDenied = 1,
    NoPeer = 2,
    PairingRejected = 3,
    AuthenticationFailed = 4,
    PeerLost = 5,
    UnsupportedFile = 6,
    SizeLimit = 7,
    InsufficientStorage = 8,
    DestinationPermissionExpired = 9,
    HashMismatch = 10,
    WriteFailed = 11,
    ProtocolMismatch = 12,
    TransferCanceled = 13,
    Timeout = 14,
}

public static class BridgeErrorCodeExtensions
{
    public static string ToWire(this BridgeErrorCode code) => $"E{(int)code:D3}";
}

/// <summary>Edge of the sender's screen a gesture left through (top-left origin).</summary>
public enum Edge { Top, Bottom, Left, Right }

public sealed record ExitGesture(Edge Edge, double NormalizedPosition, double OutwardVelocity, double TravelDistance, long FiredAtMillis);

public sealed record TrustedPeerInfo(string PeerID, string DisplayName, DevicePlatform Platform, DateTimeOffset PairedAt);

/// <summary>Shown to the user to approve a pairing; the user compares <see cref="Code"/> with the phone.</summary>
public sealed record PairingPrompt(string PeerDisplayName, DevicePlatform Platform, string Code);

/// <summary>Events the tray UI reacts to. Success is only ever reported via <see cref="TransferCommitted"/>.</summary>
public abstract record ReceiverEvent
{
    private ReceiverEvent() { }

    public sealed record AvailabilityChanged(bool Advertising) : ReceiverEvent;
    public sealed record PeerConnected(string PeerID, string DisplayName) : ReceiverEvent;
    public sealed record PeerDisconnected(string PeerID) : ReceiverEvent;

    /// <summary>Raised on TRANSFER_ACCEPT; starts the arrival overlay. <see cref="Gesture"/> is null if the sender sent none.</summary>
    public sealed record TransferIncoming(Guid TransferID, string PeerDisplayName, long ByteCount, ExitGesture? Gesture) : ReceiverEvent;
    public sealed record TransferProgress(Guid TransferID, long ReceivedBytes, long TotalBytes) : ReceiverEvent;

    /// <summary>The file is fsynced and renamed into the destination; COMMITTED is about to be sent.</summary>
    public sealed record TransferCommitted(Guid TransferID, string SavedPath, long ByteCount) : ReceiverEvent;
    public sealed record TransferFailed(Guid TransferID, BridgeErrorCode Code) : ReceiverEvent;
    public sealed record PairingFailed(BridgeErrorCode Code) : ReceiverEvent;
    public sealed record Paired(TrustedPeerInfo Peer) : ReceiverEvent;
}

/// <summary>
/// Everything the Windows tray UI needs from the protocol core. The app shell is built against a fake
/// (XP1 lane WU) and wired to the real ReceiverService in XP2b.
/// </summary>
public interface IReceiverFacade : IAsyncDisposable
{
    event EventHandler<ReceiverEvent>? EventRaised;

    /// <summary>Called when a phone asks to pair; return true only if the user confirmed the codes match.</summary>
    Func<PairingPrompt, CancellationToken, Task<bool>>? PairingApprover { get; set; }

    bool IsAvailable { get; }
    bool AllowPairing { get; }
    string? DestinationFolder { get; }
    IReadOnlyList<TrustedPeerInfo> TrustedPeers { get; }

    Task SetAvailableAsync(bool available, CancellationToken cancellationToken = default);
    Task SetAllowPairingAsync(bool allow, CancellationToken cancellationToken = default);
    Task SetDestinationFolderAsync(string folder, CancellationToken cancellationToken = default);
    Task UnpairAsync(string peerID, CancellationToken cancellationToken = default);
}
