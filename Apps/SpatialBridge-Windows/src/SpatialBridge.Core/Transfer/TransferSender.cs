using System.Security.Cryptography;
using SpatialBridge.Core.Framing;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Session;

namespace SpatialBridge.Core.Transfer;

/// <summary>Deliberate protocol violations for interop fault tests (CONFORMANCE.md §5).</summary>
public enum SendFault { None, CorruptChunk, OutOfOrder, CancelMid, OversizeOffer, UnsafeName, Stall }

public sealed record OutgoingFile(string Path, string Filename, string ContentType);

/// <summary>
/// Sends one file over an authenticated session: offer → ACCEPT/REJECT (or a replayed COMMITTED) → chunks
/// while reading PROGRESS → COMPLETE → COMMITTED. Success is reported only on COMMITTED.
/// </summary>
public sealed class TransferSender(SessionChannel channel, string localPeerID, string remotePeerID, TransferLimits? limits = null, TimeProvider? time = null)
{
    private readonly TransferLimits _limits = limits ?? TransferLimits.Default;
    private readonly TimeProvider _time = time ?? TimeProvider.System;

    public static async Task<(string Sha256Hex, long ByteCount)> HashFileAsync(string path, CancellationToken ct = default)
    {
        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream, ct).ConfigureAwait(false);
        return (Hex.Encode(hash), stream.Length);
    }

    public async Task<TransferCommitted> SendAsync(OutgoingFile file, Guid? transferID = null, ExitGesture? gesture = null, SendFault fault = SendFault.None, Action<long>? progress = null, CancellationToken ct = default)
    {
        var (digest, byteCount) = await HashFileAsync(file.Path, ct).ConfigureAwait(false);
        if (fault != SendFault.OversizeOffer)
        {
            if (byteCount <= 0) throw new BridgeException(BridgeErrorCode.UnsupportedFile, "empty file");
            if (byteCount > _limits.MaxFileBytes) throw new BridgeException(BridgeErrorCode.SizeLimit, "too large");
        }
        var id = transferID ?? Guid.NewGuid();
        var offer = new TransferOffer(
            BridgeProtocol.Version, id, localPeerID, remotePeerID,
            fault == SendFault.UnsafeName ? "../sb-unsafe.txt" : FilenameSanitizer.Sanitize(file.Filename, file.ContentType),
            file.ContentType,
            fault == SendFault.OversizeOffer ? _limits.MaxFileBytes + 1 : byteCount,
            digest, gesture, Clock.NowMillis(_time));

        channel.DrainInbox();
        await channel.SendAsync(offer, ct).ConfigureAwait(false);
        TransferAccept accept;
        switch (await channel.ReceiveControlAsync(_limits.HandshakeTimeout, ct).ConfigureAwait(false))
        {
            case TransferAccept a when a.TransferID == id:
                accept = a;
                break;
            case TransferReject r when r.TransferID == id:
                throw new BridgeException(r.Reason, "receiver rejected the offer");
            case TransferCommitted c when c.TransferID == id:
                return c;
            case TransferErrorMessage e:
                throw new BridgeException(e.Code, "receiver error");
            default:
                throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "expected TRANSFER_ACCEPT");
        }

        if (fault == SendFault.Stall)
        {
            // Stay quiet; keepalive continues. The receiver's idle timeout ends the transfer.
            return await ReadUntilCommittedAsync(id, null, ct).ConfigureAwait(false);
        }

        var chunkBytes = Math.Max(1, Math.Min(accept.ChunkBytes, Math.Min(_limits.ChunkBytes, _limits.MaxChunkBytes)));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var reader = ReadUntilCommittedAsync(id, progress, linked.Token);
        var writer = WriteChunksAsync(file.Path, id, digest, byteCount, chunkBytes, fault, linked.Token);
        try
        {
            var first = await Task.WhenAny(reader, writer).ConfigureAwait(false);
            if (first == writer)
            {
                await writer.ConfigureAwait(false);
            }
            return await reader.ConfigureAwait(false);
        }
        finally
        {
            await linked.CancelAsync().ConfigureAwait(false);
            _ = writer.ContinueWith(static t => _ = t.Exception, TaskScheduler.Default);
            _ = reader.ContinueWith(static t => _ = t.Exception, TaskScheduler.Default);
        }
    }

    private async Task WriteChunksAsync(string path, Guid id, string digest, long total, int chunkBytes, SendFault fault, CancellationToken ct)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
        var chunks = new List<ChunkFrame>();
        uint sequence = 0;
        long offset = 0;
        var buffer = new byte[chunkBytes];
        async Task<ChunkFrame?> NextAsync()
        {
            var n = await stream.ReadAtLeastAsync(buffer, chunkBytes, throwOnEndOfStream: false, ct).ConfigureAwait(false);
            if (n == 0) return null;
            var frame = new ChunkFrame(id, sequence, (ulong)offset, buffer.AsSpan(0, n).ToArray());
            sequence++;
            offset += n;
            return frame;
        }

        if (fault == SendFault.OutOfOrder)
        {
            var c0 = await NextAsync().ConfigureAwait(false);
            var c1 = await NextAsync().ConfigureAwait(false);
            await channel.SendAsync(c1 ?? c0! with { Sequence = 1 }, ct).ConfigureAwait(false);
            return;
        }

        while (await NextAsync().ConfigureAwait(false) is { } chunk)
        {
            ct.ThrowIfCancellationRequested();
            var toSend = chunk;
            if (fault == SendFault.CorruptChunk && chunk.Sequence == 0)
            {
                var bytes = chunk.Payload.ToArray();
                bytes[0] ^= 0xFF;
                toSend = chunk with { Payload = bytes };
            }
            await channel.SendAsync(toSend, ct).ConfigureAwait(false);
            if (fault == SendFault.CancelMid)
            {
                await channel.SendAsync(new TransferCancel(id), ct).ConfigureAwait(false);
                return;
            }
        }
        if (offset != total) throw new BridgeException(BridgeErrorCode.WriteFailed, "file changed while sending");
        await channel.SendAsync(new TransferComplete(id, digest, total), ct).ConfigureAwait(false);
    }

    private async Task<TransferCommitted> ReadUntilCommittedAsync(Guid id, Action<long>? progress, CancellationToken ct)
    {
        while (true)
        {
            switch (await channel.ReceiveControlAsync(_limits.TransferIdleTimeout * 4, ct).ConfigureAwait(false))
            {
                case TransferProgress p when p.TransferID == id:
                    progress?.Invoke(p.AcknowledgedOffset);
                    break;
                case TransferCommitted c when c.TransferID == id:
                    return c;
                case TransferErrorMessage e when e.TransferID is null || e.TransferID == id:
                    throw new BridgeException(e.Code, "receiver error");
                case TransferReject r when r.TransferID == id:
                    throw new BridgeException(r.Reason, "receiver rejected");
                case TransferCancel c when c.TransferID == id:
                    throw new BridgeException(BridgeErrorCode.TransferCanceled, "receiver cancelled");
            }
        }
    }
}
