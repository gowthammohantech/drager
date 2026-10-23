using System.Buffers.Binary;
using SpatialBridge.Core.Framing;
using Xunit.Abstractions;

namespace SpatialBridge.Core.Tests.Fuzz;

/// <summary>Frame header, incremental decoder and chunk payload parser under random input.</summary>
public sealed class FrameFuzzTests(ITestOutputHelper output)
{
    private static readonly TransferLimits Limits = TransferLimits.Default;
    private static readonly long MaxControl = Limits.MaxControlFrameBytes;
    private static readonly long MaxChunk = ChunkFrame.HeaderBytes + Limits.MaxChunkBytes;

    /// <summary>Lengths at and around every limit, plus the extremes of the UInt32 field.</summary>
    private static readonly long[] InterestingLengths =
    [
        .. new long[] { 0, ChunkFrame.HeaderBytes, MaxControl, MaxChunk, Limits.MaxChunkBytes }
            .SelectMany(b => Enumerable.Range(-2, 5).Select(d => b + d))
            .Where(v => v >= 0),
        0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF, 1 << 24, 1 << 20,
    ];

    private static byte[] Header(int type, long length)
    {
        var h = new byte[FrameCodec.HeaderBytes];
        h[0] = (byte)type;
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(1), (uint)length);
        return h;
    }

    private static long RandomLength(Random rng) => rng.Next(3) switch
    {
        0 => FuzzRunner.Pick(rng, InterestingLengths),
        1 => rng.NextInt64(0, 0x1_0000_0000L),
        _ => rng.NextInt64(0, MaxChunk + 64),
    };

    private static int RandomType(Random rng) => rng.Next(4) == 0 ? rng.Next(256) : 1 + rng.Next(2);

    private static long? MaxFor(int type) => type switch
    {
        FrameCodec.ControlType => MaxControl,
        FrameCodec.ChunkType => MaxChunk,
        _ => null,
    };

    private static void AssertProtocolError(FrameCodecException e) =>
        Assert.Equal(BridgeErrorCode.ProtocolMismatch, e.ToBridge().Code);

    private static Frame RandomFrame(Random rng) => rng.Next(2) == 0
        ? new ControlFrame(FuzzRunner.Bytes(rng, 512))
        : new ChunkFrame(new Guid(RandomBytes(rng, 16)), (uint)rng.NextInt64(0, 0x1_0000_0000L), (ulong)rng.NextInt64(long.MinValue, long.MaxValue), FuzzRunner.Bytes(rng, 2048));

    private static byte[] RandomBytes(Random rng, int n)
    {
        var b = new byte[n];
        rng.NextBytes(b);
        return b;
    }

    [Fact]
    public void HeaderAcceptsExactlyKnownTypesWithinTheirLimits() => FuzzRunner.Run("frame-header", (rng, _) =>
    {
        var type = RandomType(rng);
        var length = RandomLength(rng);
        var max = MaxFor(type);
        try
        {
            var parsed = FrameCodec.ParseHeader(Header(type, length), Limits);
            Assert.NotNull(parsed);
            Assert.True(max is { } m && length <= m, $"accepted type {type} length {length}");
            Assert.Equal(type, parsed.Value.Type);
            Assert.Equal(length, parsed.Value.Length);
        }
        catch (FrameCodecException e)
        {
            Assert.True(max is null || length > max, $"rejected valid type {type} length {length}");
            AssertProtocolError(e);
        }
        // Fewer than five bytes is "need more", never an error.
        Assert.Null(FrameCodec.ParseHeader(Header(type, length).AsSpan(0, rng.Next(FrameCodec.HeaderBytes)), Limits));
    }, log: output.WriteLine);

    [Fact]
    public void DecoderFailsOnlyWithCodecErrors() => FuzzRunner.Run("frame-decoder-random", (rng, _) =>
    {
        using var stream = new MemoryStream();
        var parts = 1 + rng.Next(4);
        for (var p = 0; p < parts; p++)
        {
            if (rng.Next(5) == 0)
            {
                stream.Write(FuzzRunner.Bytes(rng, 64));
                continue;
            }
            var type = RandomType(rng);
            var length = rng.Next(2) == 0 ? rng.NextInt64(0, 300) : RandomLength(rng);
            stream.Write(Header(type, length));
            stream.Write(RandomBytes(rng, (int)Math.Min(length, 300)));
        }
        var input = stream.ToArray();
        var decoder = new FrameDecoder(Limits);
        var fed = 0;
        try
        {
            while (fed < input.Length)
            {
                var n = Math.Min(input.Length - fed, 1 + rng.Next(97));
                decoder.Append(input.AsSpan(fed, n));
                fed += n;
                while (decoder.Next() is { } frame)
                {
                    switch (frame)
                    {
                        case ControlFrame c: Assert.True(c.Payload.Length <= MaxControl); break;
                        case ChunkFrame k: Assert.True(k.Payload.Length <= Limits.MaxChunkBytes); break;
                        default: Assert.Fail("unknown frame"); break;
                    }
                }
                Assert.True(decoder.BufferedByteCount <= fed);
            }
        }
        catch (FrameCodecException e)
        {
            AssertProtocolError(e);
        }
    }, log: output.WriteLine);

    [Fact]
    public void OversizedAndUnknownHeadersFailBeforeAnyPayloadArrives() => FuzzRunner.Run("frame-decoder-early-reject", (rng, _) =>
    {
        var type = RandomType(rng);
        var max = MaxFor(type);
        var length = max is { } m ? rng.NextInt64(m + 1, 0x1_0000_0000L) : RandomLength(rng);
        var decoder = new FrameDecoder(Limits);
        decoder.Append(Header(type, length));
        var e = Assert.Throws<FrameCodecException>(() => decoder.Next());
        AssertProtocolError(e);
        Assert.Equal(FrameCodec.HeaderBytes, decoder.BufferedByteCount);
    }, log: output.WriteLine);

    [Fact]
    public void TruncatedFramesWaitAndSplitFramesRoundTrip() => FuzzRunner.Run("frame-decoder-truncation", (rng, _) =>
    {
        var frames = Enumerable.Range(0, 1 + rng.Next(4)).Select(_ => RandomFrame(rng)).ToList();
        var wire = frames.SelectMany(f => FrameCodec.Encode(f)).ToArray();
        var first = FrameCodec.Encode(frames[0]);
        var cut = rng.Next(first.Length);
        var partial = new FrameDecoder(Limits);
        partial.Append(first.AsSpan(0, cut));
        Assert.Null(partial.Next());
        Assert.Equal(cut, partial.BufferedByteCount);

        var decoder = new FrameDecoder(Limits);
        var decoded = new List<Frame>();
        var fed = 0;
        while (fed < wire.Length)
        {
            var n = Math.Min(wire.Length - fed, 1 + rng.Next(700));
            decoder.Append(wire.AsSpan(fed, n));
            fed += n;
            while (decoder.Next() is { } f) decoded.Add(f);
        }
        Assert.Equal(frames.Count, decoded.Count);
        for (var i = 0; i < frames.Count; i++) Assert.Equal(FrameCodec.Encode(frames[i]), FrameCodec.Encode(decoded[i]));
        Assert.Equal(0, decoder.BufferedByteCount);
    }, log: output.WriteLine);

    /// <summary>Records the largest read the transport asks for; that is the payload buffer it allocated.</summary>
    private sealed class RecordingStream(byte[] data, int maxRead) : Stream
    {
        public int LargestRequest { get; private set; }

        public override long Position { get; set; }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => data.Length;

        public override int Read(Span<byte> buffer)
        {
            LargestRequest = Math.Max(LargestRequest, buffer.Length);
            var n = (int)Math.Min(Math.Min(buffer.Length, maxRead), data.Length - Position);
            data.AsSpan((int)Position, n).CopyTo(buffer);
            Position += n;
            return n;
        }

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(Read(buffer.Span));

        public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));

        public override void Flush() { }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    [Fact]
    public void StreamTransportAllocatesAtMostTheFrameLimitAndOnlyAfterValidation() => FuzzRunner.Run("frame-read-stream", (rng, _) =>
    {
        var type = RandomType(rng);
        var length = RandomLength(rng);
        var max = MaxFor(type);
        var body = FuzzRunner.Bytes(rng, 256);
        using var stream = new RecordingStream([.. Header(type, length), .. body], 1 + rng.Next(64));
        var transport = new Net.StreamFrameTransport(stream, Limits);
        try
        {
            var frame = transport.ReceiveAsync().AsTask().GetAwaiter().GetResult();
            Assert.True(frame is not null && max is { } m && length <= m && length <= body.Length);
        }
        catch (BridgeException e)
        {
            var oversize = max is null || length > max;
            if (e.Code == BridgeErrorCode.PeerLost)
            {
                Assert.False(oversize, "oversized header reported as a lost peer");
            }
            else
            {
                Assert.Equal(BridgeErrorCode.ProtocolMismatch, e.Code);
                Assert.True(oversize || (type == FrameCodec.ChunkType && length < ChunkFrame.HeaderBytes));
            }
            if (oversize) Assert.Equal(FrameCodec.HeaderBytes, stream.Position);
        }
        Assert.True(stream.LargestRequest <= Math.Max(FrameCodec.HeaderBytes, max ?? 0));
        if (max is null || length > max) Assert.Equal(FrameCodec.HeaderBytes, stream.LargestRequest);
    }, log: output.WriteLine);

    [Fact]
    public void ChunkPayloadParser() => FuzzRunner.Run("chunk-payload", (rng, _) =>
    {
        var payload = rng.Next(3) switch
        {
            0 => FuzzRunner.Bytes(rng, 40),
            1 => RandomBytes(rng, ChunkFrame.HeaderBytes - 2 + rng.Next(5)),
            _ => RandomBytes(rng, ChunkFrame.HeaderBytes + rng.Next(4096)),
        };
        try
        {
            var chunk = Assert.IsType<ChunkFrame>(FrameCodec.DecodePayload(FrameCodec.ChunkType, payload));
            Assert.True(payload.Length >= ChunkFrame.HeaderBytes);
            Assert.Equal(payload.Length - ChunkFrame.HeaderBytes, chunk.Payload.Length);
            Assert.Equal(payload, FrameCodec.Encode(chunk)[FrameCodec.HeaderBytes..]);
        }
        catch (FrameCodecException e)
        {
            Assert.Equal(FrameError.MalformedChunk, e.Error);
            Assert.True(payload.Length < ChunkFrame.HeaderBytes);
            AssertProtocolError(e);
        }
        var type = (byte)rng.Next(256);
        if (type is not FrameCodec.ControlType and not FrameCodec.ChunkType)
        {
            var e = Assert.Throws<FrameCodecException>(() => FrameCodec.DecodePayload(type, payload));
            Assert.Equal(FrameError.UnknownType, e.Error);
        }
    }, log: output.WriteLine);
}
