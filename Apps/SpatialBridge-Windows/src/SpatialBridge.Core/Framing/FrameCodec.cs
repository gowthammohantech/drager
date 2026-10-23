using System.Buffers.Binary;

namespace SpatialBridge.Core.Framing;

public abstract record Frame;

public sealed record ControlFrame(byte[] Payload) : Frame;

/// <summary>A slice of a file in flight.</summary>
public sealed record ChunkFrame(Guid TransferID, uint Sequence, ulong Offset, ReadOnlyMemory<byte> Payload) : Frame
{
    /// <summary>16 (uuid) + 4 (sequence) + 8 (offset).</summary>
    public const int HeaderBytes = 28;
}

public enum FrameError
{
    OversizedControl,
    OversizedChunk,
    UnknownType,
    MalformedChunk,
    LengthExceedsLimit,
}

/// <summary>A framing violation. The connection must be closed (E012).</summary>
public sealed class FrameCodecException(FrameError error, string detail) : Exception(detail)
{
    public FrameError Error { get; } = error;

    public BridgeException ToBridge() => new(BridgeErrorCode.ProtocolMismatch, $"framing: {Error}", this);
}

/// <summary><c>type(1) | length UInt32BE | payload</c>; header checked before the payload is buffered.</summary>
public static class FrameCodec
{
    public const int HeaderBytes = 5;
    public const byte ControlType = 0x01;
    public const byte ChunkType = 0x02;

    public static byte[] Encode(Frame frame, TransferLimits? limits = null)
    {
        limits ??= TransferLimits.Default;
        switch (frame)
        {
            case ControlFrame c:
            {
                if (c.Payload.Length > limits.MaxControlFrameBytes) throw new FrameCodecException(FrameError.OversizedControl, $"control {c.Payload.Length}");
                var output = new byte[HeaderBytes + c.Payload.Length];
                output[0] = ControlType;
                BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(1), (uint)c.Payload.Length);
                c.Payload.CopyTo(output, HeaderBytes);
                return output;
            }
            case ChunkFrame k:
            {
                if (k.Payload.Length > limits.MaxChunkBytes) throw new FrameCodecException(FrameError.OversizedChunk, $"chunk {k.Payload.Length}");
                var length = ChunkFrame.HeaderBytes + k.Payload.Length;
                var output = new byte[HeaderBytes + length];
                output[0] = ChunkType;
                var span = output.AsSpan();
                BinaryPrimitives.WriteUInt32BigEndian(span[1..], (uint)length);
                Uuids.Write(k.TransferID, span.Slice(HeaderBytes, 16));
                BinaryPrimitives.WriteUInt32BigEndian(span[(HeaderBytes + 16)..], k.Sequence);
                BinaryPrimitives.WriteUInt64BigEndian(span[(HeaderBytes + 20)..], k.Offset);
                k.Payload.Span.CopyTo(span[(HeaderBytes + ChunkFrame.HeaderBytes)..]);
                return output;
            }
            default:
                throw new ArgumentException("unknown frame", nameof(frame));
        }
    }

    public static int? MaximumPayloadLength(byte type, TransferLimits limits) => type switch
    {
        ControlType => limits.MaxControlFrameBytes,
        ChunkType => ChunkFrame.HeaderBytes + limits.MaxChunkBytes,
        _ => null,
    };

    /// <summary>Parses and validates a 5-byte header. Returns null when fewer than 5 bytes are available.</summary>
    public static (byte Type, int Length)? ParseHeader(ReadOnlySpan<byte> data, TransferLimits limits)
    {
        if (data.Length < HeaderBytes) return null;
        var type = data[0];
        var length = BinaryPrimitives.ReadUInt32BigEndian(data[1..]);
        var max = MaximumPayloadLength(type, limits) ?? throw new FrameCodecException(FrameError.UnknownType, $"type {type}");
        if (length > (uint)max) throw new FrameCodecException(FrameError.LengthExceedsLimit, $"length {length}");
        return (type, (int)length);
    }

    public static Frame DecodePayload(byte type, byte[] payload)
    {
        switch (type)
        {
            case ControlType:
                return new ControlFrame(payload);
            case ChunkType:
                if (payload.Length < ChunkFrame.HeaderBytes) throw new FrameCodecException(FrameError.MalformedChunk, "short chunk");
                var span = payload.AsSpan();
                return new ChunkFrame(
                    Uuids.Read(span),
                    BinaryPrimitives.ReadUInt32BigEndian(span[16..]),
                    BinaryPrimitives.ReadUInt64BigEndian(span[20..]),
                    payload.AsMemory(ChunkFrame.HeaderBytes));
            default:
                throw new FrameCodecException(FrameError.UnknownType, $"type {type}");
        }
    }
}

/// <summary>Incremental decoder for a byte stream (tests, fuzzing).</summary>
public sealed class FrameDecoder(TransferLimits? limits = null)
{
    private readonly TransferLimits _limits = limits ?? TransferLimits.Default;
    private readonly List<byte> _buffer = [];

    public int BufferedByteCount => _buffer.Count;

    public void Append(ReadOnlySpan<byte> data)
    {
        foreach (var b in data) _buffer.Add(b);
    }

    public Frame? Next()
    {
        var span = System.Runtime.InteropServices.CollectionsMarshal.AsSpan(_buffer);
        if (FrameCodec.ParseHeader(span, _limits) is not { } header) return null;
        var total = FrameCodec.HeaderBytes + header.Length;
        if (_buffer.Count < total) return null;
        var payload = span.Slice(FrameCodec.HeaderBytes, header.Length).ToArray();
        _buffer.RemoveRange(0, total);
        return FrameCodec.DecodePayload(header.Type, payload);
    }
}
