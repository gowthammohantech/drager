using System.Text.Json;
using SpatialBridge.Core.Json;

namespace SpatialBridge.Core.Messages;

/// <summary>Canonical encoding and tolerant decoding of control messages (CONFORMANCE.md §1).</summary>
public static class ControlMessageCoder
{
    public const int MaxPayloadBytes = 64 * 1024;

    public static byte[] Encode(ControlMessage message) => CanonicalJson.Encode(ToJson(message));

    public static string EncodeToString(ControlMessage message) => CanonicalJson.EncodeToString(ToJson(message));

    public static JsonObject ToJson(ControlMessage message) => new JsonObject().Add("kind", message.Kind).Add("body", Body(message));

    private static JsonObject Body(ControlMessage message) => message switch
    {
        Hello m => new JsonObject()
            .Add("protocolVersion", m.ProtocolVersion)
            .Add("device", new JsonObject()
                .Add("peerID", m.Device.PeerID)
                .Add("displayName", m.Device.DisplayName)
                .Add("platform", m.Device.Platform.Raw)
                .Add("model", m.Device.Model))
            .Add("capabilities", m.Capabilities)
            .Add("sessionNonce", m.SessionNonce),
        PairRequest m => new JsonObject()
            .Add("ephemeralPublicKey", m.EphemeralPublicKey)
            .Add("signingPublicKey", m.SigningPublicKey)
            .Add("displayName", m.DisplayName)
            .Add("challenge", m.Challenge),
        PairResponse m => new JsonObject()
            .Add("ephemeralPublicKey", m.EphemeralPublicKey)
            .Add("signingPublicKey", m.SigningPublicKey)
            .Add("displayName", m.DisplayName)
            .Add("challenge", m.Challenge)
            .Add("transcriptSignature", m.TranscriptSignature),
        PairConfirm m => new JsonObject()
            .Add("challengeResponse", m.ChallengeResponse)
            .Add("approvedPeerID", m.ApprovedPeerID)
            .Add("transcriptSignature", m.TranscriptSignature),
        PairReject m => new JsonObject().Add("reason", m.Reason.ToWire()),
        SessionAuth m => new JsonObject().Add("signature", m.Signature),
        TransferOffer m => new JsonObject()
            .Add("protocolVersion", m.ProtocolVersion)
            .Add("transferID", m.TransferID)
            .Add("sourcePeerID", m.SourcePeerID)
            .Add("targetPeerID", m.TargetPeerID)
            .Add("filename", m.Filename)
            .Add("contentType", m.ContentType)
            .Add("byteCount", m.ByteCount)
            .Add("sha256Hex", m.Sha256Hex)
            .Add("gesture", m.Gesture is { } g ? Gesture(g) : null)
            .Add("createdAt", m.CreatedAtMillis),
        TransferAccept m => new JsonObject().Add("transferID", m.TransferID).Add("chunkBytes", m.ChunkBytes),
        TransferReject m => new JsonObject().Add("transferID", m.TransferID).Add("reason", m.Reason.ToWire()).Add("message", m.Message),
        TransferProgress m => new JsonObject().Add("transferID", m.TransferID).Add("acknowledgedOffset", m.AcknowledgedOffset),
        TransferComplete m => new JsonObject().Add("transferID", m.TransferID).Add("sha256Hex", m.Sha256Hex).Add("byteCount", m.ByteCount),
        TransferCommitted m => new JsonObject().Add("transferID", m.TransferID).Add("savedFilename", m.SavedFilename).Add("byteCount", m.ByteCount),
        TransferErrorMessage m => new JsonObject().Add("transferID", m.TransferID).Add("code", m.Code.ToWire()).Add("message", m.Message),
        TransferCancel m => new JsonObject().Add("transferID", m.TransferID).Add("reason", m.Reason.ToWire()),
        Ping m => new JsonObject().Add("sequence", m.Sequence).Add("sentAt", m.SentAtMillis),
        Pong m => new JsonObject().Add("sequence", m.Sequence).Add("sentAt", m.SentAtMillis),
        _ => throw new ArgumentException("unknown message", nameof(message)),
    };

    private static JsonObject Gesture(ExitGesture g) => new JsonObject()
        .Add("edge", g.Edge.ToWire())
        .Add("normalizedPosition", g.NormalizedPosition)
        .Add("outwardVelocity", g.OutwardVelocity)
        .Add("travelDistance", g.TravelDistance)
        .Add("firedAt", g.FiredAtMillis);

    /// <summary>Decodes a control payload. Throws <see cref="BridgeException"/> (E012) if it is oversized or malformed.</summary>
    public static ControlMessage Decode(ReadOnlySpan<byte> payload)
    {
        if (payload.Length > MaxPayloadBytes) throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "control payload too large");
        try
        {
            using var doc = JsonDocument.Parse(payload.ToArray(), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, MaxDepth = 16 });
            return Decode(doc.RootElement);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException or KeyNotFoundException or ArgumentException)
        {
            throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "undecodable control message", ex);
        }
    }

    public static bool TryDecode(ReadOnlySpan<byte> payload, out ControlMessage? message)
    {
        try
        {
            message = Decode(payload);
            return true;
        }
        catch (BridgeException)
        {
            message = null;
            return false;
        }
    }

    private static ControlMessage Decode(JsonElement root)
    {
        var kind = root.Str("kind");
        var b = root.Obj("body");
        return kind switch
        {
            "HELLO" => new Hello(
                b.Int("protocolVersion"),
                DecodeDevice(b.Obj("device")),
                b.Arr("capabilities").EnumerateArray().Select(e => e.GetString() ?? throw new FormatException("capability")).ToArray(),
                b.Data("sessionNonce")),
            "PAIR_REQUEST" => new PairRequest(b.Data("ephemeralPublicKey"), b.Data("signingPublicKey"), b.Str("displayName"), b.Data("challenge")),
            "PAIR_RESPONSE" => new PairResponse(b.Data("ephemeralPublicKey"), b.Data("signingPublicKey"), b.Str("displayName"), b.Data("challenge"), b.Data("transcriptSignature")),
            "PAIR_CONFIRM" => new PairConfirm(b.Data("challengeResponse"), b.Str("approvedPeerID"), b.Data("transcriptSignature")),
            "PAIR_REJECT" => new PairReject(b.Code("reason")),
            "SESSION_AUTH" => new SessionAuth(b.Data("signature")),
            "TRANSFER_OFFER" => new TransferOffer(
                b.Int("protocolVersion"),
                b.Uuid("transferID"),
                b.Str("sourcePeerID"),
                b.Str("targetPeerID"),
                b.Str("filename"),
                b.Str("contentType"),
                b.Long("byteCount"),
                b.Str("sha256Hex"),
                b.TryProp("gesture", out var g) ? DecodeGesture(g) : null,
                b.Long("createdAt")),
            "TRANSFER_ACCEPT" => new TransferAccept(b.Uuid("transferID"), b.Int("chunkBytes")),
            "TRANSFER_REJECT" => new TransferReject(b.Uuid("transferID"), b.Code("reason"), b.TryProp("message", out var msg) ? msg.Str() : null),
            "PROGRESS" => new TransferProgress(b.Uuid("transferID"), b.Long("acknowledgedOffset")),
            "COMPLETE" => new TransferComplete(b.Uuid("transferID"), b.Str("sha256Hex"), b.Long("byteCount")),
            "COMMITTED" => new TransferCommitted(b.Uuid("transferID"), b.Str("savedFilename"), b.Long("byteCount")),
            "ERROR" => new TransferErrorMessage(
                b.TryProp("transferID", out var id) ? id.Uuid() : null,
                b.Code("code"),
                b.TryProp("message", out var em) ? em.Str() : null),
            "CANCEL" => new TransferCancel(b.Uuid("transferID"), b.Code("reason")),
            "PING" => new Ping(b.UInt("sequence"), b.Long("sentAt")),
            "PONG" => new Pong(b.UInt("sequence"), b.Long("sentAt")),
            _ => throw new FormatException("unknown kind"),
        };
    }

    private static DeviceInfo DecodeDevice(JsonElement d) =>
        new(d.Str("peerID"), d.Str("displayName"), new DevicePlatform(d.Str("platform")), d.Str("model"));

    private static ExitGesture DecodeGesture(JsonElement g)
    {
        if (!EdgeNames.TryParse(g.Str("edge"), out var edge)) throw new FormatException("edge");
        return new ExitGesture(edge, g.Dbl("normalizedPosition"), g.Dbl("outwardVelocity"), g.Dbl("travelDistance"), g.Long("firedAt"));
    }
}

internal static class JsonElementExtensions
{
    public static bool TryProp(this JsonElement e, string name, out JsonElement value)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new FormatException("expected object");
        if (e.TryGetProperty(name, out value) && value.ValueKind != JsonValueKind.Null) return true;
        value = default;
        return false;
    }

    public static JsonElement Prop(this JsonElement e, string name) =>
        e.TryProp(name, out var v) ? v : throw new KeyNotFoundException(name);

    public static JsonElement Obj(this JsonElement e, string name)
    {
        var v = e.Prop(name);
        return v.ValueKind == JsonValueKind.Object ? v : throw new FormatException(name);
    }

    public static JsonElement Arr(this JsonElement e, string name)
    {
        var v = e.Prop(name);
        return v.ValueKind == JsonValueKind.Array ? v : throw new FormatException(name);
    }

    public static string Str(this JsonElement e) =>
        e.ValueKind == JsonValueKind.String ? e.GetString()! : throw new FormatException("expected string");

    public static string Str(this JsonElement e, string name) => e.Prop(name).Str();

    public static int Int(this JsonElement e, string name) => e.Prop(name).GetInt32();

    public static long Long(this JsonElement e, string name) => e.Prop(name).GetInt64();

    public static uint UInt(this JsonElement e, string name) => e.Prop(name).GetUInt32();

    public static double Dbl(this JsonElement e, string name) => e.Prop(name).GetDouble();

    public static Guid Uuid(this JsonElement e) => Uuids.TryParse(e.Str(), out var id) ? id : throw new FormatException("uuid");

    public static Guid Uuid(this JsonElement e, string name) => e.Prop(name).Uuid();

    public static BridgeErrorCode Code(this JsonElement e, string name) =>
        BridgeErrorCodes.TryParse(e.Str(name), out var code) ? code : throw new FormatException("code");

    /// <summary>Standard padded base64, no whitespace (Foundation's <c>Data(base64Encoded:)</c>).</summary>
    public static byte[] Data(this JsonElement e, string name)
    {
        var s = e.Str(name);
        if (s.Length % 4 != 0 || s.Any(char.IsWhiteSpace)) throw new FormatException("base64");
        return Convert.FromBase64String(s);
    }
}
