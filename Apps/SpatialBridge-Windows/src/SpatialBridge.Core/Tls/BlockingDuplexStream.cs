namespace SpatialBridge.Core.Tls;

/// <summary>
/// Adapts a blocking stream (BouncyCastle's TLS stream) for async use without the base <see cref="Stream"/>
/// semaphore that would serialize a pending read with writes. Reads and writes each run on their own thread.
/// </summary>
internal sealed class BlockingDuplexStream(Stream inner, Action close) : Stream
{
    private readonly Lock _writeLock = new();
    private int _disposed;

    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

    public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);

    public override int Read(Span<byte> buffer) => inner.Read(buffer);

    public override void Write(byte[] buffer, int offset, int count)
    {
        lock (_writeLock) { inner.Write(buffer, offset, count); }
    }

    public override void Write(ReadOnlySpan<byte> buffer)
    {
        lock (_writeLock) { inner.Write(buffer); }
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
        new(Task.Factory.StartNew(() => inner.Read(buffer.Span), cancellationToken, TaskCreationOptions.DenyChildAttach, TaskScheduler.Default));

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default) =>
        new(Task.Factory.StartNew(() => Write(buffer.Span), cancellationToken, TaskCreationOptions.DenyChildAttach, TaskScheduler.Default));

    public override void Flush()
    {
        lock (_writeLock) { inner.Flush(); }
    }

    public override Task FlushAsync(CancellationToken cancellationToken) => Task.Run(Flush, cancellationToken);

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing && Interlocked.Exchange(ref _disposed, 1) == 0)
        {
            close();
        }
        base.Dispose(disposing);
    }
}
