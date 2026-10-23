package com.spatialbridge.core.fuzz

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.ControlMessageCoder
import com.spatialbridge.core.util.hexToBytes
import com.spatialbridge.core.vectors.Vectors
import com.spatialbridge.core.vectors.str
import com.spatialbridge.core.vectors.strOrNull
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import kotlin.random.Random

/**
 * Mutates the golden `control-messages` vectors. The decoder must either return a message whose
 * canonical re-encoding is stable, or throw [BridgeException] E012; nothing else.
 */
class ControlMessageFuzzTest {
    private val seeds: List<ByteArray> = Vectors.cases("control-messages").flatMap { case ->
        listOfNotNull(case.str("hex").hexToBytes(), case.strOrNull("inputJson")?.toByteArray())
    }

    private val invalidUtf8 = listOf(
        byteArrayOf(0xC0.toByte(), 0x80.toByte()), // overlong NUL
        byteArrayOf(0xFF.toByte()),
        byteArrayOf(0x80.toByte()), // lone continuation
        byteArrayOf(0xED.toByte(), 0xA0.toByte(), 0x80.toByte()), // encoded surrogate
        byteArrayOf(0xF4.toByte(), 0x90.toByte(), 0x80.toByte(), 0x80.toByte()), // > U+10FFFF
        byteArrayOf(0xE2.toByte(), 0x82.toByte()), // truncated sequence
    )

    private val hugeNumbers = listOf(
        "1e999999999", "-1e-999999999", "1e309", "-1e309", "99999999999999999999999999999", "18446744073709551616",
        "9223372036854775808", "-9223372036854775809", "4294967296", "2147483648", "-1", "1.5", "1.0", "1E+2", "-0",
        "0.0000001", "1" + "0".repeat(5000), "0." + "0".repeat(5000) + "1", "1e-2147483649", "NaN", "Infinity", "0x10", "01",
    )

    private val escapes = listOf("\\ud800", "\\udc00", "\\udc00\\ud800", "\\u0000", "\\uZZZZ", "\\", "\\x", "\"", "\\u12")

    private fun splice(input: ByteArray, at: Int, remove: Int, insert: ByteArray): ByteArray {
        val a = at.coerceIn(0, input.size)
        val r = remove.coerceIn(0, input.size - a)
        return input.copyOfRange(0, a) + insert + input.copyOfRange(a + r, input.size)
    }

    private fun deepNesting(rng: Random): ByteArray {
        val depth = Fuzz.pick(rng, listOf(17, 64, 200, 201, 1_000, 10_000, 30_000))
        val (open, close) = if (rng.nextBoolean()) "[" to "]" else "{\"a\":" to "}"
        val inner = open.repeat(depth) + "1" + close.repeat(if (rng.nextInt(4) == 0) depth / 2 else depth)
        return when (rng.nextInt(3)) {
            0 -> inner.toByteArray()
            1 -> "{\"body\":$inner,\"kind\":\"PING\"}".toByteArray()
            else -> "{\"body\":{\"sentAt\":1,\"sequence\":$inner},\"kind\":\"PING\"}".toByteArray()
        }
    }

    private fun replaceNumber(rng: Random, input: ByteArray): ByteArray {
        val digits = input.indices.filter { input[it] in '0'.code.toByte()..'9'.code.toByte() }
        if (digits.isEmpty()) return input
        var start = Fuzz.pick(rng, digits)
        while (start > 0 && (input[start - 1] in '0'.code.toByte()..'9'.code.toByte() || input[start - 1] == '-'.code.toByte())) start--
        var end = start
        while (end < input.size && input[end].toInt().toChar() in "0123456789.eE+-") end++
        return splice(input, start, end - start, Fuzz.pick(rng, hugeNumbers).toByteArray())
    }

    private fun mutate(rng: Random, seed: ByteArray): ByteArray {
        var b = seed
        repeat(1 + rng.nextInt(4)) {
            b = when (rng.nextInt(11)) {
                0 -> if (b.isEmpty()) b else b.copyOf().also { val i = rng.nextInt(it.size); it[i] = (it[i].toInt() xor (1 shl rng.nextInt(8))).toByte() }
                1 -> splice(b, rng.nextInt(b.size + 1), 0, byteArrayOf(rng.nextInt(256).toByte()))
                2 -> if (b.isEmpty()) b else splice(b, rng.nextInt(b.size), 1 + rng.nextInt(8), ByteArray(0))
                3 -> b.copyOf(rng.nextInt(b.size + 1))
                4 -> splice(b, rng.nextInt(b.size + 1), 0, Fuzz.pick(rng, invalidUtf8))
                5 -> replaceNumber(rng, b)
                6 -> deepNesting(rng)
                7 -> if (b.isEmpty()) b else { val i = rng.nextInt(b.size); splice(b, i, 0, b.copyOfRange(i, minOf(b.size, i + 1 + rng.nextInt(64)))) }
                8 -> if (b.isEmpty()) b else splice(b, rng.nextInt(b.size), 1, byteArrayOf("\"\\{}[],:0-e.n ".random(rng).code.toByte()))
                9 -> {
                    // Inside a string value: right after an opening quote.
                    val quotes = b.indices.filter { b[it] == '"'.code.toByte() }
                    if (quotes.isEmpty()) b else splice(b, Fuzz.pick(rng, quotes) + 1, 0, Fuzz.pick(rng, escapes).toByteArray())
                }
                else -> Fuzz.pick(rng, seeds) // swap in a different message entirely
            }
        }
        return b
    }

    private fun checkDecode(input: ByteArray) {
        val message = try {
            ControlMessageCoder.decode(input)
        } catch (e: BridgeException) {
            assertEquals(BridgeErrorCode.PROTOCOL_MISMATCH, e.code, "unexpected code for decode failure: $e")
            return
        }
        // Accepted input must have a stable canonical form.
        val canonical = try {
            ControlMessageCoder.encode(message)
        } catch (e: Exception) {
            throw AssertionError("decoded ${message.kind} cannot be re-encoded: $e", e)
        }
        assertArrayEquals(canonical, ControlMessageCoder.encode(ControlMessageCoder.decode(canonical)))
    }

    @Test
    fun `mutated golden vectors decode or fail E012`() {
        Fuzz.run("control-json-mutate") { rng, _ -> checkDecode(mutate(rng, Fuzz.pick(rng, seeds))) }
    }

    @Test
    fun `random bytes decode or fail E012`() {
        Fuzz.run("control-json-random") { rng, _ ->
            val input = if (rng.nextBoolean()) Fuzz.bytes(rng, 256) else ByteArray(rng.nextInt(256)) { "{}[]\",:0123456789.eE-truefalsn\\u ".random(rng).code.toByte() }
            checkDecode(input)
        }
    }

    private val offerWithGesture = """{"body":{"byteCount":10485760,"contentType":"public.jpeg","createdAt":1760000000123,""" +
        """"filename":"IMG_0001.jpeg","gesture":{"edge":"top","firedAt":1760000000123,"normalizedPosition":NP,""" +
        """"outwardVelocity":812.5,"travelDistance":143.25},"protocolVersion":1,"sha256Hex":"${"0".repeat(64)}",""" +
        """"sourcePeerID":"65b60673d6ed884bf01c2c222d82ada0","targetPeerID":"ba8112fa4ba3d6f934b2ad2aa0696602",""" +
        """"transferID":"3F2504E0-4F89-41D3-9A0C-0305E82C3301"},"kind":"TRANSFER_OFFER"}"""

    private fun assertRejected(json: String) {
        val e = try {
            ControlMessageCoder.decode(json.toByteArray())
            null
        } catch (e: BridgeException) {
            e
        }
        assertEquals(BridgeErrorCode.PROTOCOL_MISMATCH, e?.code, "accepted: $json")
    }

    @Test
    fun `numbers outside the JSON grammar or the target type are rejected`() {
        ControlMessageCoder.decode(offerWithGesture.replace("NP", "0.42").toByteArray())
        for (token in listOf("1e309", "-1e309", "1e999999999", "NaN", "Infinity", "-Infinity", "1f", "1d", "0x1p3", "+1", ".5", "1.", "01", "-", "1e", "\"0.42\"")) {
            assertRejected(offerWithGesture.replace("NP", token))
        }
        for (token in listOf("4294967296", "-1", "1e999999999", "18446744073709551616", "NaN", "1f", "+1", "01", "0x10")) {
            assertRejected("""{"body":{"sentAt":1,"sequence":$token},"kind":"PING"}""")
        }
    }

    @Test
    fun `deep nesting and huge numbers fail E012 in bounded time`() {
        Fuzz.run("control-json-extremes", count = maxOf(50, Fuzz.iterations / 20)) { rng, _ -> checkDecode(deepNesting(rng)) }
        for (n in hugeNumbers) {
            checkDecode("""{"body":{"sentAt":$n,"sequence":1},"kind":"PING"}""".toByteArray())
            checkDecode("""{"body":{"sentAt":1,"sequence":$n},"kind":"PONG"}""".toByteArray())
            checkDecode(
                """{"body":{"acknowledgedOffset":$n,"transferID":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8"},"kind":"PROGRESS"}""".toByteArray(),
            )
        }
    }
}
