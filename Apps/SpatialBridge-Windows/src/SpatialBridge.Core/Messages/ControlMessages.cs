using System.Globalization;

namespace SpatialBridge.Core.Messages;

/// <summary>HELLO device block. Never authenticated on its own.</summary>
public sealed record DeviceInfo(string PeerID, string DisplayName, DevicePlatform Platform, string Model)
{
    /// <summary>Truncates name and model to 64 characters, like Swift's initializer.</summary>
    public static DeviceInfo Create(string peerID, string displayName, DevicePlatform platform, string model) =>
        new(peerID, Text.PrefixGraphemes(displayName, 64), platform, Text.PrefixGraphemes(model, 64));
}

/// <summary>A control message: JSON <c>{"body":{...},"kind":KIND}</c>.</summary>
public abstract record ControlMessage
{
    public abstract string Kind { get; }

    public virtual Guid? TransferRef => null;
}

public sealed record Hello(int ProtocolVersion, DeviceInfo Device, IReadOnlyList<string> Capabilities, byte[] SessionNonce) : ControlMessage
{
    public override string Kind => "HELLO";
}

public sealed record PairRequest(byte[] EphemeralPublicKey, byte[] SigningPublicKey, string DisplayName, byte[] Challenge) : ControlMessage
{
    public override string Kind => "PAIR_REQUEST";
}

public sealed record PairResponse(byte[] EphemeralPublicKey, byte[] SigningPublicKey, string DisplayName, byte[] Challenge, byte[] TranscriptSignature) : ControlMessage
{
    public override string Kind => "PAIR_RESPONSE";
}

public sealed record PairConfirm(byte[] ChallengeResponse, string ApprovedPeerID, byte[] TranscriptSignature) : ControlMessage
{
    public override string Kind => "PAIR_CONFIRM";
}

public sealed record PairReject(BridgeErrorCode Reason) : ControlMessage
{
    public override string Kind => "PAIR_REJECT";
}

public sealed record SessionAuth(byte[] Signature) : ControlMessage
{
    public override string Kind => "SESSION_AUTH";
}

public sealed record TransferOffer(
    int ProtocolVersion,
    Guid TransferID,
    string SourcePeerID,
    string TargetPeerID,
    string Filename,
    string ContentType,
    long ByteCount,
    string Sha256Hex,
    ExitGesture? Gesture,
    long CreatedAtMillis) : ControlMessage
{
    public override string Kind => "TRANSFER_OFFER";
    public override Guid? TransferRef => TransferID;
}

public sealed record TransferAccept(Guid TransferID, int ChunkBytes) : ControlMessage
{
    public override string Kind => "TRANSFER_ACCEPT";
    public override Guid? TransferRef => TransferID;
}

public sealed record TransferReject(Guid TransferID, BridgeErrorCode Reason, string? Message = null) : ControlMessage
{
    public override string Kind => "TRANSFER_REJECT";
    public override Guid? TransferRef => TransferID;
}

public sealed record TransferProgress(Guid TransferID, long AcknowledgedOffset) : ControlMessage
{
    public override string Kind => "PROGRESS";
    public override Guid? TransferRef => TransferID;
}

public sealed record TransferComplete(Guid TransferID, string Sha256Hex, long ByteCount) : ControlMessage
{
    public override string Kind => "COMPLETE";
    public override Guid? TransferRef => TransferID;
}

public sealed record TransferCommitted(Guid TransferID, string SavedFilename, long ByteCount) : ControlMessage
{
    public override string Kind => "COMMITTED";
    public override Guid? TransferRef => TransferID;
}

public sealed record TransferErrorMessage(Guid? TransferID, BridgeErrorCode Code, string? Message = null) : ControlMessage
{
    public override string Kind => "ERROR";
    public override Guid? TransferRef => TransferID;
}

public sealed record TransferCancel(Guid TransferID, BridgeErrorCode Reason = BridgeErrorCode.TransferCanceled) : ControlMessage
{
    public override string Kind => "CANCEL";
    public override Guid? TransferRef => TransferID;
}

public sealed record Ping(uint Sequence, long SentAtMillis) : ControlMessage
{
    public override string Kind => "PING";
}

public sealed record Pong(uint Sequence, long SentAtMillis) : ControlMessage
{
    public override string Kind => "PONG";
}

public static class EdgeNames
{
    public static string ToWire(this Edge edge) => edge switch
    {
        Edge.Top => "top",
        Edge.Bottom => "bottom",
        Edge.Left => "left",
        Edge.Right => "right",
        _ => throw new ArgumentOutOfRangeException(nameof(edge)),
    };

    public static bool TryParse(string? s, out Edge edge)
    {
        switch (s)
        {
            case "top": edge = Edge.Top; return true;
            case "bottom": edge = Edge.Bottom; return true;
            case "left": edge = Edge.Left; return true;
            case "right": edge = Edge.Right; return true;
            default: edge = default; return false;
        }
    }
}

public static class Clock
{
    /// <summary>Integer milliseconds since the epoch, <c>round(seconds × 1000)</c>.</summary>
    public static long ToMillis(DateTimeOffset time) => MillisFromSeconds((time - DateTimeOffset.UnixEpoch).Ticks / (double)TimeSpan.TicksPerSecond);

    /// <summary>Swift's <c>Int64((seconds * 1000).rounded())</c> on the same double arithmetic.</summary>
    public static long MillisFromSeconds(double seconds)
    {
        var x = seconds * 1000;
        var magnitude = Math.Abs(x);
        var whole = Math.Floor(magnitude);
        if (magnitude - whole >= 0.5) whole += 1;
        return (long)Math.CopySign(whole, x);
    }

    public static long NowMillis(TimeProvider? provider = null) => ToMillis((provider ?? TimeProvider.System).GetUtcNow());

    public static string Iso(long millis) => DateTimeOffset.FromUnixTimeMilliseconds(millis).ToString("O", CultureInfo.InvariantCulture);
}
