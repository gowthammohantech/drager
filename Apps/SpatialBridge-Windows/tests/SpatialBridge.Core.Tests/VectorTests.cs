using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SpatialBridge.Core.Calibration;
using SpatialBridge.Core.Crypto;
using SpatialBridge.Core.Framing;
using SpatialBridge.Core.Json;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Transfer;

namespace SpatialBridge.Core.Tests;

public sealed class FramingVectorTests
{
    public static IEnumerable<object[]> Cases => Vectors.Names("framing");

    [Theory]
    [MemberData(nameof(Cases))]
    public void Framing(string name)
    {
        var c = Vectors.Case("framing", name);
        if (c.B("invalid"))
        {
            if (c.S("direction") == "encode")
            {
                var length = c.GetProperty("payloadLength").GetInt32();
                Frame frame = c.GetProperty("frameType").GetInt32() == 1
                    ? new ControlFrame(new byte[length])
                    : new ChunkFrame(Guid.Empty, 0, 0, new byte[length]);
                var ex = Assert.Throws<FrameCodecException>(() => FrameCodec.Encode(frame));
                Assert.Equal(c.S("error"), Camel(ex.Error));
                return;
            }
            var decoder = new FrameDecoder();
            decoder.Append(c.H("hex"));
            if (c.S("error") == "incomplete")
            {
                Assert.Null(decoder.Next());
                return;
            }
            var err = Assert.Throws<FrameCodecException>(() => decoder.Next());
            Assert.Equal(c.S("error"), Camel(err.Error));
            Assert.Equal(c.S("bridgeErrorCode"), err.ToBridge().Code.ToWire());
            return;
        }

        Frame expected;
        byte[] payload = c.Has("payloadPattern")
            ? Enumerable.Range(0, c.GetProperty("payloadLength").GetInt32()).Select(i => (byte)(i % 256)).ToArray()
            : c.H("payload");
        if (c.GetProperty("frameType").GetInt32() == 1)
        {
            expected = new ControlFrame(payload);
        }
        else
        {
            Assert.True(Uuids.TryParse(c.S("transferID"), out var id));
            expected = new ChunkFrame(id, c.GetProperty("sequence").GetUInt32(), c.GetProperty("offset").GetUInt64(), payload);
        }
        var encoded = FrameCodec.Encode(expected);
        if (c.Has("hex"))
        {
            Assert.Equal(c.S("hex"), Convert.ToHexStringLower(encoded));
        }
        else
        {
            Assert.Equal(c.S("headerHex"), Convert.ToHexStringLower(encoded.AsSpan(0, c.S("headerHex").Length / 2)));
            Assert.Equal(c.S("frameSha256"), Convert.ToHexStringLower(SHA256.HashData(encoded)));
            Assert.Equal(c.S("payloadSha256"), Convert.ToHexStringLower(SHA256.HashData(payload)));
            Assert.Equal(c.GetProperty("frameLength").GetInt32(), encoded.Length);
        }

        var dec = new FrameDecoder();
        dec.Append(encoded);
        var decoded = dec.Next();
        Assert.NotNull(decoded);
        switch (decoded)
        {
            case ControlFrame cf:
                Assert.Equal(payload, cf.Payload);
                break;
            case ChunkFrame kf:
                var ek = (ChunkFrame)expected;
                Assert.Equal(ek.TransferID, kf.TransferID);
                Assert.Equal(ek.Sequence, kf.Sequence);
                Assert.Equal(ek.Offset, kf.Offset);
                Assert.Equal(payload, kf.Payload.ToArray());
                break;
        }
        Assert.Equal(0, dec.BufferedByteCount);
    }

    private static string Camel(FrameError e) => char.ToLowerInvariant(e.ToString()[0]) + e.ToString()[1..];
}

public sealed class ControlMessageVectorTests
{
    public static IEnumerable<object[]> Cases => Vectors.Names("control-messages");

    [Theory]
    [MemberData(nameof(Cases))]
    public void ControlMessage(string name)
    {
        var c = Vectors.Case("control-messages", name);
        var json = c.S("json");
        Assert.Equal(c.S("hex"), Convert.ToHexStringLower(Encoding.UTF8.GetBytes(json)));

        var input = c.B("decodeOnly") ? c.S("inputJson") : json;
        var message = ControlMessageCoder.Decode(Encoding.UTF8.GetBytes(input));
        Assert.Equal(c.S("kind"), message.Kind);
        Assert.Equal(json, ControlMessageCoder.EncodeToString(message));

        if (c.SOpt("displayNameInput") is { } displayName)
        {
            var hello = (Hello)message;
            var rebuilt = hello with { Device = DeviceInfo.Create(hello.Device.PeerID, displayName, hello.Device.Platform, hello.Device.Model) };
            Assert.Equal(json, ControlMessageCoder.EncodeToString(rebuilt));
        }
    }
}

public sealed class CanonicalJsonVectorTests
{
    public static IEnumerable<object[]> Cases => Vectors.Names("canonical-json");

    [Theory]
    [MemberData(nameof(Cases))]
    public void CanonicalJson(string name)
    {
        var c = Vectors.Case("canonical-json", name);
        var expected = c.S("json");
        switch (c.S("type"))
        {
            case "string":
                var sb = new StringBuilder();
                foreach (var cp in c.GetProperty("input").EnumerateArray()) sb.Append(char.ConvertFromUtf32(cp.GetInt32()));
                var s = sb.ToString();
                Assert.Equal(c.S("inputUtf8"), Convert.ToHexStringLower(Encoding.UTF8.GetBytes(s)));
                Assert.Equal(expected, Json.CanonicalJson.EncodeToString(s));
                var msg = new TransferErrorMessage(null, BridgeErrorCode.ProtocolMismatch, s);
                var encoded = ControlMessageCoder.EncodeToString(msg);
                Assert.Contains("\"message\":" + expected, encoded, StringComparison.Ordinal);
                var back = (TransferErrorMessage)ControlMessageCoder.Decode(Encoding.UTF8.GetBytes(encoded));
                Assert.Equal(s, back.Message);
                break;
            case "base64":
                Assert.Equal(expected, Json.CanonicalJson.EncodeToString(c.H("inputHex")));
                var auth = (SessionAuth)ControlMessageCoder.Decode(Encoding.UTF8.GetBytes($"{{\"body\":{{\"signature\":{expected}}},\"kind\":\"SESSION_AUTH\"}}"));
                Assert.Equal(c.H("inputHex"), auth.Signature);
                break;
            case "date-ms":
                var ms = c.GetProperty("milliseconds").GetInt64();
                // Swift stores Dates relative to 2001, so half-millisecond inputs are not exact; the vector's integer wins.
                if (c.B("matchesNaiveRounding")) Assert.Equal(ms, Clock.MillisFromSeconds(c.D("secondsSince1970")));
                Assert.Equal(expected, Json.CanonicalJson.EncodeToString(ms));
                var ping = (Ping)ControlMessageCoder.Decode(Encoding.UTF8.GetBytes($"{{\"body\":{{\"sentAt\":{expected},\"sequence\":1}},\"kind\":\"PING\"}}"));
                Assert.Equal(ms, ping.SentAtMillis);
                break;
            case "uuid":
                Assert.True(Uuids.TryParse(c.S("input"), out var id));
                Assert.Equal(expected, Json.CanonicalJson.EncodeToString(id));
                var bytes = new byte[16];
                Uuids.Write(id, bytes);
                Assert.Equal(c.S("bytesHex"), Convert.ToHexStringLower(bytes));
                Assert.Equal(id, Uuids.Read(bytes));
                break;
            default:
                Assert.Fail("unknown type " + c.S("type"));
                break;
        }
    }
}

public sealed class PairingVectorTests
{
    public static IEnumerable<object[]> Cases => Vectors.Names("pairing");

    [Theory]
    [MemberData(nameof(Cases))]
    public void Pairing(string name)
    {
        var c = Vectors.Case("pairing", name);
        var initiator = new DeviceIdentity(c.H("initiatorSigningSeed"));
        var responder = new DeviceIdentity(c.H("responderSigningSeed"));
        Assert.Equal(c.S("initiatorSigningPublicKey"), Hex.Encode(initiator.PublicKey));
        Assert.Equal(c.S("responderSigningPublicKey"), Hex.Encode(responder.PublicKey));
        Assert.Equal(c.S("initiatorPeerID"), initiator.PeerID);
        Assert.Equal(c.S("responderPeerID"), responder.PeerID);

        var ie = X25519KeyPair.FromPrivate(c.H("initiatorEphemeralPrivateKey"));
        var re = X25519KeyPair.FromPrivate(c.H("responderEphemeralPrivateKey"));
        Assert.Equal(c.S("initiatorEphemeralPublicKey"), Hex.Encode(ie.PublicKey));
        Assert.Equal(c.S("responderEphemeralPublicKey"), Hex.Encode(re.PublicKey));
        Assert.Equal(c.S("sharedSecret"), Hex.Encode(ie.Agree(re.PublicKey)));
        Assert.Equal(c.S("sharedSecret"), Hex.Encode(re.Agree(ie.PublicKey)));

        // Our own HELLO encoding must reproduce the wire bytes.
        foreach (var side in new[] { "initiatorHello", "responderHello" })
        {
            Assert.Equal(c.S(side + "Json"), Encoding.UTF8.GetString(c.H(side)));
            var hello = (Hello)ControlMessageCoder.Decode(c.H(side));
            Assert.Equal(c.S(side), Hex.Encode(ControlMessageCoder.Encode(hello)));
            Assert.Equal(c.S(side == "initiatorHello" ? "initiatorNonce" : "responderNonce"), Hex.Encode(hello.SessionNonce));
            Assert.Equal([BridgeProtocol.PairingCapability], hello.Capabilities);
        }

        var transcript = new PairingTranscript(c.H("initiatorHello"), c.H("responderHello"), ie.PublicKey, re.PublicKey,
            initiator.PublicKey, responder.PublicKey, c.H("initiatorChallenge"), c.H("responderChallenge"));
        Assert.Equal(c.S("transcriptHash"), Hex.Encode(transcript.Hash()));
        Assert.Equal(c.S("okm"), Hex.Encode(PairingCrypto.Okm(ie.Agree(re.PublicKey), transcript.Hash())));
        var keys = PairingCrypto.Derive(ie, re.PublicKey, transcript);
        Assert.Equal(c.S("sasKey"), c.S("okm")[..64]);
        Assert.Equal(c.S("sas"), keys.ShortAuthenticationString);
        Assert.Equal(c.S("sasDisplay"), PairingCrypto.FormatForDisplay(keys.ShortAuthenticationString));
        Assert.Equal(c.S("psk"), Hex.Encode(keys.PreSharedKey));
        Assert.Equal(c.S("confirmKey"), Hex.Encode(keys.ConfirmKey));
        Assert.Equal(c.S("pskFingerprint"), PairingCrypto.PskFingerprint(keys.PreSharedKey));
        Assert.Equal(c.S("confirmInitiator"), Hex.Encode(PairingCrypto.Confirmation(keys.ConfirmKey, PairingRole.Initiator, responder.PeerID)));
        Assert.Equal(c.S("confirmResponder"), Hex.Encode(PairingCrypto.Confirmation(keys.ConfirmKey, PairingRole.Responder, initiator.PeerID)));
        Assert.True(PairingCrypto.VerifyConfirmation(c.H("confirmInitiator"), keys.ConfirmKey, PairingRole.Initiator, responder.PeerID));
        Assert.False(PairingCrypto.VerifyConfirmation(c.H("confirmInitiator"), keys.ConfirmKey, PairingRole.Responder, responder.PeerID));

        foreach (var (field, key) in new[] { ("initiatorTranscriptSignature", initiator.PublicKey), ("responderTranscriptSignature", responder.PublicKey) })
        {
            var sig = c.GetProperty(field);
            Assert.Equal(c.S("transcriptHash"), sig.S("message"));
            Assert.True(Ed25519.Verify(key, sig.H("message"), sig.H("signature")));
        }

        // Every recorded message must decode and re-encode byte for byte.
        foreach (var m in c.GetProperty("messages").EnumerateObject())
        {
            var bytes = Convert.FromHexString(m.Value.GetString()!);
            Assert.Equal(bytes, ControlMessageCoder.Encode(ControlMessageCoder.Decode(bytes)));
            switch (ControlMessageCoder.Decode(bytes))
            {
                case PairConfirm confirm when m.Name == "pairConfirmInitiator":
                    Assert.Equal(c.S("confirmInitiator"), Hex.Encode(confirm.ChallengeResponse));
                    Assert.True(Ed25519.Verify(initiator.PublicKey, keys.TranscriptHash, confirm.TranscriptSignature));
                    break;
                case PairConfirm confirm when m.Name == "pairConfirmResponder":
                    Assert.Equal(c.S("confirmResponder"), Hex.Encode(confirm.ChallengeResponse));
                    Assert.Empty(confirm.TranscriptSignature);
                    break;
                case PairResponse response:
                    Assert.True(Ed25519.Verify(responder.PublicKey, keys.TranscriptHash, response.TranscriptSignature));
                    break;
            }
        }
    }
}

public sealed class SessionAuthVectorTests
{
    public static IEnumerable<object[]> Cases => Vectors.Names("session-auth");

    [Theory]
    [MemberData(nameof(Cases))]
    public void SessionAuth(string name)
    {
        var c = Vectors.Case("session-auth", name);
        var role = c.S("role") == "initiator" ? PairingRole.Initiator : PairingRole.Responder;
        var context = SessionContext.Build(c.H("initiatorNonce"), c.H("responderNonce"), c.S("initiatorPeerID"), c.S("responderPeerID"), role);
        Assert.Equal(c.S("signedContext"), Hex.Encode(context));
        var sig = c.GetProperty("signature");
        Assert.Equal(c.S("signedContext"), sig.S("message"));
        Assert.Equal(c.S("signerPublicKey"), sig.S("publicKey"));
        Assert.True(Ed25519.Verify(c.H("signerPublicKey"), context, sig.H("signature")));
        var other = SessionContext.Build(c.H("initiatorNonce"), c.H("responderNonce"), c.S("initiatorPeerID"), c.S("responderPeerID"), role.Other());
        Assert.False(Ed25519.Verify(c.H("signerPublicKey"), other, sig.H("signature")));

        var message = (Messages.SessionAuth)ControlMessageCoder.Decode(Encoding.UTF8.GetBytes(c.S("sessionAuthJson")));
        Assert.Equal(sig.H("signature"), message.Signature);
        Assert.Equal(c.S("sessionAuthJson"), ControlMessageCoder.EncodeToString(message));
    }
}

public sealed class Ed25519VectorTests
{
    public static IEnumerable<object[]> Cases => Vectors.Names("ed25519");

    [Theory]
    [MemberData(nameof(Cases))]
    public void Ed25519Case(string name)
    {
        var c = Vectors.Case("ed25519", name);
        var valid = c.B("valid");
        Assert.Equal(valid, Ed25519.Verify(c.H("publicKey"), c.H("message"), c.H("signature")));
        if (c.Has("privateKeySeed"))
        {
            Assert.Equal(c.S("publicKey"), Hex.Encode(Ed25519.PublicKey(c.H("privateKeySeed"))));
            var ours = Ed25519.Sign(c.H("privateKeySeed"), c.H("message"));
            Assert.True(Ed25519.Verify(c.H("publicKey"), c.H("message"), ours));
            if (c.B("deterministic")) Assert.Equal(c.S("signature"), Hex.Encode(ours));
        }
    }
}

public sealed class SanitizerVectorTests
{
    public static IEnumerable<object[]> Cases => Vectors.Names("sanitizer");

    [Theory]
    [MemberData(nameof(Cases))]
    public void Sanitizer(string name)
    {
        var c = Vectors.Case("sanitizer", name);
        var input = c.S("input");
        if (c.S("op") == "candidate")
        {
            Assert.Equal(c.S("candidate"), FilenameSanitizer.Candidate(input, c.GetProperty("attempt").GetInt32()));
            return;
        }
        var sanitized = FilenameSanitizer.Sanitize(input, c.SOpt("contentType"));
        Assert.Equal(c.S("sanitized"), sanitized);
        Assert.Equal(c.GetProperty("sanitizedUtf8Length").GetInt32(), Encoding.UTF8.GetByteCount(sanitized));
        Assert.Equal(c.B("isSafe"), FilenameSanitizer.IsSafe(input));
        Assert.Equal(c.B("sanitizedIsSafe"), FilenameSanitizer.IsSafe(sanitized));

        // Whatever passes isSafe must map to a valid, non-reserved Windows name.
        if (FilenameSanitizer.IsSafe(sanitized)) WindowsSaveNameTests.AssertValidWindowsName(WindowsSaveName.Map(sanitized));
    }
}

public sealed class UtiPolicyVectorTests
{
    public static IEnumerable<object[]> Cases => Vectors.Names("uti-policy");

    /// <summary>Windows must deny everything the Mac denies, with the same code.</summary>
    [Theory]
    [MemberData(nameof(Cases))]
    public void AtLeastAsStrictAsMac(string name)
    {
        var c = Vectors.Case("uti-policy", name);
        var error = Record.Exception(() => TransferPolicy.Default.ValidateName(c.S("filename"), c.S("contentType")));
        if (!c.B("allowedOnMac"))
        {
            var bridge = Assert.IsType<BridgeException>(error);
            Assert.Equal(c.S("errorCode"), bridge.Code.ToWire());
            return;
        }
        var ext = FilenameSanitizer.SplitExtension(c.S("filename")).Extension;
        var windowsDenied = TransferPolicy.DeniedExtensions.Contains(ext) || TransferPolicy.WindowsDeniedTypes.Any(t => UtiCatalog.ConformsTo(c.S("contentType"), t));
        if (windowsDenied)
        {
            Assert.Equal(BridgeErrorCode.UnsupportedFile, Assert.IsType<BridgeException>(error).Code);
        }
        else
        {
            Assert.Null(error);
        }
    }
}

public sealed class CoordinateMapperVectorTests
{
    public static IEnumerable<object[]> Cases => Vectors.Names("coordinate-mapper");

    [Theory]
    [MemberData(nameof(Cases))]
    public void Mapper(string name)
    {
        var c = Vectors.Case("coordinate-mapper", name);
        var tol = c.D("tolerance");
        var l = c.GetProperty("layout");
        var layout = new SpatialLayout(
            Enum.Parse<PhonePlacement>(l.S("placement"), ignoreCase: true),
            l.SOpt("macDisplayIdentifier"),
            l.D("alignmentOffsetInput"),
            l.B("mirrored"));
        Assert.Equal(l.D("alignmentOffset"), layout.AlignmentOffset, tol);
        var g = c.GetProperty("gesture");
        var position = Math.Clamp(g.D("normalizedPositionInput"), 0, 1);
        Assert.Equal(g.D("normalizedPosition"), position, tol);
        Assert.Equal(c.D("mappedPosition"), CoordinateMapper.MapNormalizedPosition(position, layout), tol);

        var displays = c.GetProperty("displays").EnumerateArray().Select(d => new DisplayGeometry(
            d.S("identifier"), d.S("localizedName"), Rect(d.GetProperty("frame")), Rect(d.GetProperty("visibleFrame")),
            d.D("backingScaleFactor"), d.B("originIsBottomLeft"), d.B("isMain"))).ToList();
        var selected = CoordinateMapper.SelectDisplay(layout, displays);
        Assert.Equal(c.SOpt("selectedDisplay"), selected?.Identifier);
        if (!c.Has("expected"))
        {
            Assert.Null(selected);
            return;
        }
        var e = c.GetProperty("expected");
        var size = c.GetProperty("cardSize");
        var p = CoordinateMapper.Placement(position, layout, selected!, new SizeD(size.D("width"), size.D("height")), c.D("restInset"));
        Assert.Equal(e.S("edge"), p.Edge.ToWire());
        Assert.Equal(e.D("normalizedPosition"), p.NormalizedPosition, tol);
        AssertPoint(e.GetProperty("entryPoint"), p.EntryPoint, tol);
        AssertPoint(e.GetProperty("restPoint"), p.RestPoint, tol);
        var card = e.GetProperty("cardFrame");
        Assert.Equal(card.D("x"), p.CardFrame.X, tol);
        Assert.Equal(card.D("y"), p.CardFrame.Y, tol);
        Assert.Equal(card.D("width"), p.CardFrame.Width, tol);
        Assert.Equal(card.D("height"), p.CardFrame.Height, tol);
    }

    private static RectD Rect(JsonElement r) => new(r.D("x"), r.D("y"), r.D("width"), r.D("height"));

    private static void AssertPoint(JsonElement e, PointD p, double tol)
    {
        Assert.Equal(e.D("x"), p.X, tol);
        Assert.Equal(e.D("y"), p.Y, tol);
    }
}
