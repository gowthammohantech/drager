using System.Net.Sockets;
using SpatialBridge.Core.Crypto;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Net;
using SpatialBridge.Core.Pairing;
using SpatialBridge.Core.Session;
using SpatialBridge.Core.Tls;
using SpatialBridge.Core.Transfer;

namespace SpatialBridge.Core.Services;

/// <summary>
/// The sender role (pairing initiator, TLS client, session initiator) over explicit endpoints. Used by the
/// CLI and loopback tests; the shipping senders are the iPhone and Android apps.
/// </summary>
public sealed class SenderClient(ISecretStore secrets, ITrustedPeerStore trusted, string displayName = "sb-dotnet", DevicePlatform? platform = null, string model = "dotnet")
{
    public DeviceIdentity Identity { get; } = secrets.LoadOrCreateIdentity();

    public DeviceInfo Device => DeviceInfo.Create(Identity.PeerID, displayName, platform ?? DevicePlatform.Windows, model);

    public ProtocolTimeouts Timeouts { get; init; } = ProtocolTimeouts.Default;

    public TransferLimits Limits { get; init; } = TransferLimits.Default;

    public async Task<PairingOutcome> PairAsync(string host, int port, PairingDecisionHandler decide, CancellationToken ct = default)
    {
        var client = await ConnectAsync(host, port, ct).ConfigureAwait(false);
        await using var channel = new SessionChannel(StreamFrameTransport.Over(client), SessionChannelOptions.Handshake);
        var outcome = await PairingProtocol.RunInitiatorAsync(channel, Identity, Device, decide, Timeouts, null, ct).ConfigureAwait(false);
        secrets.WritePsk(outcome.TrustedPeer.PeerID, outcome.PreSharedKey);
        trusted.Upsert(outcome.TrustedPeer);
        return outcome;
    }

    /// <summary>Opens TLS-PSK and authenticates. The caller owns the returned channel.</summary>
    public async Task<SessionChannel> OpenSessionAsync(string host, int port, TrustedPeer peer, CancellationToken ct = default)
    {
        var psk = secrets.ReadPsk(peer.PeerID) ?? throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "no PSK for peer");
        var client = await ConnectAsync(host, port, ct).ConfigureAwait(false);
        PskTlsConnection tls;
        try
        {
            tls = await PskTls.ConnectAsync(client.GetStream(), Identity.PeerID, psk, Timeouts.Handshake, ct).ConfigureAwait(false);
        }
        catch
        {
            client.Dispose();
            throw;
        }
        var channel = new SessionChannel(StreamFrameTransport.Over(client, tls.Stream, Limits, tls), SessionChannelOptions.Session);
        try
        {
            await SessionAuthenticator.AuthenticateAsInitiatorAsync(channel, Identity, Device, peer, Timeouts.SessionAuth, ct).ConfigureAwait(false);
            return channel;
        }
        catch
        {
            await channel.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    public async Task<TransferCommitted> SendFileAsync(string host, int port, TrustedPeer peer, OutgoingFile file, Guid? transferID = null, SendFault fault = SendFault.None, Action<long>? progress = null, Action? sessionReady = null, CancellationToken ct = default)
    {
        await using var channel = await OpenSessionAsync(host, port, peer, ct).ConfigureAwait(false);
        sessionReady?.Invoke();
        var sender = new TransferSender(channel, Identity.PeerID, peer.PeerID, Limits);
        return await sender.SendAsync(file, transferID, null, fault, progress, ct).ConfigureAwait(false);
    }

    private static async Task<TcpClient> ConnectAsync(string host, int port, CancellationToken ct)
    {
        var client = new TcpClient { NoDelay = true };
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(10));
            await client.ConnectAsync(host, port, cts.Token).ConfigureAwait(false);
            return client;
        }
        catch (Exception ex) when (ex is SocketException or OperationCanceledException)
        {
            client.Dispose();
            throw new BridgeException(BridgeErrorCode.NoPeer, "connect failed", ex);
        }
    }
}
