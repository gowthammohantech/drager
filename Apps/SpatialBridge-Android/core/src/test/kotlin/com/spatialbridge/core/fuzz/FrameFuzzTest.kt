package com.spatialbridge.core.fuzz

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.TransferLimits
import com.spatialbridge.core.net.Frame
import com.spatialbridge.core.net.FrameCodec
import com.spatialbridge.core.net.FrameDecoder
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream
import java.util.UUID
import kotlin.random.Random

/** Frame header, incremental decoder, blocking reader and chunk payload parser under random input. */
class FrameFuzzTest {
    private val limits = TransferLimits.DEFAULT
    private val maxControl = limits.maxControlFrameBytes
    private val maxChunk = Frame.Chunk.HEADER_BYTES + limits.maxChunkBytes

    /** Lengths at and around every limit, plus extremes of the UInt32 field. */
    private val interestingLengths: List<Long> = buildList {
        for (base in listOf(0L, Frame.Chunk.HEADER_BYTES.toLong(), maxControl.toLong(), maxChunk.toLong(), limits.maxChunkBytes.toLong())) {
            for (d in -2L..2L) if (base + d >= 0) add(base + d)
        }
        addAll(listOf(0x7FFF_FFFFL, 0x8000_0000L, 0xFFFF_FFFEL, 0xFFFF_FFFFL, 1L shl 24, 1L shl 20))
    }

    private fun header(type: Int, length: Long): ByteArray = byteArrayOf(
        type.toByte(), (length shr 24).toByte(), (length shr 16).toByte(), (length shr 8).toByte(), length.toByte(),
    )

    private fun randomLength(rng: Random): Long = when (rng.nextInt(3)) {
        0 -> Fuzz.pick(rng, interestingLengths)
        1 -> rng.nextLong(0, 0x1_0000_0000L)
        else -> rng.nextLong(0, maxChunk + 64L)
    }

    private fun randomType(rng: Random): Int = if (rng.nextInt(4) == 0) rng.nextInt(256) else 1 + rng.nextInt(2)

    private fun maxFor(type: Int): Long? = when (type) {
        FrameCodec.CONTROL_TYPE -> maxControl.toLong()
        FrameCodec.CHUNK_TYPE -> maxChunk.toLong()
        else -> null
    }

    private fun assertProtocolError(e: FrameCodec.CodecError) {
        assertEquals(BridgeErrorCode.PROTOCOL_MISMATCH, e.toBridge().code)
    }

    private fun randomFrame(rng: Random): Frame = if (rng.nextBoolean()) {
        Frame.Control(Fuzz.bytes(rng, 512))
    } else {
        Frame.Chunk(UUID(rng.nextLong(), rng.nextLong()), rng.nextLong(0, 0x1_0000_0000L), rng.nextLong(), Fuzz.bytes(rng, 2048))
    }

    private fun assertSameFrame(expected: Frame, actual: Frame) {
        assertArrayEquals(FrameCodec.encode(expected), FrameCodec.encode(actual))
    }

    @Test
    fun `header accepts exactly known types within their limits`() {
        Fuzz.run("frame-header") { rng, _ ->
            val type = randomType(rng)
            val length = randomLength(rng)
            val max = maxFor(type)
            try {
                val (t, l) = FrameCodec.parseHeader(header(type, length), limits)
                assertTrue(max != null && length <= max, "accepted type $type length $length")
                assertEquals(type, t)
                assertEquals(length, l.toLong())
                assertTrue(l >= 0)
            } catch (e: FrameCodec.CodecError) {
                assertTrue(max == null || length > max, "rejected valid type $type length $length: $e")
                assertProtocolError(e)
            }
        }
    }

    @Test
    fun `decoder never fails except with codec errors and never buffers an invalid frame`() {
        Fuzz.run("frame-decoder-random") { rng, _ ->
            val stream = ByteArrayOutputStream()
            // Mostly well-formed headers with random payloads, sometimes pure noise.
            repeat(1 + rng.nextInt(4)) {
                if (rng.nextInt(5) == 0) {
                    stream.write(Fuzz.bytes(rng, 64))
                } else {
                    val type = randomType(rng)
                    val length = if (rng.nextBoolean()) rng.nextLong(0, 300) else randomLength(rng)
                    stream.write(header(type, length))
                    stream.write(Fuzz.bytes(rng, minOf(length, 300L).toInt()))
                }
            }
            val input = stream.toByteArray()
            val decoder = FrameDecoder(limits)
            var fed = 0
            try {
                while (fed < input.size) {
                    val n = minOf(input.size - fed, 1 + rng.nextInt(97))
                    decoder.append(input.copyOfRange(fed, fed + n))
                    fed += n
                    while (true) {
                        val frame = decoder.next() ?: break
                        when (frame) {
                            is Frame.Control -> assertTrue(frame.payload.size <= maxControl)
                            is Frame.Chunk -> {
                                assertTrue(frame.payload.size <= limits.maxChunkBytes)
                                assertTrue(frame.sequence in 0..0xFFFF_FFFFL)
                            }
                        }
                    }
                    assertTrue(decoder.bufferedByteCount <= fed)
                }
            } catch (e: FrameCodec.CodecError) {
                assertProtocolError(e)
            }
        }
    }

    @Test
    fun `oversized and unknown headers fail before any payload arrives`() {
        Fuzz.run("frame-decoder-early-reject") { rng, _ ->
            val type = randomType(rng)
            val max = maxFor(type)
            val length = if (max == null) randomLength(rng) else rng.nextLong(max + 1, 0x1_0000_0000L)
            val decoder = FrameDecoder(limits)
            decoder.append(header(type, length))
            try {
                decoder.next()
                throw AssertionError("header type $type length $length was not rejected")
            } catch (e: FrameCodec.CodecError) {
                assertProtocolError(e)
            }
            assertEquals(FrameCodec.HEADER_BYTES, decoder.bufferedByteCount)
        }
    }

    @Test
    fun `truncated frames wait for more bytes and split frames round-trip`() {
        Fuzz.run("frame-decoder-truncation") { rng, _ ->
            val frames = List(1 + rng.nextInt(4)) { randomFrame(rng) }
            val wire = frames.fold(ByteArray(0)) { acc, f -> acc + FrameCodec.encode(f) }
            // Truncation: any strict prefix of a single frame yields nothing and no error.
            val first = FrameCodec.encode(frames[0])
            val cut = rng.nextInt(first.size)
            val partial = FrameDecoder(limits).apply { append(first.copyOf(cut)) }
            assertNull(partial.next())
            assertEquals(cut, partial.bufferedByteCount)
            // Arbitrary splits decode the same frames.
            val decoder = FrameDecoder(limits)
            val out = ArrayList<Frame>()
            var fed = 0
            while (fed < wire.size) {
                val n = minOf(wire.size - fed, 1 + rng.nextInt(700))
                decoder.append(wire.copyOfRange(fed, fed + n))
                fed += n
                while (true) out += decoder.next() ?: break
            }
            assertEquals(frames.size, out.size)
            frames.zip(out).forEach { (a, b) -> assertSameFrame(a, b) }
            assertEquals(0, decoder.bufferedByteCount)
        }
    }

    /** Records the largest buffer the reader asks to fill; that is the payload it allocated. */
    private class RecordingStream(private val data: ByteArray, private val maxRead: Int) : InputStream() {
        var position = 0
        var largestRequest = 0

        override fun read(): Int = if (position < data.size) data[position++].toInt() and 0xFF else -1

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            largestRequest = maxOf(largestRequest, b.size)
            if (position >= data.size) return -1
            val n = minOf(len, maxRead, data.size - position)
            System.arraycopy(data, position, b, off, n)
            position += n
            return n
        }
    }

    @Test
    fun `blocking reader allocates at most the frame limit and only after validation`() {
        Fuzz.run("frame-read-stream") { rng, _ ->
            val type = randomType(rng)
            val length = randomLength(rng)
            val max = maxFor(type)
            val body = Fuzz.bytes(rng, 256)
            val stream = RecordingStream(header(type, length) + body, 1 + rng.nextInt(64))
            try {
                val frame = FrameCodec.read(stream, limits)
                assertTrue(frame != null && max != null && length <= max && length <= body.size)
            } catch (e: FrameCodec.CodecError) {
                assertProtocolError(e)
                assertTrue(max == null || length > max || (type == FrameCodec.CHUNK_TYPE && length < Frame.Chunk.HEADER_BYTES))
                if (max == null || length > max) assertEquals(FrameCodec.HEADER_BYTES, stream.position, "read past a rejected header")
            } catch (e: EOFException) {
                // Truncated stream: the transport maps this to a lost peer.
                assertTrue(max != null && length <= max)
            }
            assertTrue(stream.largestRequest <= maxOf(FrameCodec.HEADER_BYTES.toLong(), max ?: 0L, 0L))
            if (max == null || length > max) assertEquals(FrameCodec.HEADER_BYTES, stream.largestRequest)
        }
    }

    @Test
    fun `chunk payload parser`() {
        Fuzz.run("chunk-payload") { rng, _ ->
            val payload = when (rng.nextInt(3)) {
                0 -> Fuzz.bytes(rng, 40)
                1 -> rng.nextBytes(Frame.Chunk.HEADER_BYTES - 2 + rng.nextInt(5))
                else -> rng.nextBytes(Frame.Chunk.HEADER_BYTES + rng.nextInt(4096))
            }
            try {
                val frame = FrameCodec.decodePayload(FrameCodec.CHUNK_TYPE, payload) as Frame.Chunk
                assertTrue(payload.size >= Frame.Chunk.HEADER_BYTES)
                assertTrue(frame.sequence in 0..0xFFFF_FFFFL)
                assertEquals(payload.size - Frame.Chunk.HEADER_BYTES, frame.payload.size)
                val encoded = FrameCodec.encode(frame)
                assertArrayEquals(payload, encoded.copyOfRange(FrameCodec.HEADER_BYTES, encoded.size))
            } catch (e: FrameCodec.CodecError.MalformedChunk) {
                assertTrue(payload.size < Frame.Chunk.HEADER_BYTES)
                assertProtocolError(e)
            }
            // Unknown types never decode.
            val type = rng.nextInt(256)
            if (type != FrameCodec.CONTROL_TYPE && type != FrameCodec.CHUNK_TYPE) {
                try {
                    FrameCodec.decodePayload(type, payload)
                    throw AssertionError("type $type decoded")
                } catch (e: FrameCodec.CodecError.UnknownType) {
                    assertProtocolError(e)
                }
            }
        }
    }
}
