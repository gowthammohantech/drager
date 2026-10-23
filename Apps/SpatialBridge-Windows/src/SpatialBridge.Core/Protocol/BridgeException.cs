namespace SpatialBridge.Core;

/// <summary>A protocol failure carrying a wire error code. <see cref="Exception.Message"/> is developer-facing and never holds secrets or filenames.</summary>
public sealed class BridgeException : Exception
{
    public BridgeException(BridgeErrorCode code, string? detail = null)
        : base(detail ?? code.ToWire())
    {
        Code = code;
    }

    public BridgeException(BridgeErrorCode code, string detail, Exception inner)
        : base(detail, inner)
    {
        Code = code;
    }

    public BridgeException() : this(BridgeErrorCode.ProtocolMismatch) { }

    public BridgeException(string message) : this(BridgeErrorCode.ProtocolMismatch, message) { }

    public BridgeException(string message, Exception innerException) : this(BridgeErrorCode.ProtocolMismatch, message, innerException) { }

    public BridgeErrorCode Code { get; }

    /// <summary>Maps any exception to a code, like Swift's <c>BridgeError.wrap</c>.</summary>
    public static BridgeErrorCode Classify(Exception error, bool networkContext) => error switch
    {
        BridgeException b => b.Code,
        OperationCanceledException => BridgeErrorCode.TransferCanceled,
        AggregateException { InnerException: { } inner } => Classify(inner, networkContext),
        IOException io when IsDiskFull(io) => BridgeErrorCode.InsufficientStorage,
        UnauthorizedAccessException when !networkContext => BridgeErrorCode.DestinationPermissionExpired,
        _ => networkContext ? BridgeErrorCode.PeerLost : BridgeErrorCode.WriteFailed,
    };

    private static bool IsDiskFull(IOException io) =>
        (io.HResult & 0xFFFF) is 0x70 or 0x27 || io.HResult == 28 /* ENOSPC */;
}

public static class BridgeErrorCodes
{
    public static bool TryParse(string? wire, out BridgeErrorCode code)
    {
        code = default;
        if (wire is not { Length: 4 } || wire[0] != 'E' || !int.TryParse(wire.AsSpan(1), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var n) || n < 1 || n > 14)
        {
            return false;
        }
        code = (BridgeErrorCode)n;
        return true;
    }

    public static int ExitCode(this BridgeErrorCode code) => (int)code;
}
