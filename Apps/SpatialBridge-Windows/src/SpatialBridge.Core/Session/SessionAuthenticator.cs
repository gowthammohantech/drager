using System.Security.Cryptography;
using SpatialBridge.Core.Crypto;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Pairing;

namespace SpatialBridge.Core.Session;

/// <summary>
/// Binds a TLS-PSK session to one trusted peer: each side signs both fresh HELLO nonces, both peer IDs
/// and its role with its Ed25519 key; the other verifies against the key stored at pairing.
/// </summary>
public static class SessionAuthenticator
{
    private static Hello SessionHello(DeviceInfo device) =>
        new(BridgeProtocol.Version, device, [.. BridgeProtocol.DefaultCapabilities, BridgeProtocol.SessionCapability], RandomNumberGenerator.GetBytes(32));

    /// <summary>Sender side. Returns the responder's HELLO.</summary>
    public static async Task<Hello> AuthenticateAsInitiatorAsync(SessionChannel channel, DeviceIdentity identity, DeviceInfo device, TrustedPeer expectedPeer, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var t = timeout ?? ProtocolTimeouts.Default.SessionAuth;
        var hello = SessionHello(device);
        await channel.SendAsync(hello, ct).ConfigureAwait(false);
        var (theirHello, _) = await PairingProtocol.ExpectHelloAsync(channel, BridgeProtocol.SessionCapability, t, ct).ConfigureAwait(false);
        if (theirHello.Device.PeerID != expectedPeer.PeerID) throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "connected to an unexpected peer");

        var mine = identity.Sign(SessionContext.Build(hello.SessionNonce, theirHello.SessionNonce, identity.PeerID, expectedPeer.PeerID, PairingRole.Initiator));
        await channel.SendAsync(new SessionAuth(mine), ct).ConfigureAwait(false);

        var reply = await channel.ReceiveControlAsync(t, ct).ConfigureAwait(false);
        if (reply is not SessionAuth auth)
        {
            if (reply is TransferErrorMessage error) throw new BridgeException(error.Code, "responder refused session");
            throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "expected SESSION_AUTH");
        }
        var context = SessionContext.Build(hello.SessionNonce, theirHello.SessionNonce, identity.PeerID, expectedPeer.PeerID, PairingRole.Responder);
        if (!Ed25519.Verify(expectedPeer.SigningPublicKey, context, auth.Signature))
        {
            throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "responder session signature invalid");
        }
        return theirHello;
    }

    /// <summary>
    /// Receiver side. <paramref name="tlsIdentity"/>, when known, must equal the HELLO peer ID: the PSK that
    /// opened TLS has to belong to the peer that signs.
    /// </summary>
    public static async Task<(TrustedPeer Peer, Hello Hello)> AuthenticateAsResponderAsync(SessionChannel channel, DeviceIdentity identity, DeviceInfo device, Func<string, TrustedPeer?> trust, string? tlsIdentity = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var t = timeout ?? ProtocolTimeouts.Default.SessionAuth;
        var (theirHello, _) = await PairingProtocol.ExpectHelloAsync(channel, BridgeProtocol.SessionCapability, t, ct).ConfigureAwait(false);
        var peer = trust(theirHello.Device.PeerID);
        if (peer is null || (tlsIdentity is not null && tlsIdentity != peer.PeerID))
        {
            await channel.TrySendAsync(new TransferErrorMessage(null, BridgeErrorCode.AuthenticationFailed)).ConfigureAwait(false);
            throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "untrusted peer");
        }
        var myHello = SessionHello(device);
        await channel.SendAsync(myHello, ct).ConfigureAwait(false);

        if (await channel.ReceiveControlAsync(t, ct).ConfigureAwait(false) is not SessionAuth auth)
        {
            throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "expected SESSION_AUTH");
        }
        var context = SessionContext.Build(theirHello.SessionNonce, myHello.SessionNonce, peer.PeerID, identity.PeerID, PairingRole.Initiator);
        if (!Ed25519.Verify(peer.SigningPublicKey, context, auth.Signature))
        {
            await channel.TrySendAsync(new TransferErrorMessage(null, BridgeErrorCode.AuthenticationFailed)).ConfigureAwait(false);
            throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "initiator session signature invalid");
        }
        var mine = identity.Sign(SessionContext.Build(theirHello.SessionNonce, myHello.SessionNonce, peer.PeerID, identity.PeerID, PairingRole.Responder));
        await channel.SendAsync(new SessionAuth(mine), ct).ConfigureAwait(false);
        return (peer, theirHello);
    }
}
