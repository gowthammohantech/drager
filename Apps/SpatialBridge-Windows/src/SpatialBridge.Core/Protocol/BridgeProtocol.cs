namespace SpatialBridge.Core;

/// <summary>Protocol-wide constants (Swift <c>BridgeProtocol</c>).</summary>
public static class BridgeProtocol
{
    public const int Version = 1;
    public const string ServiceType = "_spatialbridge._tcp";
    public const string ServiceDomain = "local.";

    public const string PairingCapability = "pair.v1";
    public const string SessionCapability = "session.v1";
    public static readonly IReadOnlyList<string> DefaultCapabilities = ["transfer.v1", "gesture.v1"];

    public static class TxtKey
    {
        public const string PeerID = "pid";
        public const string DisplayName = "name";
        public const string Platform = "plat";
        public const string ProtocolVersion = "pv";
        public const string Role = "role";
    }

    public static class SecretKey
    {
        public const string IdentitySeed = "identity.ed25519.seed";
        public const string PairPskPrefix = "pair.psk.";

        public static string PairPsk(string peerID) => PairPskPrefix + peerID;
    }
}

/// <summary>Frame and transfer limits; defaults follow FRD §4 and CONFORMANCE.md §4.</summary>
public sealed record TransferLimits
{
    public int MaxControlFrameBytes { get; init; } = 64 * 1024;
    public int ChunkBytes { get; init; } = 256 * 1024;
    public int MaxChunkBytes { get; init; } = 512 * 1024;
    public long MaxFileBytes { get; init; } = 100L * 1024 * 1024;
    public int SendWindow { get; init; } = 4;
    public TimeSpan HandshakeTimeout { get; init; } = TimeSpan.FromSeconds(30);
    public TimeSpan TransferIdleTimeout { get; init; } = TimeSpan.FromSeconds(30);
    public long DiskHeadroomBytes { get; init; } = 64L * 1024 * 1024;
    public TimeSpan StagingRetention { get; init; } = TimeSpan.FromHours(24);

    public static TransferLimits Default { get; } = new();
}

/// <summary>Handshake timeouts (CONFORMANCE.md §4).</summary>
public sealed record ProtocolTimeouts
{
    public TimeSpan Handshake { get; init; } = TimeSpan.FromSeconds(30);
    public TimeSpan SessionAuth { get; init; } = TimeSpan.FromSeconds(15);
    public TimeSpan UserDecision { get; init; } = TimeSpan.FromSeconds(120);

    public static ProtocolTimeouts Default { get; } = new();
}

public static class PeerIds
{
    /// <summary>32 lowercase hex characters.</summary>
    public static bool IsValid(string? value) =>
        value is { Length: 32 } && value.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    public static string ShortForm(string peerID) => peerID.Length <= 8 ? peerID : peerID[..8];

    /// <summary><c>ab12 cd34 ef56 7890</c>.</summary>
    public static string Fingerprint(string peerID)
    {
        var raw = peerID.Length > 16 ? peerID[..16] : peerID;
        return string.Join(' ', Enumerable.Range(0, (raw.Length + 3) / 4).Select(i => raw.Substring(i * 4, Math.Min(4, raw.Length - (i * 4)))));
    }
}

public static class Uuids
{
    public static string ToWire(Guid id) => id.ToString("D").ToUpperInvariant();

    public static bool TryParse(string? s, out Guid id)
    {
        id = default;
        return s is { Length: 36 } && Guid.TryParseExact(s, "D", out id);
    }

    /// <summary>RFC 4122 byte order (CONFORMANCE.md §2).</summary>
    public static void Write(Guid id, Span<byte> destination)
    {
        if (!id.TryWriteBytes(destination, bigEndian: true, out _)) throw new ArgumentException("destination too small", nameof(destination));
    }

    public static Guid Read(ReadOnlySpan<byte> source) => new(source[..16], bigEndian: true);
}
