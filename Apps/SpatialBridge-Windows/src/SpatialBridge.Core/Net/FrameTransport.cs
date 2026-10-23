using System.Net.Sockets;
using SpatialBridge.Core.Framing;

namespace SpatialBridge.Core.Net;

/// <summary>An ordered, bidirectional frame stream. One reader at a time; sends may be concurrent.</summary>
public interface IFrameTransport : IAsyncDisposable
{
    /// <summary>Next frame, or null when the peer closed cleanly. Throws <see cref="BridgeException"/> on violations or I/O failure.</summary>
    ValueTask<Frame?> ReceiveAsync(CancellationToken cancellationToken = default);

    ValueTask SendAsync(Frame frame, CancellationToken cancellationToken = default);

    /// <summary>Closes the connection. Idempotent; unblocks a pending receive.</summary>
    void Close();
}

/// <summary>Frames over a <see cref="Stream"/>: the header is parsed and bounded before the payload is read.</summary>
public sealed class StreamFrameTransport : IFrameTransport
{
    private readonly Stream _stream;
    private readonly IDisposable[] _owned;
    private readonly TransferLimits _limits;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly byte[] _header = new byte[FrameCodec.HeaderBytes];
    private int _closed;

    public StreamFrameTransport(Stream stream, TransferLimits? limits = null, params IDisposable[] owned)
    {
        _stream = stream;
        _limits = limits ?? TransferLimits.Default;
        _owned = owned;
    }

    public static StreamFrameTransport Over(TcpClient client, Stream? stream = null, TransferLimits? limits = null, params IDisposable[] extra) =>
        new(stream ?? client.GetStream(), limits, [.. extra, client]);

    public bool IsClosed => Volatile.Read(ref _closed) != 0;

    public async ValueTask<Frame?> ReceiveAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var got = await ReadFully(_header, cancellationToken).ConfigureAwait(false);
            if (got == 0) return null;
            if (got < _header.Length) throw new BridgeException(BridgeErrorCode.PeerLost, "truncated header");
            var (type, length) = FrameCodec.ParseHeader(_header, _limits)!.Value;
            var payload = new byte[length];
            if (await ReadFully(payload, cancellationToken).ConfigureAwait(false) < length)
            {
                throw new BridgeException(BridgeErrorCode.PeerLost, "truncated payload");
            }
            return FrameCodec.DecodePayload(type, payload);
        }
        catch (FrameCodecException ex)
        {
            throw ex.ToBridge();
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or SocketException or InvalidOperationException)
        {
            throw new BridgeException(BridgeErrorCode.PeerLost, "read failed", ex);
        }
    }

    private async ValueTask<int> ReadFully(Memory<byte> buffer, CancellationToken cancellationToken)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var n = await _stream.ReadAsync(buffer[total..], cancellationToken).ConfigureAwait(false);
            if (n <= 0) break;
            total += n;
        }
        return total;
    }

    public async ValueTask SendAsync(Frame frame, CancellationToken cancellationToken = default)
    {
        byte[] bytes;
        try
        {
            bytes = FrameCodec.Encode(frame, _limits);
        }
        catch (FrameCodecException ex)
        {
            throw ex.ToBridge();
        }
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (IsClosed) throw new BridgeException(BridgeErrorCode.PeerLost, "transport closed");
            await _stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
            await _stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or SocketException or InvalidOperationException)
        {
            throw new BridgeException(BridgeErrorCode.PeerLost, "write failed", ex);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public void Close()
    {
        if (Interlocked.Exchange(ref _closed, 1) != 0) return;
        try { _stream.Dispose(); } catch (Exception) { }
        foreach (var d in _owned)
        {
            try { d.Dispose(); } catch (Exception) { }
        }
    }

    public ValueTask DisposeAsync()
    {
        Close();
        return ValueTask.CompletedTask;
    }
}
