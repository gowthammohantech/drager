using System.Collections.Concurrent;
using System.Collections.Frozen;
using System.Net;
using System.Net.Sockets;
using SpatialBridge.Core.Crypto;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Net;
using SpatialBridge.Core.Pairing;
using SpatialBridge.Core.Session;
using SpatialBridge.Core.Tls;
using SpatialBridge.Core.Transfer;

namespace SpatialBridge.Core.Services;

public sealed record ReceiverOptions
{
    public string DisplayName { get; init; } = Environment.MachineName;
    public string Model { get; init; } = "PC";
    public DevicePlatform Platform { get; init; } = DevicePlatform.Windows;

    /// <summary>Defaults to dual-stack any. Use loopback for tests and the CLI.</summary>
    public IPAddress ListenAddress { get; init; } = IPAddress.IPv6Any;
    public int PairingPort { get; init; }
    public int SessionPort { get; init; }

    public string? DestinationFolder { get; init; }

    /// <summary>Null keeps staging inside the destination folder, so the final rename stays on one volume.</summary>
    public string? StagingFolder { get; init; }

    public TransferPolicy Policy { get; init; } = TransferPolicy.Default;
    public ProtocolTimeouts Timeouts { get; init; } = ProtocolTimeouts.Default;
    public SessionChannelOptions SessionChannel { get; init; } = SessionChannelOptions.Session;
    public int MaxPendingHandshakes { get; init; } = 8;
    public TimeProvider Time { get; init; } = TimeProvider.System;
    public Func<string, long>? FreeSpace { get; init; }

    /// <summary>Redacted diagnostics only: codes and short peer IDs, never names, paths or secrets.</summary>
    public Action<string>? Log { get; init; }
}

/// <summary>Detailed pairing results for diagnostics and the CLI (the facade only gets <see cref="ReceiverEvent.Paired"/>).</summary>
public abstract record PairingActivity
{
    private PairingActivity() { }

    public sealed record Prompted(PairingRequestPrompt Prompt) : PairingActivity;
    public sealed record Succeeded(TrustedPeer Peer, string ShortAuthenticationString, string PskFingerprint) : PairingActivity;
    public sealed record Failed(BridgeErrorCode Code) : PairingActivity;
}

/// <summary>
/// Windows-side orchestration, mirroring Swift's ReceiverService: listeners and advertising, pairing approval
/// (one at a time, rate-limited), TLS-PSK with one key per trusted peer, session authentication, one session
/// per peer and transfer receiving. Platform services are injected.
/// </summary>
public sealed class ReceiverService : IReceiverFacade
{
    private readonly ReceiverOptions _options;
    private readonly ISecretStore _secrets;
    private readonly ITrustedPeerStore _trusted;
    private readonly IServiceAdvertiser _advertiser;
    private readonly IFileCommitter _committer;
    private readonly PairingRateLimiter _rateLimiter;
    private readonly TransferOutcomeLedger _ledger = new();
    private readonly ConcurrentDictionary<Guid, (TrustedPeer Peer, SessionChannel Channel)> _sessions = new();
    private readonly SemaphoreSlim _stateGate = new(1, 1);
    private readonly SemaphoreSlim _handshakes;
    private FrozenDictionary<string, byte[]> _psks = FrozenDictionary<string, byte[]>.Empty;
    private TcpListener? _pairingListener;
    private TcpListener? _sessionListener;
    private CancellationTokenSource? _listening;
    private int _pairingInProgress;
    private volatile TaskCompletionSource? _pairingDone;
    private string? _destination;

    public ReceiverService(ReceiverOptions options, ISecretStore secrets, ITrustedPeerStore trustedPeers, IServiceAdvertiser? advertiser = null, IFileCommitter? committer = null, PairingRateLimiter? rateLimiter = null)
    {
        _options = options;
        _secrets = secrets;
        _trusted = trustedPeers;
        _advertiser = advertiser ?? new NullServiceAdvertiser();
        _committer = committer ?? new PortableFileCommitter();
        _rateLimiter = rateLimiter ?? new PairingRateLimiter(time: options.Time);
        _handshakes = new SemaphoreSlim(options.MaxPendingHandshakes, options.MaxPendingHandshakes);
        _destination = options.DestinationFolder;
        Identity = secrets.LoadOrCreateIdentity();
        Device = DeviceInfo.Create(Identity.PeerID, options.DisplayName, options.Platform, options.Model);
        RebuildPsks();
    }

    public event EventHandler<ReceiverEvent>? EventRaised;

    /// <summary>Every transfer event, including the offer and digest (for diagnostics and the CLI).</summary>
    public event EventHandler<TransferEvent>? TransferEventRaised;

    public event EventHandler<PairingActivity>? PairingActivityRaised;

    /// <summary>A session that failed TLS or authentication, with its code.</summary>
    public event EventHandler<BridgeErrorCode>? SessionRefused;

    public Func<PairingPrompt, CancellationToken, Task<bool>>? PairingApprover { get; set; }

    public DeviceIdentity Identity { get; }

    public DeviceInfo Device { get; }

    public string PeerID => Identity.PeerID;

    public bool IsAvailable { get; private set; }

    public bool AllowPairing { get; private set; }

    public string? DestinationFolder => _destination;

    public int? PairingPort => (_pairingListener?.LocalEndpoint as IPEndPoint)?.Port;

    public int? SessionPort => (_sessionListener?.LocalEndpoint as IPEndPoint)?.Port;

    public IReadOnlyList<TrustedPeerInfo> TrustedPeers => [.. _trusted.All().Select(p => p.ToInfo())];

    public IReadOnlyList<string> ConnectedPeerIDs => [.. _sessions.Values.Select(s => s.Peer.PeerID).Distinct()];

    private AdvertisedDevice Advertised => new(Identity.PeerID, Device.DisplayName, Device.Platform);

    public async Task SetAvailableAsync(bool available, CancellationToken cancellationToken = default)
    {
        await _stateGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (available == IsAvailable) return;
            if (available)
            {
                StartListeners();
                IsAvailable = true;
                PurgeStaging();
                await _advertiser.AdvertiseAsync(ServiceRole.Session, Advertised, SessionPort!.Value, cancellationToken).ConfigureAwait(false);
                if (AllowPairing) await _advertiser.AdvertiseAsync(ServiceRole.Pairing, Advertised, PairingPort!.Value, cancellationToken).ConfigureAwait(false);
            }
            else
            {
                IsAvailable = false;
                await _advertiser.WithdrawAsync(ServiceRole.Pairing, cancellationToken).ConfigureAwait(false);
                await _advertiser.WithdrawAsync(ServiceRole.Session, cancellationToken).ConfigureAwait(false);
                StopListeners();
                foreach (var (_, s) in _sessions) s.Channel.Close(BridgeErrorCode.PeerLost);
            }
        }
        finally
        {
            _stateGate.Release();
        }
        Raise(new ReceiverEvent.AvailabilityChanged(available));
    }

    public async Task SetAllowPairingAsync(bool allow, CancellationToken cancellationToken = default)
    {
        await _stateGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (allow == AllowPairing) return;
            AllowPairing = allow;
            if (!IsAvailable) return;
            if (allow)
            {
                await _advertiser.AdvertiseAsync(ServiceRole.Pairing, Advertised, PairingPort!.Value, cancellationToken).ConfigureAwait(false);
            }
            else
            {
                await _advertiser.WithdrawAsync(ServiceRole.Pairing, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            _stateGate.Release();
        }
    }

    public Task SetDestinationFolderAsync(string folder, CancellationToken cancellationToken = default)
    {
        _destination = Path.GetFullPath(folder);
        PurgeStaging();
        return Task.CompletedTask;
    }

    public Task UnpairAsync(string peerID, CancellationToken cancellationToken = default)
    {
        _secrets.DeletePsk(peerID);
        _trusted.Remove(peerID);
        RebuildPsks();
        foreach (var (id, s) in _sessions)
        {
            if (s.Peer.PeerID == peerID && _sessions.TryRemove(id, out _))
            {
                s.Channel.Close(BridgeErrorCode.AuthenticationFailed);
                Raise(new ReceiverEvent.PeerDisconnected(peerID));
            }
        }
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            await SetAvailableAsync(false).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Log("advertiser stop failed");
        }
        StopListeners();
        await _advertiser.DisposeAsync().ConfigureAwait(false);
        _stateGate.Dispose();
        _handshakes.Dispose();
    }

    // MARK: Listeners

    private void StartListeners()
    {
        _listening = new CancellationTokenSource();
        _pairingListener = Listen(_options.PairingPort);
        _sessionListener = Listen(_options.SessionPort);
        var token = _listening.Token;
        _ = Task.Run(() => AcceptLoop(_pairingListener, HandlePairingAsync, token), CancellationToken.None);
        _ = Task.Run(() => AcceptLoop(_sessionListener, HandleSessionAsync, token), CancellationToken.None);
    }

    private TcpListener Listen(int port)
    {
        var listener = new TcpListener(_options.ListenAddress, port);
        if (_options.ListenAddress.Equals(IPAddress.IPv6Any)) listener.Server.DualMode = true;
        listener.Start();
        return listener;
    }

    private void StopListeners()
    {
        _listening?.Cancel();
        _listening?.Dispose();
        _listening = null;
        _pairingListener?.Stop();
        _sessionListener?.Stop();
    }

    private async Task AcceptLoop(TcpListener listener, Func<TcpClient, Task> handle, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(token).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException or SocketException or InvalidOperationException)
            {
                return;
            }
            client.NoDelay = true;
            if (!_handshakes.Wait(0, CancellationToken.None))
            {
                client.Dispose();
                continue;
            }
            _ = Task.Run(async () =>
            {
                try
                {
                    await handle(client).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    client.Dispose();
                    Log("connection handler failed: " + BridgeException.Classify(ex, true).ToWire());
                }
            }, CancellationToken.None);
        }
    }

    // MARK: Pairing

    private async Task HandlePairingAsync(TcpClient client)
    {
        var released = false;
        void Release()
        {
            if (!released) _handshakes.Release();
            released = true;
        }
        if (!AllowPairing || !IsAvailable || Interlocked.CompareExchange(ref _pairingInProgress, 1, 0) != 0)
        {
            Release();
            client.Dispose();
            return;
        }
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _pairingDone = done;
        try
        {
            await using var channel = new SessionChannel(StreamFrameTransport.Over(client), SessionChannelOptions.Handshake with { Time = _options.Time });
            Release();
            var outcome = await PairingProtocol.RunResponderAsync(channel, Identity, Device, _rateLimiter, DecideAsync, _options.Timeouts, _options.Time).ConfigureAwait(false);
            _secrets.WritePsk(outcome.TrustedPeer.PeerID, outcome.PreSharedKey);
            _trusted.Upsert(outcome.TrustedPeer);
            RebuildPsks();
            Log($"paired with {PeerIds.ShortForm(outcome.TrustedPeer.PeerID)}");
            PairingActivityRaised?.Invoke(this, new PairingActivity.Succeeded(outcome.TrustedPeer, outcome.ShortAuthenticationString, PairingCrypto.PskFingerprint(outcome.PreSharedKey)));
            Raise(new ReceiverEvent.Paired(outcome.TrustedPeer.ToInfo()));
        }
        catch (Exception ex) when (ex is BridgeException or OperationCanceledException)
        {
            var code = BridgeException.Classify(ex, true);
            Log("pairing failed: " + code.ToWire());
            PairingActivityRaised?.Invoke(this, new PairingActivity.Failed(code));
            Raise(new ReceiverEvent.PairingFailed(code));
        }
        finally
        {
            Release();
            Interlocked.Exchange(ref _pairingInProgress, 0);
            done.TrySetResult();
        }
    }

    private async Task<bool> DecideAsync(PairingRequestPrompt prompt, CancellationToken ct)
    {
        PairingActivityRaised?.Invoke(this, new PairingActivity.Prompted(prompt));
        if (PairingApprover is not { } approver) return false;
        return await approver(new PairingPrompt(prompt.Peer.DisplayName, prompt.Peer.Platform, prompt.ShortAuthenticationString), ct).ConfigureAwait(false);
    }

    // MARK: Sessions

    private void RebuildPsks()
    {
        var map = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var peer in _trusted.All())
        {
            if (_secrets.ReadPsk(peer.PeerID) is { Length: 32 } psk) map[peer.PeerID] = psk;
        }
        _psks = map.ToFrozenDictionary(StringComparer.Ordinal);
    }

    /// <summary>
    /// The initiator finishes pairing as soon as it holds our PAIR_CONFIRM, which can be before we have verified its
    /// confirm and stored the PSK. An unknown identity therefore waits briefly for an in-flight pairing.
    /// Runs on BouncyCastle's handshake thread, so blocking here is safe.
    /// </summary>
    private byte[]? LookupPsk(string identity)
    {
        if (_psks.TryGetValue(identity, out var psk)) return psk;
        if (Volatile.Read(ref _pairingInProgress) != 0 && _pairingDone is { } pending)
        {
            pending.Task.Wait(TimeSpan.FromSeconds(5));
        }
        return _psks.GetValueOrDefault(identity);
    }

    private async Task HandleSessionAsync(TcpClient client)
    {
        SessionChannel channel;
        TrustedPeer peer;
        try
        {
            PskTlsConnection tls;
            try
            {
                tls = await PskTls.AcceptAsync(client.GetStream(), LookupPsk, _options.Timeouts.Handshake).ConfigureAwait(false);
            }
            catch (BridgeException ex)
            {
                client.Dispose();
                Log("session TLS refused: " + ex.Code.ToWire());
                SessionRefused?.Invoke(this, ex.Code);
                return;
            }
            channel = new SessionChannel(StreamFrameTransport.Over(client, tls.Stream, null, tls), _options.SessionChannel with { Time = _options.Time });
            try
            {
                (peer, _) = await SessionAuthenticator.AuthenticateAsResponderAsync(channel, Identity, Device, _trusted.Find, tls.Identity, _options.Timeouts.SessionAuth).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is BridgeException or OperationCanceledException)
            {
                var code = BridgeException.Classify(ex, true);
                channel.Close(code);
                await channel.DisposeAsync().ConfigureAwait(false);
                Log("session refused: " + code.ToWire());
                SessionRefused?.Invoke(this, code);
                return;
            }
        }
        finally
        {
            _handshakes.Release();
        }

        await using (channel)
        {
            if (!IsAvailable)
            {
                channel.Close(BridgeErrorCode.PeerLost);
                return;
            }
            foreach (var (id, existing) in _sessions)
            {
                if (existing.Peer.PeerID == peer.PeerID && _sessions.TryRemove(id, out _)) existing.Channel.Close();
            }
            var sessionID = Guid.NewGuid();
            _sessions[sessionID] = (peer, channel);
            _trusted.Upsert(peer with { LastSeenAt = _options.Time.GetUtcNow() });
            Log($"session with {PeerIds.ShortForm(peer.PeerID)} authenticated");
            Raise(new ReceiverEvent.PeerConnected(peer.PeerID, peer.DisplayName));

            await RunTransfersAsync(channel, peer).ConfigureAwait(false);

            channel.Close();
            if (_sessions.TryRemove(sessionID, out _)) Raise(new ReceiverEvent.PeerDisconnected(peer.PeerID));
        }
    }

    private async Task RunTransfersAsync(SessionChannel channel, TrustedPeer peer)
    {
        var folder = _destination;
        FolderDestination destination;
        StagingArea staging;
        if (folder is null)
        {
            // No destination yet: every offer is refused with E009 by the access check.
            var missing = Path.Combine(Path.GetTempPath(), "sb-no-destination-" + Guid.NewGuid().ToString("N"));
            destination = new FolderDestination(missing, _committer, _options.FreeSpace);
            staging = new StagingArea(_options.StagingFolder ?? Path.Combine(Path.GetTempPath(), StagingArea.DefaultFolderName));
        }
        else
        {
            destination = new FolderDestination(folder, _committer, _options.FreeSpace);
            staging = _options.StagingFolder is { } s ? new StagingArea(s) : StagingArea.In(folder);
        }
        var receiver = new TransferReceiver(channel, peer, Identity.PeerID, destination, staging, _ledger, OnTransferEvent, new TransferReceiverOptions { Policy = _options.Policy });
        await receiver.RunAsync().ConfigureAwait(false);
    }

    private void OnTransferEvent(TransferEvent e)
    {
        TransferEventRaised?.Invoke(this, e);
        var id = e.Offer.TransferID;
        switch (e)
        {
            case TransferEvent.Accepted:
                Raise(new ReceiverEvent.TransferIncoming(id, e.Peer.DisplayName, e.Offer.ByteCount, e.Offer.Gesture) { Filename = e.Offer.Filename, ContentType = e.Offer.ContentType });
                break;
            case TransferEvent.Verifying:
                Raise(new ReceiverEvent.TransferVerifying(id));
                break;
            case TransferEvent.Progress p:
                Raise(new ReceiverEvent.TransferProgress(id, p.BytesReceived, e.Offer.ByteCount));
                break;
            case TransferEvent.Committed c:
                Log($"transfer {id.ToString()[..8]} committed ({e.Offer.ByteCount} bytes)");
                Raise(new ReceiverEvent.TransferCommitted(id, c.SavedPath, e.Offer.ByteCount));
                break;
            case TransferEvent.Rejected r:
                Log($"transfer {id.ToString()[..8]} rejected: {r.Code.ToWire()}");
                Raise(new ReceiverEvent.TransferFailed(id, r.Code));
                break;
            case TransferEvent.Failed f:
                Log($"transfer {id.ToString()[..8]} failed: {f.Code.ToWire()}");
                Raise(new ReceiverEvent.TransferFailed(id, f.Code));
                break;
        }
    }

    private void PurgeStaging()
    {
        try
        {
            var dir = _options.StagingFolder ?? (_destination is { } d ? Path.Combine(d, StagingArea.DefaultFolderName) : null);
            if (dir is not null && Directory.Exists(dir)) new StagingArea(dir).Purge(_options.Policy.Limits.StagingRetention, _options.Time.GetUtcNow());
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log("staging purge failed");
        }
    }

    private void Raise(ReceiverEvent e) => EventRaised?.Invoke(this, e);

    private void Log(string message) => _options.Log?.Invoke(message);
}
