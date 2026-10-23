using System.Threading.Channels;
using SpatialBridge.Core.Framing;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Net;

namespace SpatialBridge.Core.Session;

/// <summary>A decoded control message plus the exact payload bytes it arrived in (ADR-014).</summary>
public sealed record ReceivedControlFrame(ControlMessage Message, byte[] Payload);

public sealed record SessionChannelOptions
{
    /// <summary>Null disables keepalive (pairing).</summary>
    public TimeSpan? KeepaliveInterval { get; init; } = TimeSpan.FromSeconds(5);
    public TimeSpan DeadPeerTimeout { get; init; } = TimeSpan.FromSeconds(20);
    public int InboxCapacity { get; init; } = 8;
    public TimeProvider Time { get; init; } = TimeProvider.System;

    public static SessionChannelOptions Session { get; } = new();
    public static SessionChannelOptions Handshake { get; } = new() { KeepaliveInterval = null, DeadPeerTimeout = TimeSpan.FromSeconds(180) };
}

/// <summary>
/// Message view of a transport shared by pairing, session auth and transfer. One read loop answers PING,
/// records RTT from PONG and pushes everything else into a bounded inbox; a slow consumer stalls the
/// read loop and lets TCP flow control push back (ADR-007).
/// </summary>
public sealed class SessionChannel : IAsyncDisposable
{
    private readonly IFrameTransport _transport;
    private readonly SessionChannelOptions _options;
    private readonly Channel<Frame> _inbox;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Lock _gate = new();
    private Task? _readTask;
    private Task? _keepaliveTask;
    private long _lastHeardTicks;
    private uint _pingSequence;
    private int _closed;

    public SessionChannel(IFrameTransport transport, SessionChannelOptions? options = null)
    {
        _transport = transport;
        _options = options ?? SessionChannelOptions.Session;
        _inbox = Channel.CreateBounded<Frame>(new BoundedChannelOptions(_options.InboxCapacity)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = false,
            SingleWriter = true,
        });
    }

    public bool IsClosed => Volatile.Read(ref _closed) != 0;

    public BridgeErrorCode? CloseReason { get; private set; }

    public double? SmoothedRoundTripSeconds { get; private set; }

    public event EventHandler<BridgeErrorCode?>? Closed;

    public void Start()
    {
        lock (_gate)
        {
            if (_readTask is not null || IsClosed) return;
            Touch();
            _readTask = Task.Run(ReadLoop);
            if (_options.KeepaliveInterval is { } interval) _keepaliveTask = Task.Run(() => KeepaliveLoop(interval));
        }
    }

    /// <summary>Next non-keepalive frame. Throws the close reason once closed and drained.</summary>
    public async Task<Frame> ReceiveAsync(CancellationToken cancellationToken = default)
    {
        Start();
        try
        {
            if (await _inbox.Reader.WaitToReadAsync(cancellationToken).ConfigureAwait(false) && _inbox.Reader.TryRead(out var frame))
            {
                return frame;
            }
        }
        catch (ChannelClosedException)
        {
        }
        if (_inbox.Reader.TryRead(out var late)) return late;
        throw new BridgeException(CloseReason ?? BridgeErrorCode.PeerLost, "channel closed");
    }

    public async Task<Frame> ReceiveAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(timeout);
        try
        {
            return await ReceiveAsync(cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new BridgeException(BridgeErrorCode.Timeout, "receive timed out");
        }
    }

    public async Task<ReceivedControlFrame> ReceiveControlFrameAsync(TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        var frame = timeout is { } t ? await ReceiveAsync(t, cancellationToken).ConfigureAwait(false) : await ReceiveAsync(cancellationToken).ConfigureAwait(false);
        if (frame is not ControlFrame control) throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "unexpected chunk");
        return new ReceivedControlFrame(ControlMessageCoder.Decode(control.Payload), control.Payload);
    }

    public async Task<ControlMessage> ReceiveControlAsync(TimeSpan? timeout = null, CancellationToken cancellationToken = default) =>
        (await ReceiveControlFrameAsync(timeout, cancellationToken).ConfigureAwait(false)).Message;

    /// <summary>Encodes and sends; returns the exact payload bytes sent.</summary>
    public async Task<byte[]> SendAsync(ControlMessage message, CancellationToken cancellationToken = default)
    {
        var payload = ControlMessageCoder.Encode(message);
        await SendAsync(new ControlFrame(payload), cancellationToken).ConfigureAwait(false);
        return payload;
    }

    public async Task SendAsync(Frame frame, CancellationToken cancellationToken = default)
    {
        if (IsClosed) throw new BridgeException(CloseReason ?? BridgeErrorCode.PeerLost, "channel closed");
        try
        {
            await _transport.SendAsync(frame, cancellationToken).ConfigureAwait(false);
        }
        catch (BridgeException ex)
        {
            Close(ex.Code);
            throw;
        }
    }

    /// <summary>Best-effort send that never throws.</summary>
    public async Task TrySendAsync(ControlMessage message)
    {
        try
        {
            await SendAsync(message).ConfigureAwait(false);
        }
        catch (BridgeException)
        {
        }
    }

    /// <summary>Drops frames buffered from an earlier exchange.</summary>
    public void DrainInbox()
    {
        while (_inbox.Reader.TryRead(out _)) { }
    }

    /// <summary>Closes the channel and the transport. Idempotent.</summary>
    public void Close(BridgeErrorCode? reason = null)
    {
        if (Interlocked.Exchange(ref _closed, 1) != 0) return;
        CloseReason = reason;
        _lifetime.Cancel();
        _inbox.Writer.TryComplete();
        _transport.Close();
        Closed?.Invoke(this, reason);
    }

    public async ValueTask DisposeAsync()
    {
        Close();
        var tasks = new[] { _readTask, _keepaliveTask }.Where(t => t is not null).Cast<Task>().ToArray();
        try
        {
            await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        }
        catch (Exception)
        {
        }
        await _transport.DisposeAsync().ConfigureAwait(false);
        _lifetime.Dispose();
    }

    private void Touch() => Interlocked.Exchange(ref _lastHeardTicks, _options.Time.GetTimestamp());

    private async Task ReadLoop()
    {
        var token = _lifetime.Token;
        try
        {
            while (!token.IsCancellationRequested)
            {
                var frame = await _transport.ReceiveAsync(token).ConfigureAwait(false);
                if (frame is null)
                {
                    Close(BridgeErrorCode.PeerLost);
                    return;
                }
                Touch();
                if (frame is ControlFrame control && ControlMessageCoder.TryDecode(control.Payload, out var message))
                {
                    switch (message)
                    {
                        case Ping ping:
                            await _transport.SendAsync(new ControlFrame(ControlMessageCoder.Encode(new Pong(ping.Sequence, ping.SentAtMillis))), token).ConfigureAwait(false);
                            continue;
                        case Pong pong:
                            RecordRoundTrip(pong.SentAtMillis);
                            continue;
                    }
                }
                await _inbox.Writer.WriteAsync(frame, token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (ChannelClosedException)
        {
        }
        catch (BridgeException ex)
        {
            Close(ex.Code);
        }
    }

    private async Task KeepaliveLoop(TimeSpan interval)
    {
        var token = _lifetime.Token;
        try
        {
            while (!token.IsCancellationRequested)
            {
                await Task.Delay(interval, _options.Time, token).ConfigureAwait(false);
                if (_options.Time.GetElapsedTime(Interlocked.Read(ref _lastHeardTicks)) > _options.DeadPeerTimeout)
                {
                    Close(BridgeErrorCode.PeerLost);
                    return;
                }
                _pingSequence = unchecked(_pingSequence + 1);
                await _transport.SendAsync(new ControlFrame(ControlMessageCoder.Encode(new Ping(_pingSequence, Clock.NowMillis(_options.Time)))), token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (BridgeException ex)
        {
            Close(ex.Code);
        }
    }

    private void RecordRoundTrip(long sentAtMillis)
    {
        var sample = (Clock.NowMillis(_options.Time) - sentAtMillis) / 1000.0;
        if (sample is < 0 or >= 30) return;
        SmoothedRoundTripSeconds = SmoothedRoundTripSeconds is { } s ? (s * 0.8) + (sample * 0.2) : sample;
    }
}
