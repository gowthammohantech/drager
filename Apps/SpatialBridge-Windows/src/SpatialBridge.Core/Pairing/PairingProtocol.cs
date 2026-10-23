using System.Security.Cryptography;
using SpatialBridge.Core.Crypto;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Session;

namespace SpatialBridge.Core.Pairing;

/// <summary>A paired device. Secrets (the PSK) live in the secret store; this is public metadata.</summary>
public sealed record TrustedPeer(
    string PeerID,
    string DisplayName,
    DevicePlatform Platform,
    string Model,
    byte[] SigningPublicKey,
    DateTimeOffset PairedAt,
    DateTimeOffset? LastSeenAt = null)
{
    public TrustedPeerInfo ToInfo() => new(PeerID, DisplayName, Platform, PairedAt);
}

/// <summary>What the local user compares. <see cref="ShortAuthenticationString"/> is six digits.</summary>
public sealed record PairingRequestPrompt(string ShortAuthenticationString, DeviceInfo Peer, string PeerFingerprint)
{
    public string FormattedCode => PairingCrypto.FormatForDisplay(ShortAuthenticationString);
}

public sealed record PairingOutcome(TrustedPeer TrustedPeer, byte[] PreSharedKey, string ShortAuthenticationString);

/// <summary>Asks the local user to compare codes; must honour cancellation (peer rejected or disconnected).</summary>
public delegate Task<bool> PairingDecisionHandler(PairingRequestPrompt prompt, CancellationToken cancellationToken);

/// <summary>
/// The pairing handshake (PROTOCOL.md): HELLO(pair.v1) both ways, PAIR_REQUEST, PAIR_RESPONSE (responder
/// signs the transcript), both users decide, PAIR_CONFIRM both ways (initiator signs). Trust results only
/// when the local user approved and the peer's confirmation verified.
/// </summary>
public static class PairingProtocol
{
    public const string GlobalLimiterKey = "global";

    public static async Task<PairingOutcome> RunInitiatorAsync(SessionChannel channel, DeviceIdentity identity, DeviceInfo device, PairingDecisionHandler decide, ProtocolTimeouts? timeouts = null, TimeProvider? time = null, CancellationToken cancellationToken = default)
    {
        timeouts ??= ProtocolTimeouts.Default;
        try
        {
            var outcome = await InitiateAsync(channel, identity, device, decide, timeouts, time ?? TimeProvider.System, cancellationToken).ConfigureAwait(false);
            channel.Close();
            return outcome;
        }
        catch (Exception ex)
        {
            channel.Close(BridgeException.Classify(ex, true));
            throw;
        }
    }

    public static async Task<PairingOutcome> RunResponderAsync(SessionChannel channel, DeviceIdentity identity, DeviceInfo device, PairingRateLimiter rateLimiter, PairingDecisionHandler decide, ProtocolTimeouts? timeouts = null, TimeProvider? time = null, CancellationToken cancellationToken = default)
    {
        timeouts ??= ProtocolTimeouts.Default;
        try
        {
            var outcome = await AcceptAsync(channel, identity, device, rateLimiter, decide, timeouts, time ?? TimeProvider.System, cancellationToken).ConfigureAwait(false);
            channel.Close();
            return outcome;
        }
        catch (Exception ex)
        {
            channel.Close(BridgeException.Classify(ex, true));
            throw;
        }
    }

    private static async Task<PairingOutcome> InitiateAsync(SessionChannel channel, DeviceIdentity identity, DeviceInfo device, PairingDecisionHandler decide, ProtocolTimeouts timeouts, TimeProvider time, CancellationToken ct)
    {
        var myHello = new Hello(BridgeProtocol.Version, device, [BridgeProtocol.PairingCapability], RandomNumberGenerator.GetBytes(32));
        var myHelloPayload = await channel.SendAsync(myHello, ct).ConfigureAwait(false);
        var (theirHello, theirHelloPayload) = await ExpectHelloAsync(channel, BridgeProtocol.PairingCapability, timeouts.Handshake, ct).ConfigureAwait(false);

        var ephemeral = X25519KeyPair.Generate();
        var request = new PairRequest(ephemeral.PublicKey, identity.PublicKey, device.DisplayName, RandomNumberGenerator.GetBytes(32));
        await channel.SendAsync(request, ct).ConfigureAwait(false);

        var response = await channel.ReceiveControlAsync(timeouts.Handshake, ct).ConfigureAwait(false) switch
        {
            PairResponse r => r,
            PairReject reject => throw new BridgeException(reject.Reason, "responder refused pairing"),
            TransferErrorMessage error => throw new BridgeException(error.Code, "responder error"),
            _ => throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "expected PAIR_RESPONSE"),
        };
        if (DeviceIdentity.PeerIdFor(response.SigningPublicKey) != theirHello.Device.PeerID)
        {
            throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "responder key does not match HELLO peer ID");
        }
        var transcript = new PairingTranscript(myHelloPayload, theirHelloPayload, request.EphemeralPublicKey, response.EphemeralPublicKey,
            identity.PublicKey, response.SigningPublicKey, request.Challenge, response.Challenge);
        var keys = PairingCrypto.Derive(ephemeral, response.EphemeralPublicKey, transcript);
        if (!Ed25519.Verify(response.SigningPublicKey, keys.TranscriptHash, response.TranscriptSignature))
        {
            await channel.TrySendAsync(new PairReject(BridgeErrorCode.AuthenticationFailed)).ConfigureAwait(false);
            throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "bad responder transcript signature");
        }

        await ConvergeAsync(PairingRole.Initiator, channel, keys, identity, theirHello.Device, response.SigningPublicKey, timeouts, decide, ct).ConfigureAwait(false);
        return new PairingOutcome(Trusted(theirHello.Device, response.SigningPublicKey, time), keys.PreSharedKey, keys.ShortAuthenticationString);
    }

    private static async Task<PairingOutcome> AcceptAsync(SessionChannel channel, DeviceIdentity identity, DeviceInfo device, PairingRateLimiter rateLimiter, PairingDecisionHandler decide, ProtocolTimeouts timeouts, TimeProvider time, CancellationToken ct)
    {
        var (theirHello, theirHelloPayload) = await ExpectHelloAsync(channel, BridgeProtocol.PairingCapability, timeouts.Handshake, ct).ConfigureAwait(false);
        var peerID = theirHello.Device.PeerID;
        if (rateLimiter.IsLocked(peerID) || rateLimiter.IsLocked(GlobalLimiterKey))
        {
            await channel.TrySendAsync(new PairReject(BridgeErrorCode.PairingRejected)).ConfigureAwait(false);
            throw new BridgeException(BridgeErrorCode.PairingRejected, "rate limited");
        }
        try
        {
            var outcome = await RespondAsync(channel, identity, device, theirHello, theirHelloPayload, decide, timeouts, time, ct).ConfigureAwait(false);
            rateLimiter.RecordSuccess(peerID);
            return outcome;
        }
        catch (Exception)
        {
            rateLimiter.RecordFailure(peerID);
            rateLimiter.RecordFailure(GlobalLimiterKey);
            throw;
        }
    }

    private static async Task<PairingOutcome> RespondAsync(SessionChannel channel, DeviceIdentity identity, DeviceInfo device, Hello theirHello, byte[] theirHelloPayload, PairingDecisionHandler decide, ProtocolTimeouts timeouts, TimeProvider time, CancellationToken ct)
    {
        var myHello = new Hello(BridgeProtocol.Version, device, [BridgeProtocol.PairingCapability], RandomNumberGenerator.GetBytes(32));
        var myHelloPayload = await channel.SendAsync(myHello, ct).ConfigureAwait(false);

        if (await channel.ReceiveControlAsync(timeouts.Handshake, ct).ConfigureAwait(false) is not PairRequest request)
        {
            throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "expected PAIR_REQUEST");
        }
        if (DeviceIdentity.PeerIdFor(request.SigningPublicKey) != theirHello.Device.PeerID)
        {
            await channel.TrySendAsync(new PairReject(BridgeErrorCode.AuthenticationFailed)).ConfigureAwait(false);
            throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "initiator key does not match HELLO peer ID");
        }

        var ephemeral = X25519KeyPair.Generate();
        var challenge = RandomNumberGenerator.GetBytes(32);
        var transcript = new PairingTranscript(theirHelloPayload, myHelloPayload, request.EphemeralPublicKey, ephemeral.PublicKey,
            request.SigningPublicKey, identity.PublicKey, request.Challenge, challenge);
        var keys = PairingCrypto.Derive(ephemeral, request.EphemeralPublicKey, transcript);
        await channel.SendAsync(new PairResponse(ephemeral.PublicKey, identity.PublicKey, device.DisplayName, challenge, identity.Sign(keys.TranscriptHash)), ct).ConfigureAwait(false);

        await ConvergeAsync(PairingRole.Responder, channel, keys, identity, theirHello.Device, request.SigningPublicKey, timeouts, decide, ct).ConfigureAwait(false);
        return new PairingOutcome(Trusted(theirHello.Device, request.SigningPublicKey, time), keys.PreSharedKey, keys.ShortAuthenticationString);
    }

    /// <summary>Waits for both the local decision and the peer's confirmation, in either order.</summary>
    private static async Task ConvergeAsync(PairingRole role, SessionChannel channel, PairingKeys keys, DeviceIdentity identity, DeviceInfo peer, byte[] peerSigningKey, ProtocolTimeouts timeouts, PairingDecisionHandler decide, CancellationToken ct)
    {
        var prompt = new PairingRequestPrompt(keys.ShortAuthenticationString, peer, PeerIds.Fingerprint(peer.PeerID));
        var peerRole = role.Other();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeouts.UserDecision);

        Task<bool>? decision = decide(prompt, cts.Token);
        Task<ControlMessage>? message = channel.ReceiveControlAsync(timeouts.UserDecision, cts.Token);
        var locallyApproved = false;
        var peerConfirmed = false;
        BridgeException? confirmSendError = null;
        try
        {
            while (decision is not null || message is not null)
            {
                var pending = new List<Task>(2);
                if (decision is not null) pending.Add(decision);
                if (message is not null) pending.Add(message);
                var done = await Task.WhenAny(pending).ConfigureAwait(false);

                if (done == decision)
                {
                    decision = null;
                    var approved = await ((Task<bool>)done).ConfigureAwait(false);
                    if (!approved)
                    {
                        await channel.TrySendAsync(new PairReject(BridgeErrorCode.PairingRejected)).ConfigureAwait(false);
                        throw new BridgeException(BridgeErrorCode.PairingRejected, "rejected on this device");
                    }
                    locallyApproved = true;
                    var confirm = new PairConfirm(
                        PairingCrypto.Confirmation(keys.ConfirmKey, role, peer.PeerID),
                        peer.PeerID,
                        role == PairingRole.Initiator ? identity.Sign(keys.TranscriptHash) : []);
                    try
                    {
                        await channel.SendAsync(confirm, ct).ConfigureAwait(false);
                    }
                    catch (BridgeException ex)
                    {
                        // The peer may have rejected and closed first; its buffered message decides.
                        confirmSendError = ex;
                    }
                }
                else
                {
                    message = null;
                    switch (await ((Task<ControlMessage>)done).ConfigureAwait(false))
                    {
                        case PairReject reject:
                            throw new BridgeException(reject.Reason == BridgeErrorCode.AuthenticationFailed ? BridgeErrorCode.AuthenticationFailed : BridgeErrorCode.PairingRejected, "rejected by peer");
                        case PairConfirm c:
                            var validMac = PairingCrypto.VerifyConfirmation(c.ChallengeResponse, keys.ConfirmKey, peerRole, identity.PeerID);
                            var validSignature = peerRole == PairingRole.Responder || Ed25519.Verify(peerSigningKey, keys.TranscriptHash, c.TranscriptSignature);
                            if (c.ApprovedPeerID != identity.PeerID || !validMac || !validSignature)
                            {
                                await channel.TrySendAsync(new PairReject(BridgeErrorCode.AuthenticationFailed)).ConfigureAwait(false);
                                throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "peer confirmation did not verify");
                            }
                            peerConfirmed = true;
                            break;
                        case TransferErrorMessage error:
                            throw new BridgeException(error.Code, "peer error during pairing");
                        default:
                            throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "unexpected message during pairing");
                    }
                }
                if (locallyApproved && peerConfirmed)
                {
                    if (confirmSendError is not null) throw confirmSendError;
                    return;
                }
            }
            throw new BridgeException(BridgeErrorCode.PeerLost, "pairing ended early");
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new BridgeException(BridgeErrorCode.Timeout, "pairing decision timed out");
        }
        finally
        {
            await cts.CancelAsync().ConfigureAwait(false);
            foreach (var t in new Task?[] { decision, message })
            {
                if (t is not null) _ = t.ContinueWith(static x => _ = x.Exception, TaskScheduler.Default);
            }
        }
    }

    /// <summary>Validated HELLO plus its exact payload bytes (ADR-014).</summary>
    public static async Task<(Hello Hello, byte[] Payload)> ExpectHelloAsync(SessionChannel channel, string capability, TimeSpan timeout, CancellationToken ct = default)
    {
        var received = await channel.ReceiveControlFrameAsync(timeout, ct).ConfigureAwait(false);
        switch (received.Message)
        {
            case PairReject reject:
                throw new BridgeException(reject.Reason, "peer refused before HELLO");
            case TransferErrorMessage error:
                throw new BridgeException(error.Code, "peer error before HELLO");
            case not Hello:
                throw new BridgeException(BridgeErrorCode.ProtocolMismatch, $"expected HELLO, got {received.Message.Kind}");
        }
        var hello = (Hello)received.Message;
        if (hello.ProtocolVersion != BridgeProtocol.Version)
        {
            await channel.TrySendAsync(new TransferErrorMessage(null, BridgeErrorCode.ProtocolMismatch)).ConfigureAwait(false);
            throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "peer protocol version");
        }
        if (!hello.Capabilities.Contains(capability) || hello.SessionNonce.Length != 32)
        {
            throw new BridgeException(BridgeErrorCode.ProtocolMismatch, $"HELLO missing {capability}");
        }
        if (!PeerIds.IsValid(hello.Device.PeerID)) throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "malformed peer ID");
        return (hello, received.Payload);
    }

    private static TrustedPeer Trusted(DeviceInfo device, byte[] key, TimeProvider time) =>
        new(device.PeerID, device.DisplayName, device.Platform, device.Model, key, time.GetUtcNow());
}

/// <summary>Rate-limits SAS guessing: 3 failures per 60 s lock the key (per peer, and the shared "global" key).</summary>
public sealed class PairingRateLimiter(int maxFailures = 3, TimeSpan? lockout = null, TimeProvider? time = null)
{
    private readonly TimeSpan _lockout = lockout ?? TimeSpan.FromSeconds(60);
    private readonly TimeProvider _time = time ?? TimeProvider.System;
    private readonly Dictionary<string, (int Count, DateTimeOffset? LockedUntil)> _failures = new(StringComparer.Ordinal);
    private readonly Lock _gate = new();

    public bool IsLocked(string key)
    {
        lock (_gate)
        {
            if (!_failures.TryGetValue(key, out var entry) || entry.LockedUntil is not { } until) return false;
            if (_time.GetUtcNow() >= until)
            {
                _failures.Remove(key);
                return false;
            }
            return true;
        }
    }

    public void RecordFailure(string key)
    {
        lock (_gate)
        {
            var entry = _failures.GetValueOrDefault(key);
            entry.Count++;
            if (entry.Count >= maxFailures)
            {
                entry.LockedUntil = _time.GetUtcNow() + _lockout;
                entry.Count = 0;
            }
            _failures[key] = entry;
        }
    }

    public void RecordSuccess(string key)
    {
        lock (_gate) { _failures.Remove(key); }
    }
}
