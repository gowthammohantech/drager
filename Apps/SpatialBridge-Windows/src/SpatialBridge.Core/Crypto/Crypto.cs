using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;

namespace SpatialBridge.Core.Crypto;

public enum PairingRole { Initiator, Responder }

public static class PairingRoles
{
    public static string ToWire(this PairingRole role) => role == PairingRole.Initiator ? "initiator" : "responder";

    public static PairingRole Other(this PairingRole role) => role == PairingRole.Initiator ? PairingRole.Responder : PairingRole.Initiator;
}

public static class Ed25519
{
    public const int KeyBytes = 32;
    public const int SignatureBytes = 64;

    public static byte[] PublicKey(ReadOnlySpan<byte> seed) => new Ed25519PrivateKeyParameters(seed).GeneratePublicKey().GetEncoded();

    public static byte[] Sign(ReadOnlySpan<byte> seed, ReadOnlySpan<byte> message)
    {
        var signer = new Ed25519Signer();
        signer.Init(true, new Ed25519PrivateKeyParameters(seed));
        signer.BlockUpdate(message);
        return signer.GenerateSignature();
    }

    public static bool Verify(ReadOnlySpan<byte> publicKey, ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature)
    {
        if (publicKey.Length != KeyBytes || signature.Length != SignatureBytes) return false;
        try
        {
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(publicKey));
            verifier.BlockUpdate(message);
            return verifier.VerifySignature(signature.ToArray());
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
        {
            return false;
        }
    }
}

/// <summary>An ephemeral X25519 key for one pairing attempt.</summary>
public sealed class X25519KeyPair
{
    private readonly X25519PrivateKeyParameters _private;

    private X25519KeyPair(X25519PrivateKeyParameters key)
    {
        _private = key;
        PublicKey = key.GeneratePublicKey().GetEncoded();
    }

    public byte[] PublicKey { get; }

    public static X25519KeyPair Generate() => new(new X25519PrivateKeyParameters(new SecureRandom()));

    public static X25519KeyPair FromPrivate(ReadOnlySpan<byte> raw) => new(new X25519PrivateKeyParameters(raw));

    /// <summary>Raw shared secret. Throws E004 for an invalid or low-order peer key.</summary>
    public byte[] Agree(ReadOnlySpan<byte> peerPublicKey)
    {
        if (peerPublicKey.Length != 32) throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "Invalid ephemeral key");
        try
        {
            var agreement = new X25519Agreement();
            agreement.Init(_private);
            var shared = new byte[agreement.AgreementSize];
            agreement.CalculateAgreement(new X25519PublicKeyParameters(peerPublicKey), shared, 0);
            return shared;
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException)
        {
            throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "Invalid ephemeral key", ex);
        }
    }
}

/// <summary>The device's long-term Ed25519 identity. The seed lives in the secret store.</summary>
public sealed class DeviceIdentity
{
    private readonly byte[] _seed;

    public DeviceIdentity(ReadOnlySpan<byte> seed)
    {
        if (seed.Length != 32) throw new ArgumentException("seed must be 32 bytes", nameof(seed));
        _seed = seed.ToArray();
        PublicKey = Ed25519.PublicKey(_seed);
        PeerID = PeerIdFor(PublicKey);
    }

    public byte[] PublicKey { get; }

    public string PeerID { get; }

    public static DeviceIdentity Generate() => new(RandomNumberGenerator.GetBytes(32));

    public byte[] ExportSeed() => (byte[])_seed.Clone();

    public byte[] Sign(ReadOnlySpan<byte> data) => Ed25519.Sign(_seed, data);

    /// <summary><c>hex(SHA256(ed25519)[0..16])</c>.</summary>
    public static string PeerIdFor(ReadOnlySpan<byte> signingPublicKey) => Hex.Encode(SHA256.HashData(signingPublicKey).AsSpan(0, 16));
}

/// <summary>Keys derived at pairing. The SAS is display-only.</summary>
public sealed record PairingKeys(string ShortAuthenticationString, byte[] PreSharedKey, byte[] ConfirmKey, byte[] TranscriptHash);

/// <summary>Pairing transcript over the HELLO wire bytes (ADR-014).</summary>
public sealed record PairingTranscript(
    byte[] InitiatorHelloPayload,
    byte[] ResponderHelloPayload,
    byte[] InitiatorEphemeralPublicKey,
    byte[] ResponderEphemeralPublicKey,
    byte[] InitiatorSigningPublicKey,
    byte[] ResponderSigningPublicKey,
    byte[] InitiatorChallenge,
    byte[] ResponderChallenge)
{
    public byte[] Hash()
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Absorb(string label, ReadOnlySpan<byte> data)
        {
            hash.AppendData(Encoding.UTF8.GetBytes(label));
            Span<byte> length = stackalloc byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(length, (uint)data.Length);
            hash.AppendData(length);
            hash.AppendData(data);
        }
        Absorb("sb-pair-v1", []);
        Absorb("ihello", InitiatorHelloPayload);
        Absorb("rhello", ResponderHelloPayload);
        Absorb("ieph", InitiatorEphemeralPublicKey);
        Absorb("reph", ResponderEphemeralPublicKey);
        Absorb("isig", InitiatorSigningPublicKey);
        Absorb("rsig", ResponderSigningPublicKey);
        Absorb("ichal", InitiatorChallenge);
        Absorb("rchal", ResponderChallenge);
        return hash.GetHashAndReset();
    }
}

public static class PairingCrypto
{
    public const int SasDigits = 6;
    private static readonly byte[] KeyInfo = "sb-pair-v1-keys"u8.ToArray();

    /// <summary>HKDF-SHA256(ikm = shared, salt = transcript hash, info = "sb-pair-v1-keys", 96 bytes).</summary>
    public static byte[] Okm(ReadOnlySpan<byte> sharedSecret, ReadOnlySpan<byte> transcriptHash)
    {
        var okm = new byte[96];
        HKDF.DeriveKey(HashAlgorithmName.SHA256, sharedSecret, okm, transcriptHash, KeyInfo);
        return okm;
    }

    public static PairingKeys Derive(X25519KeyPair ephemeral, ReadOnlySpan<byte> peerEphemeralPublicKey, PairingTranscript transcript)
    {
        var shared = ephemeral.Agree(peerEphemeralPublicKey);
        return KeysFrom(shared, transcript.Hash());
    }

    public static PairingKeys KeysFrom(ReadOnlySpan<byte> sharedSecret, byte[] transcriptHash)
    {
        var okm = Okm(sharedSecret, transcriptHash);
        return new PairingKeys(ShortAuthenticationString(okm.AsSpan(0, 32)), okm[32..64], okm[64..96], transcriptHash);
    }

    public static string ShortAuthenticationString(ReadOnlySpan<byte> sasKey) =>
        (BinaryPrimitives.ReadUInt32BigEndian(sasKey) % 1_000_000u).ToString("D6", CultureInfo.InvariantCulture);

    public static byte[] Confirmation(byte[] confirmKey, PairingRole role, string approvedPeerID)
    {
        var message = Encoding.UTF8.GetBytes("sb-confirm-v1:" + role.ToWire() + "\u001F" + approvedPeerID);
        return HMACSHA256.HashData(confirmKey, message);
    }

    public static bool VerifyConfirmation(ReadOnlySpan<byte> candidate, byte[] confirmKey, PairingRole role, string approvedPeerID)
    {
        var expected = Confirmation(confirmKey, role, approvedPeerID);
        return candidate.Length == expected.Length && CryptographicOperations.FixedTimeEquals(candidate, expected);
    }

    /// <summary><c>123 456</c>.</summary>
    public static string FormatForDisplay(string sas) => sas.Length == 6 ? $"{sas[..3]} {sas[3..]}" : sas;

    public static string PskFingerprint(ReadOnlySpan<byte> psk) => Hex.Encode(SHA256.HashData(psk))[..16];
}

public static class SessionContext
{
    private static readonly byte[] Label = "sb-session-v1"u8.ToArray();

    /// <summary><c>"sb-session-v1" ‖ for each part: UInt32BE(len) ‖ bytes</c>.</summary>
    public static byte[] Build(ReadOnlySpan<byte> initiatorNonce, ReadOnlySpan<byte> responderNonce, string initiator, string responder, PairingRole signer)
    {
        using var buffer = new MemoryStream();
        buffer.Write(Label);
        void Part(ReadOnlySpan<byte> part)
        {
            Span<byte> length = stackalloc byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(length, (uint)part.Length);
            buffer.Write(length);
            buffer.Write(part);
        }
        Part(initiatorNonce);
        Part(responderNonce);
        Part(Encoding.UTF8.GetBytes(initiator));
        Part(Encoding.UTF8.GetBytes(responder));
        Part(Encoding.UTF8.GetBytes(signer.ToWire()));
        return buffer.ToArray();
    }
}
