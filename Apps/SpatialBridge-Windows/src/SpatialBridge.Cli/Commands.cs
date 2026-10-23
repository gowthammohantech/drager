using System.Net;
using System.Net.Sockets;
using SpatialBridge.Core;
using SpatialBridge.Core.Crypto;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Net;
using SpatialBridge.Core.Pairing;
using SpatialBridge.Core.Services;
using SpatialBridge.Core.Session;
using SpatialBridge.Core.Transfer;

namespace SpatialBridge.Cli;

/// <summary><c>--state DIR</c>: unencrypted test-only identity and trust (secrets.json, trusted-peers.json, staging/).</summary>
internal sealed class HarnessState
{
    public HarnessState(string dir)
    {
        Directory.CreateDirectory(dir);
        Dir = Path.GetFullPath(dir);
        Secrets = new FileSecretStore(Path.Combine(Dir, "secrets.json"));
        Trusted = new FileTrustedPeerStore(Path.Combine(Dir, "trusted-peers.json"));
    }

    public string Dir { get; }
    public FileSecretStore Secrets { get; }
    public FileTrustedPeerStore Trusted { get; }
    public string Staging => Path.Combine(Dir, "staging");

    /// <summary>Peers that currently have a pair PSK on disk.</summary>
    public HashSet<string> PairedPeers() =>
        [.. Secrets.Keys(BridgeProtocol.SecretKey.PairPskPrefix).Select(k => k[BridgeProtocol.SecretKey.PairPskPrefix.Length..])];
}

/// <summary>
/// <c>unpair --state DIR --peer PEERID</c>: forgets a peer (pair PSK and trust entry). Idempotent. A <c>serve</c> on the
/// same state notices within <see cref="WatchIntervalMs"/> and prints its own <c>unpaired</c>.
/// </summary>
internal static class UnpairCommand
{
    public const int WatchIntervalMs = 200;

    public static int Run(Args args)
    {
        var state = new HarnessState(args.Required("state"));
        var peer = args.Required("peer");
        if (!PeerIds.IsValid(peer)) throw new UsageException("--peer must be a peer ID (32 lowercase hex characters)");
        state.Secrets.DeletePsk(peer);
        state.Trusted.Remove(peer);
        Out.Event("unpaired", ("peerID", peer));
        return 0;
    }

    /// <summary>
    /// Polls the state for PSKs another process removed. The baseline also holds every peer this process paired
    /// (<paramref name="paired"/>), so an unpair that lands between a pairing and the next poll is still noticed.
    /// </summary>
    public static async Task WatchAsync(HarnessState state, System.Collections.Concurrent.ConcurrentDictionary<string, bool> paired, Func<string, Task> removed, CancellationToken cancellationToken = default)
    {
        var known = state.PairedPeers();
        while (!cancellationToken.IsCancellationRequested)
        {
            await Task.Delay(WatchIntervalMs, cancellationToken).ConfigureAwait(false);
            // Merge local pairings before reading the disk: their PSK was written before the event, so it is on disk.
            foreach (var peer in paired.Keys)
            {
                known.Add(peer);
                paired.TryRemove(peer, out _);
            }
            HashSet<string> now;
            try
            {
                now = state.PairedPeers();
            }
            catch (IOException)
            {
                continue;
            }
            foreach (var peer in known.Except(now).Order(StringComparer.Ordinal)) await removed(peer).ConfigureAwait(false);
            known = now;
        }
    }
}

/// <summary>Shorter timeouts for fault runs (<c>--test-mode</c>), matching sb-swift.</summary>
internal static class HarnessTimeouts
{
    public static ProtocolTimeouts Protocol(bool testMode) => testMode
        ? new ProtocolTimeouts { Handshake = TimeSpan.FromSeconds(10), UserDecision = TimeSpan.FromSeconds(10), SessionAuth = TimeSpan.FromSeconds(10) }
        : ProtocolTimeouts.Default;

    public static TransferLimits Limits(bool testMode) => testMode
        ? TransferLimits.Default with { HandshakeTimeout = TimeSpan.FromSeconds(10), TransferIdleTimeout = TimeSpan.FromSeconds(5) }
        : TransferLimits.Default;
}

internal static class Decision
{
    public static bool Parse(Args args) => args.Required("decision") switch
    {
        "approve" => true,
        "reject" => false,
        _ => throw new UsageException("--decision must be approve or reject"),
    };

    public static PairingDecisionHandler Handler(bool approve) => (prompt, _) =>
    {
        Out.Event("sas", ("code", prompt.ShortAuthenticationString));
        return Task.FromResult(approve);
    };
}

internal static class PairCommands
{
    public static async Task<int> InitiateAsync(Args args)
    {
        var state = new HarnessState(args.Required("state"));
        var approve = Decision.Parse(args);
        var (host, port) = args.HostPort("connect");
        var client = new SenderClient(state.Secrets, state.Trusted, "sb-dotnet", DevicePlatform.Android, "dotnet") { Timeouts = HarnessTimeouts.Protocol(args.Flag("test-mode")) };
        try
        {
            var outcome = await client.PairAsync(host, port, Decision.Handler(approve));
            Paired(outcome.TrustedPeer.PeerID, outcome.PreSharedKey);
            Out.Event("done");
            return 0;
        }
        catch (Exception ex) when (ex is BridgeException or OperationCanceledException)
        {
            return PairFailed(BridgeException.Classify(ex, true));
        }
    }

    /// <summary>Handles one pairing attempt as the responder, then exits.</summary>
    public static async Task<int> RespondAsync(Args args)
    {
        var state = new HarnessState(args.Required("state"));
        var approve = Decision.Parse(args);
        var testMode = args.Flag("test-mode");
        var (host, port) = args.HostPort("listen");
        var identity = state.Secrets.LoadOrCreateIdentity();
        var device = DeviceInfo.Create(identity.PeerID, "sb-dotnet", DevicePlatform.Windows, "dotnet");
        using var listener = new TcpListener(IPAddress.Parse(host), port);
        listener.Start();
        var bound = ((IPEndPoint)listener.LocalEndpoint).Port;
        Out.Event("listening", ("pairingPort", bound), ("port", bound));
        var socket = await listener.AcceptTcpClientAsync();
        socket.NoDelay = true;
        try
        {
            await using var channel = new SessionChannel(StreamFrameTransport.Over(socket), SessionChannelOptions.Handshake);
            var outcome = await PairingProtocol.RunResponderAsync(channel, identity, device, new PairingRateLimiter(), Decision.Handler(approve), HarnessTimeouts.Protocol(testMode));
            state.Secrets.WritePsk(outcome.TrustedPeer.PeerID, outcome.PreSharedKey);
            state.Trusted.Upsert(outcome.TrustedPeer);
            Paired(outcome.TrustedPeer.PeerID, outcome.PreSharedKey);
            Out.Event("done");
            return 0;
        }
        catch (Exception ex) when (ex is BridgeException or OperationCanceledException)
        {
            return PairFailed(BridgeException.Classify(ex, true));
        }
    }

    public static void Paired(string peerID, byte[] psk) =>
        Out.Event("paired", ("peerID", peerID), ("pskFingerprint", PairingCrypto.PskFingerprint(psk)));

    public static int PairFailed(BridgeErrorCode code)
    {
        Out.Event("pairFailed", ("code", code.ToWire()));
        return code.ExitCode();
    }
}

internal static class ServeCommand
{
    /// <summary>The receiver role on loopback, with no advertising. Runs until killed.</summary>
    public static async Task<int> RunAsync(Args args)
    {
        var state = new HarnessState(args.Required("state"));
        var approve = Decision.Parse(args);
        var testMode = args.Flag("test-mode");
        var (host, port) = args.HostPort("listen");
        var dest = Path.GetFullPath(args.Required("dest"));
        Directory.CreateDirectory(dest);
        var sessionPort = args.Optional("session-port") is { } sp ? int.Parse(sp, System.Globalization.CultureInfo.InvariantCulture) : 0;
        var limits = HarnessTimeouts.Limits(testMode);

        await using var service = new ReceiverService(
            new ReceiverOptions
            {
                DisplayName = "sb-dotnet",
                Model = "dotnet",
                ListenAddress = IPAddress.Parse(host),
                PairingPort = port,
                SessionPort = sessionPort,
                DestinationFolder = dest,
                StagingFolder = state.Staging,
                Timeouts = HarnessTimeouts.Protocol(testMode),
                Policy = TransferPolicy.Default with { Limits = limits },
                Log = Environment.GetEnvironmentVariable("SB_DEBUG") == "1" ? Out.Log : null,
            },
            state.Secrets,
            state.Trusted);
        service.PairingApprover = (_, _) => Task.FromResult(approve);
        var pairedHere = new System.Collections.Concurrent.ConcurrentDictionary<string, bool>(StringComparer.Ordinal);
        service.PairingActivityRaised += (_, activity) =>
        {
            switch (activity)
            {
                case PairingActivity.Prompted p:
                    Out.Event("sas", ("code", p.Prompt.ShortAuthenticationString));
                    break;
                case PairingActivity.Succeeded s:
                    pairedHere[s.Peer.PeerID] = true;
                    Out.Event("paired", ("peerID", s.Peer.PeerID), ("pskFingerprint", s.PskFingerprint));
                    break;
                case PairingActivity.Failed f:
                    Out.Event("pairFailed", ("code", f.Code.ToWire()));
                    break;
            }
        };
        service.SessionRefused += (_, code) => Out.Error(code);
        service.EventRaised += (_, e) =>
        {
            if (e is ReceiverEvent.PeerConnected c) Out.Event("sessionReady", ("peerID", c.PeerID));
        };
        service.TransferEventRaised += (_, e) =>
        {
            switch (e)
            {
                case TransferEvent.Progress p:
                    Out.Event("progress", ("offset", p.BytesReceived));
                    break;
                case TransferEvent.Committed c:
                    Out.Event("committed", ("transferID", Uuids.ToWire(c.Offer.TransferID)), ("byteCount", c.Offer.ByteCount), ("sha256Hex", c.Sha256Hex));
                    break;
                case TransferEvent.Replayed r:
                    Out.Event("committed", ("transferID", Uuids.ToWire(r.Offer.TransferID)), ("byteCount", r.Offer.ByteCount), ("sha256Hex", r.Offer.Sha256Hex.ToLowerInvariant()), ("replayed", true));
                    break;
                case TransferEvent.Rejected r:
                    Out.Error(r.Code);
                    break;
                case TransferEvent.Failed f:
                    Out.Error(f.Code);
                    break;
            }
        };
        await service.SetAllowPairingAsync(true);
        await service.SetAvailableAsync(true);
        Out.Event("listening", ("pairingPort", service.PairingPort), ("sessionPort", service.SessionPort));
        // The service caches PSKs, so an unpair by another process is applied here: it drops the key and trust
        // entry and closes that peer's live sessions; the next session from it fails E004.
        await UnpairCommand.WatchAsync(state, pairedHere, async peer =>
        {
            await service.UnpairAsync(peer);
            Out.Event("unpaired", ("peerID", peer));
        });
        return 0;
    }
}

internal static class SendCommand
{
    public static async Task<int> RunAsync(Args args)
    {
        var state = new HarnessState(args.Required("state"));
        var testMode = args.Flag("test-mode");
        var (host, port) = args.HostPort("connect");
        var path = args.Required("file");
        if (!File.Exists(path)) throw new UsageException("--file does not exist");
        var contentType = args.Optional("content-type") ?? UtiCatalog.TypeForExtension(FilenameSanitizer.SplitExtension(Path.GetFileName(path)).Extension) ?? "public.data";
        Guid? transferID = null;
        if (args.Optional("transfer-id") is { } raw)
        {
            if (!Uuids.TryParse(raw, out var id)) throw new UsageException("--transfer-id must be a UUID");
            transferID = id;
        }
        var fault = args.Optional("fault") switch
        {
            null => SendFault.None,
            "corrupt-chunk" => SendFault.CorruptChunk,
            "out-of-order" => SendFault.OutOfOrder,
            "cancel-mid" => SendFault.CancelMid,
            "oversize-offer" => SendFault.OversizeOffer,
            "unsafe-name" => SendFault.UnsafeName,
            "stall" => SendFault.Stall,
            _ => throw new UsageException("unknown --fault"),
        };
        var requested = args.Optional("peer");
        var peers = state.Trusted.All();
        var peer = requested is null ? peers.MaxBy(p => p.PairedAt) : peers.FirstOrDefault(p => p.PeerID == requested);
        if (peer is null)
        {
            Out.Error(BridgeErrorCode.AuthenticationFailed);
            return BridgeErrorCode.AuthenticationFailed.ExitCode();
        }

        var client = new SenderClient(state.Secrets, state.Trusted, "sb-dotnet", DevicePlatform.Android, "dotnet")
        {
            Timeouts = HarnessTimeouts.Protocol(testMode),
            Limits = HarnessTimeouts.Limits(testMode),
        };
        try
        {
            var (sha, _) = await TransferSender.HashFileAsync(path);
            var committed = await client.SendFileAsync(host, port, peer, new OutgoingFile(path, Path.GetFileName(path), contentType), transferID, fault,
                // The receiver acknowledges every 1 MiB and at the end.
                progress: offset => Out.Event("progress", ("offset", offset)),
                sessionReady: () => Out.Event("sessionReady", ("peerID", peer.PeerID)));
            Out.Event("committed", ("transferID", Uuids.ToWire(committed.TransferID)), ("byteCount", committed.ByteCount), ("sha256Hex", sha));
            Out.Event("done");
            return 0;
        }
        catch (Exception ex) when (ex is BridgeException or OperationCanceledException or IOException)
        {
            var code = BridgeException.Classify(ex, true);
            Out.Error(code);
            return code.ExitCode();
        }
    }
}
