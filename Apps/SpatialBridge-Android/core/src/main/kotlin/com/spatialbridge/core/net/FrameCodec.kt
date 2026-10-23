package com.spatialbridge.core.net

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.TransferLimits
import java.io.EOFException
import java.io.InputStream
import java.nio.ByteBuffer
import java.util.UUID

/** Decoded frame (PROTOCOL.md "Framing"). */
sealed interface Frame {
    class Control(val payload: ByteArray) : Frame

    class Chunk(val transferID: UUID, val sequence: Long, val offset: Long, val payload: ByteArray) : Frame {
        companion object {
            const val HEADER_BYTES = 28
        }
    }
}

/**
 * `type(1) | length UInt32BE | payload`. The length is checked against the type's maximum before
 * any payload is buffered; violations are E012 and the caller must close the connection.
 */
object FrameCodec {
    const val HEADER_BYTES = 5
    const val CONTROL_TYPE = 0x01
    const val CHUNK_TYPE = 0x02

    sealed class CodecError(message: String) : Exception(message) {
        class OversizedControl(val size: Int) : CodecError("oversizedControl($size)")
        class OversizedChunk(val size: Int) : CodecError("oversizedChunk($size)")
        class UnknownType(val type: Int) : CodecError("unknownType($type)")
        class MalformedChunk : CodecError("malformedChunk")
        class LengthExceedsLimit(val length: Long) : CodecError("lengthExceedsLimit($length)")

        fun toBridge() = BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, message, this)
    }

    fun encode(frame: Frame, limits: TransferLimits = TransferLimits.DEFAULT): ByteArray = when (frame) {
        is Frame.Control -> {
            if (frame.payload.size > limits.maxControlFrameBytes) throw CodecError.OversizedControl(frame.payload.size)
            ByteBuffer.allocate(HEADER_BYTES + frame.payload.size)
                .put(CONTROL_TYPE.toByte()).putInt(frame.payload.size).put(frame.payload).array()
        }
        is Frame.Chunk -> {
            if (frame.payload.size > limits.maxChunkBytes) throw CodecError.OversizedChunk(frame.payload.size)
            val length = Frame.Chunk.HEADER_BYTES + frame.payload.size
            ByteBuffer.allocate(HEADER_BYTES + length)
                .put(CHUNK_TYPE.toByte()).putInt(length)
                .putLong(frame.transferID.mostSignificantBits).putLong(frame.transferID.leastSignificantBits)
                .putInt(frame.sequence.toInt()).putLong(frame.offset)
                .put(frame.payload).array()
        }
    }

    fun maximumPayloadLength(type: Int, limits: TransferLimits): Int? = when (type) {
        CONTROL_TYPE -> limits.maxControlFrameBytes
        CHUNK_TYPE -> Frame.Chunk.HEADER_BYTES + limits.maxChunkBytes
        else -> null
    }

    /** Validates a 5-byte header and returns `(type, length)`. */
    fun parseHeader(header: ByteArray, limits: TransferLimits): Pair<Int, Int> {
        require(header.size >= HEADER_BYTES)
        val type = header[0].toInt() and 0xFF
        val length = ByteBuffer.wrap(header, 1, 4).int.toLong() and 0xFFFF_FFFFL
        val max = maximumPayloadLength(type, limits) ?: throw CodecError.UnknownType(type)
        if (length > max) throw CodecError.LengthExceedsLimit(length)
        return type to length.toInt()
    }

    fun decodePayload(type: Int, payload: ByteArray): Frame = when (type) {
        CONTROL_TYPE -> Frame.Control(payload)
        CHUNK_TYPE -> {
            if (payload.size < Frame.Chunk.HEADER_BYTES) throw CodecError.MalformedChunk()
            val buffer = ByteBuffer.wrap(payload)
            val id = UUID(buffer.long, buffer.long)
            val sequence = buffer.int.toLong() and 0xFFFF_FFFFL
            val offset = buffer.long
            Frame.Chunk(id, sequence, offset, payload.copyOfRange(Frame.Chunk.HEADER_BYTES, payload.size))
        }
        else -> throw CodecError.UnknownType(type)
    }

    /** Reads one frame from a blocking stream; returns null on a clean EOF at a frame boundary. */
    fun read(input: InputStream, limits: TransferLimits): Frame? {
        val header = ByteArray(HEADER_BYTES)
        val first = input.read(header, 0, HEADER_BYTES)
        if (first < 0) return null
        readFully(input, header, first)
        val (type, length) = parseHeader(header, limits)
        val payload = ByteArray(length)
        readFully(input, payload, 0)
        return decodePayload(type, payload)
    }

    private fun readFully(input: InputStream, buffer: ByteArray, start: Int) {
        var read = start
        while (read < buffer.size) {
            val n = input.read(buffer, read, buffer.size - read)
            if (n < 0) throw EOFException("truncated frame")
            read += n
        }
    }
}

/** Incremental decoder for a byte stream, like Swift's `FrameDecoder`. */
class FrameDecoder(private val limits: TransferLimits = TransferLimits.DEFAULT) {
    private var buffer = ByteArray(0)

    val bufferedByteCount: Int get() = buffer.size

    fun append(data: ByteArray) {
        buffer += data
    }

    /** The next complete frame, or null if more bytes are needed. Throws [FrameCodec.CodecError]. */
    fun next(): Frame? {
        if (buffer.size < FrameCodec.HEADER_BYTES) return null
        val (type, length) = FrameCodec.parseHeader(buffer.copyOf(FrameCodec.HEADER_BYTES), limits)
        val total = FrameCodec.HEADER_BYTES + length
        if (buffer.size < total) return null
        val payload = buffer.copyOfRange(FrameCodec.HEADER_BYTES, total)
        buffer = buffer.copyOfRange(total, buffer.size)
        return FrameCodec.decodePayload(type, payload)
    }
}
