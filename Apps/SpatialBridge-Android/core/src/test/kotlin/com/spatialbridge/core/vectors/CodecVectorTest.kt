package com.spatialbridge.core.vectors

import com.spatialbridge.core.json.CanonicalJson
import com.spatialbridge.core.model.ControlMessage
import com.spatialbridge.core.model.ControlMessageCoder
import com.spatialbridge.core.model.DeviceInfo
import com.spatialbridge.core.model.Hello
import com.spatialbridge.core.net.Frame
import com.spatialbridge.core.net.FrameCodec
import com.spatialbridge.core.net.FrameDecoder
import com.spatialbridge.core.util.hexToBytes
import com.spatialbridge.core.util.sha256
import com.spatialbridge.core.util.toHex
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.TestFactory
import org.junit.jupiter.api.assertThrows
import java.math.BigInteger
import java.nio.ByteBuffer
import java.util.UUID

class CodecVectorTest {
    @TestFactory
    fun `canonical-json`() = Vectors.tests("canonical-json") { case ->
        val expected = case.str("json")
        when (case.str("type")) {
            "string" -> {
                val input = buildString { case.getValue("input").jsonArray.forEach { appendCodePoint(it.jsonPrimitive.int) } }
                assertEquals(case.str("inputUtf8"), input.toByteArray().toHex())
                assertEquals(expected, CanonicalJson.encodeToString(input))
                val message = ControlMessage.Error(null, com.spatialbridge.core.BridgeErrorCode.PROTOCOL_MISMATCH, input)
                val decoded = ControlMessageCoder.decode(ControlMessageCoder.encode(message)) as ControlMessage.Error
                assertEquals(input, decoded.message)
            }
            "base64" -> assertEquals(expected, CanonicalJson.encodeToString(case.str("inputHex").hexToBytes()))
            "date-ms" -> {
                val millis = case.str("milliseconds").toLong()
                assertEquals(expected, CanonicalJson.encodeToString(millis))
                val ping = ControlMessageCoder.decode("""{"body":{"sentAt":$expected,"sequence":1},"kind":"PING"}""".toByteArray())
                assertEquals(millis, (ping as ControlMessage.Ping).sentAtMillis)
            }
            "uuid" -> {
                val id = ControlMessageCoder.parseUuid(case.str("input"))
                assertEquals(expected, CanonicalJson.encodeToString(ControlMessageCoder.uuidString(id)))
                val bytes = ByteBuffer.allocate(16).putLong(id.mostSignificantBits).putLong(id.leastSignificantBits).array()
                assertEquals(case.str("bytesHex"), bytes.toHex())
            }
            else -> error("unknown type ${case.str("type")}")
        }
    }

    @TestFactory
    fun `control-messages`() = Vectors.tests("control-messages") { case ->
        val json = case.str("json")
        val input = case.strOrNull("inputJson") ?: json
        val decoded = ControlMessageCoder.decode(input.toByteArray())
        assertEquals(case.str("kind"), decoded.kind.wire)
        val message = case.strOrNull("displayNameInput")?.let { name ->
            val hello = (decoded as ControlMessage.HelloMsg).hello
            val device = DeviceInfo.make(hello.device.peerID, name, hello.device.platform, hello.device.model)
            ControlMessage.HelloMsg(Hello(hello.protocolVersion, device, hello.capabilities, hello.sessionNonce))
        } ?: decoded
        val encoded = ControlMessageCoder.encode(message)
        assertEquals(json, String(encoded, Charsets.UTF_8))
        if (case.has("hex")) assertEquals(case.str("hex"), encoded.toHex())
    }

    @TestFactory
    fun framing() = Vectors.tests("framing") { case ->
        if (case.bool("invalid")) {
            when (case.strOrNull("direction")) {
                "encode" -> {
                    val payload = ByteArray(case.str("payloadLength").toInt())
                    val frame = if (case.str("frameType") == "1") Frame.Control(payload) else Frame.Chunk(UUID(0, 0), 0, 0, payload)
                    val error = assertThrows<FrameCodec.CodecError> { FrameCodec.encode(frame) }
                    assertEquals(case.str("error"), error.message!!.substringBefore('('))
                }
                else -> {
                    val decoder = FrameDecoder()
                    decoder.append(case.str("hex").hexToBytes())
                    if (case.str("error") == "incomplete") {
                        assertNull(decoder.next())
                    } else {
                        val error = assertThrows<FrameCodec.CodecError> { decoder.next() }
                        assertEquals(case.str("error"), error.message!!.substringBefore('('))
                        case.strOrNull("errorValue")?.let { assertEquals("${case.str("error")}($it)", error.message) }
                        assertEquals(case.str("bridgeErrorCode"), error.toBridge().code.wire)
                    }
                }
            }
            return@tests
        }
        val type = case.str("frameType").toInt()
        val payloadLength = case.str("payloadLength").toInt()
        val payload = if (case.has("payloadPattern")) ByteArray(payloadLength) { it.toByte() } else case.str("payload").hexToBytes()
        case.strOrNull("payloadSha256")?.let { assertEquals(it, sha256(payload).toHex()) }
        val frame = if (type == FrameCodec.CONTROL_TYPE) {
            Frame.Control(payload)
        } else {
            Frame.Chunk(
                ControlMessageCoder.parseUuid(case.str("transferID")),
                case.str("sequence").toLong(),
                BigInteger(case.str("offset")).toLong(),
                payload,
            )
        }
        val encoded = FrameCodec.encode(frame)
        case.strOrNull("hex")?.let { assertEquals(it, encoded.toHex()) }
        case.strOrNull("headerHex")?.let { assertEquals(it, encoded.copyOf(it.length / 2).toHex()) }
        case.strOrNull("frameSha256")?.let { assertEquals(it, sha256(encoded).toHex()) }

        val decoder = FrameDecoder()
        decoder.append(encoded)
        val decoded = decoder.next()!!
        assertEquals(0, decoder.bufferedByteCount)
        when (decoded) {
            is Frame.Control -> assertArrayEquals(payload, decoded.payload)
            is Frame.Chunk -> {
                frame as Frame.Chunk
                assertEquals(frame.transferID, decoded.transferID)
                assertEquals(frame.sequence, decoded.sequence)
                assertEquals(case.str("offset"), java.lang.Long.toUnsignedString(decoded.offset))
                assertArrayEquals(payload, decoded.payload)
            }
        }
        assertTrue(decoded.javaClass == frame.javaClass)
    }
}
