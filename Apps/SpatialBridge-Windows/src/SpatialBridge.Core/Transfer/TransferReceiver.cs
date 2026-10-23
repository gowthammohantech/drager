using SpatialBridge.Core.Framing;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Pairing;
using SpatialBridge.Core.Session;

namespace SpatialBridge.Core.Transfer;

/// <summary>What the receiver reports. Success is only <see cref="Committed"/>, raised after the durable rename.</summary>
public abstract record TransferEvent(TransferOffer Offer, TrustedPeer Peer)
{
    public sealed record Accepted(TransferOffer Offer, TrustedPeer Peer) : TransferEvent(Offer, Peer);
    public sealed record Progress(TransferOffer Offer, TrustedPeer Peer, long BytesReceived) : TransferEvent(Offer, Peer);
    public sealed record Verifying(TransferOffer Offer, TrustedPeer Peer) : TransferEvent(Offer, Peer);
    public sealed record Committed(TransferOffer Offer, TrustedPeer Peer, string SavedPath, string SavedFilename, string Sha256Hex) : TransferEvent(Offer, Peer);
    public sealed record Rejected(TransferOffer Offer, TrustedPeer Peer, BridgeErrorCode Code) : TransferEvent(Offer, Peer);
    public sealed record Failed(TransferOffer Offer, TrustedPeer Peer, BridgeErrorCode Code) : TransferEvent(Offer, Peer);
    /// <summary>A replayed offer for a committed ID, answered from the ledger without writing.</summary>
    public sealed record Replayed(TransferOffer Offer, TrustedPeer Peer, string SavedFilename) : TransferEvent(Offer, Peer);
}

public sealed record TransferReceiverOptions
{
    public TransferPolicy Policy { get; init; } = TransferPolicy.Default;
    public long ProgressAckInterval { get; init; } = 1 << 20;
}

/// <summary>
/// Receives transfers on one authenticated session, one at a time (ADR-007): offer → validate → ACCEPT →
/// strict sequence/offset chunks into a staging file with incremental SHA-256 → COMPLETE → verify →
/// fsync → exclusive collision-safe rename → committed event → COMMITTED. Every failure removes staging.
/// </summary>
public sealed class TransferReceiver(
    SessionChannel channel,
    TrustedPeer peer,
    string localPeerID,
    FolderDestination destination,
    StagingArea staging,
    TransferOutcomeLedger ledger,
    Action<TransferEvent> emit,
    TransferReceiverOptions? options = null)
{
    private readonly TransferReceiverOptions _options = options ?? new TransferReceiverOptions();

    private TransferLimits Limits => _options.Policy.Limits;

    /// <summary>Serves offers until the session closes. Never throws.</summary>
    public async Task RunAsync(CancellationToken ct = default)
    {
        while (!ct.IsCancellationRequested)
        {
            ControlMessage message;
            try
            {
                message = await channel.ReceiveControlAsync(null, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is BridgeException or OperationCanceledException)
            {
                if (ex is BridgeException { Code: BridgeErrorCode.ProtocolMismatch } && !channel.IsClosed)
                {
                    await channel.TrySendAsync(new TransferErrorMessage(null, BridgeErrorCode.ProtocolMismatch)).ConfigureAwait(false);
                    channel.Close(BridgeErrorCode.ProtocolMismatch);
                }
                return;
            }
            switch (message)
            {
                case TransferOffer offer:
                    await HandleAsync(offer, ct).ConfigureAwait(false);
                    break;
                case TransferCancel or TransferComplete or TransferProgress:
                    break;
                default:
                    await channel.TrySendAsync(new TransferErrorMessage(message.TransferRef, BridgeErrorCode.ProtocolMismatch)).ConfigureAwait(false);
                    break;
            }
        }
    }

    private async Task HandleAsync(TransferOffer offer, CancellationToken ct)
    {
        if (ledger.Outcome(offer.TransferID) is TransferOutcome.Committed done)
        {
            await channel.TrySendAsync(new TransferCommitted(offer.TransferID, done.SavedFilename, done.ByteCount)).ConfigureAwait(false);
            emit(new TransferEvent.Replayed(offer, peer, done.SavedFilename));
            return;
        }

        try
        {
            Validate(offer);
        }
        catch (BridgeException ex)
        {
            ledger.Record(offer.TransferID, new TransferOutcome.Failed(ex.Code));
            await channel.TrySendAsync(new TransferReject(offer.TransferID, ex.Code)).ConfigureAwait(false);
            emit(new TransferEvent.Rejected(offer, peer, ex.Code));
            return;
        }

        var chunkBytes = Math.Min(Limits.ChunkBytes, Limits.MaxChunkBytes);
        try
        {
            await channel.SendAsync(new TransferAccept(offer.TransferID, chunkBytes), ct).ConfigureAwait(false);
        }
        catch (BridgeException)
        {
            return;
        }
        emit(new TransferEvent.Accepted(offer, peer));

        try
        {
            var (path, digest) = await ReceiveAsync(offer, ct).ConfigureAwait(false);
            var savedName = Path.GetFileName(path);
            ledger.Record(offer.TransferID, new TransferOutcome.Committed(savedName, offer.ByteCount));
            // Emit before acknowledging so both success states follow durable storage together.
            emit(new TransferEvent.Committed(offer, peer, path, savedName, digest));
            await channel.TrySendAsync(new TransferCommitted(offer.TransferID, savedName, offer.ByteCount)).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is BridgeException or OperationCanceledException)
        {
            var code = BridgeException.Classify(ex, true);
            staging.Remove(offer.TransferID);
            ledger.Record(offer.TransferID, new TransferOutcome.Failed(code));
            if (!channel.IsClosed) await channel.TrySendAsync(new TransferErrorMessage(offer.TransferID, code)).ConfigureAwait(false);
            emit(new TransferEvent.Failed(offer, peer, code));
        }
    }

    private void Validate(TransferOffer offer)
    {
        if (offer.SourcePeerID != peer.PeerID) throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "offer source does not match session peer");
        if (offer.TargetPeerID != localPeerID) throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "offer addressed to another device");
        _options.Policy.Validate(offer);
        destination.ValidateAccess();
        var free = destination.AvailableCapacity();
        if (free < offer.ByteCount + Limits.DiskHeadroomBytes) throw new BridgeException(BridgeErrorCode.InsufficientStorage, "low disk space");
    }

    private async Task<(string Path, string Digest)> ReceiveAsync(TransferOffer offer, CancellationToken ct)
    {
        using var writer = staging.CreateWriter(offer.TransferID, offer.ByteCount);
        uint expectedSequence = 0;
        long lastAck = 0;
        TransferComplete? complete = null;
        try
        {
            while (complete is null)
            {
                var frame = await channel.ReceiveAsync(Limits.TransferIdleTimeout, ct).ConfigureAwait(false);
                switch (frame)
                {
                    case ChunkFrame chunk:
                        if (chunk.TransferID != offer.TransferID) throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "chunk for another transfer");
                        if (chunk.Sequence != expectedSequence || chunk.Offset != (ulong)writer.BytesWritten)
                        {
                            throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "out-of-order chunk");
                        }
                        await writer.AppendAsync(chunk.Payload, ct).ConfigureAwait(false);
                        expectedSequence = unchecked(expectedSequence + 1);
                        if (writer.BytesWritten - lastAck >= _options.ProgressAckInterval || writer.BytesWritten == offer.ByteCount)
                        {
                            lastAck = writer.BytesWritten;
                            await channel.SendAsync(new TransferProgress(offer.TransferID, lastAck), ct).ConfigureAwait(false);
                            emit(new TransferEvent.Progress(offer, peer, lastAck));
                        }
                        break;
                    case ControlFrame control:
                        var message = ControlMessageCoder.Decode(control.Payload);
                        switch (message)
                        {
                            case TransferComplete c when c.TransferID == offer.TransferID:
                                complete = c;
                                break;
                            case TransferCancel c when c.TransferID == offer.TransferID:
                                throw new BridgeException(BridgeErrorCode.TransferCanceled, "sender cancelled");
                            case TransferErrorMessage e:
                                throw new BridgeException(e.Code, "sender error");
                            case TransferOffer other:
                                await channel.TrySendAsync(new TransferReject(other.TransferID, BridgeErrorCode.ProtocolMismatch, "busy")).ConfigureAwait(false);
                                break;
                            default:
                                throw new BridgeException(BridgeErrorCode.ProtocolMismatch, $"unexpected {message.Kind} during transfer");
                        }
                        break;
                }
            }

            emit(new TransferEvent.Verifying(offer, peer));
            var digest = writer.Finish();
            if (writer.BytesWritten != offer.ByteCount
                || complete.ByteCount != offer.ByteCount
                || !string.Equals(digest, offer.Sha256Hex, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(complete.Sha256Hex, digest, StringComparison.OrdinalIgnoreCase))
            {
                throw new BridgeException(BridgeErrorCode.HashMismatch, "size or digest mismatch");
            }
            return (await destination.CommitAsync(writer.Path, offer.Filename, ct).ConfigureAwait(false), digest);
        }
        catch
        {
            writer.Abandon();
            throw;
        }
    }
}
