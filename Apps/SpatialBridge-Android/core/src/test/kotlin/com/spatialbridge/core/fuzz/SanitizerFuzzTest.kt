package com.spatialbridge.core.fuzz

import com.spatialbridge.core.model.canonicallyEquals
import com.spatialbridge.core.model.graphemes
import com.spatialbridge.core.transfer.FilenameSanitizer
import com.spatialbridge.core.vectors.Vectors
import com.spatialbridge.core.vectors.str
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.text.Normalizer
import kotlin.random.Random

/** `sanitize` never throws, is idempotent, and always yields a name `isSafe` accepts. */
class SanitizerFuzzTest {
    private val pools: List<List<Int>> = listOf(
        ('a'..'z').map { it.code } + ('A'..'Z').map { it.code } + ('0'..'9').map { it.code },
        listOf('.', '/', '\\', ':', ' ', '-', '_', '~', '*', '?', '"', '<', '>', '|').map { it.code },
        (0x00..0x1F).toList() + 0x7F + 0x85 + 0xA0 + 0x2028 + 0x2029 + 0x3000 + 0x200B + 0xFEFF + 0x1680,
        (0x0300..0x036F).toList() + 0x20DD + 0x0903 + 0x093F, // combining, enclosing and spacing marks
        listOf(0x00C5, 0x212B, 0x0041, 0x030A, 0x1E9B, 0x0323, 0xFB01, 0x2126, 0x0130, 0x0131, 0x1E9E, 0x00DF), // NFC/case traps
        listOf(0x1F600, 0x1F468, 0x200D, 0x1F469, 0x1F467, 0x1F3FB, 0xFE0F, 0x1F1FA, 0x1F1F8, 0x1F3F4, 0xE0067, 0xE007F),
        listOf(0x1100, 0x1161, 0x11A8, 0xAC00, 0x4E2D, 0x6587, 0x05D0, 0x0627, 0x202E, 0x202D, 0x0E01, 0x0E33),
        // No lone surrogates: Swift Strings cannot hold them and CanonicalJson.parse refuses `\ud800`.
        listOf(0xFFFD, 0xFFFF, 0x10FFFF, 0xE000, 0xF8FF, 0x2160, 0x00B2, 0x0660, 0x2155),
    )

    private val contentTypes = listOf(null, "public.jpeg", "public.png", "com.adobe.pdf", "public.data", "public.plain-text", "x.unknown")

    private fun randomName(rng: Random): String {
        val sb = StringBuilder()
        val length = when (rng.nextInt(4)) {
            0 -> rng.nextInt(8)
            1 -> rng.nextInt(40)
            2 -> 240 + rng.nextInt(40)
            else -> rng.nextInt(400)
        }
        val favourite = Fuzz.pick(rng, pools)
        repeat(length) { sb.appendCodePoint(Fuzz.pick(rng, if (rng.nextInt(3) == 0) Fuzz.pick(rng, pools) else favourite)) }
        if (rng.nextInt(3) == 0) sb.append('.').append(randomExt(rng))
        if (rng.nextInt(6) == 0) sb.insert(0, Fuzz.pick(rng, listOf(".", "..", "../", " .", "./.", "C:\\", "/")))
        return sb.toString()
    }

    private fun randomExt(rng: Random): String = buildString {
        repeat(rng.nextInt(24)) { appendCodePoint(Fuzz.pick(rng, Fuzz.pick(rng, pools))) }
    }

    private val vectorInputs: List<String> = Vectors.cases("sanitizer").mapNotNull { it["input"]?.let { _ -> it.str("input") } }

    private fun describe(s: String) = s.codePoints().toArray().joinToString(" ") { "U+%04X".format(it) }

    private fun check(input: String, contentType: String?) {
        try {
            checkProperties(input, contentType)
        } catch (e: Throwable) {
            throw AssertionError("input [${describe(input)}] contentType=$contentType -> [${describe(FilenameSanitizer.sanitize(input, contentType))}]: ${e.message}", e)
        }
    }

    private fun checkProperties(input: String, contentType: String?) {
        val once = FilenameSanitizer.sanitize(input, contentType)
        assertEquals(once, FilenameSanitizer.sanitize(once), "not idempotent")
        assertTrue(FilenameSanitizer.isSafe(once), "sanitized name is not safe")
        assertTrue(once.isNotEmpty())
        assertTrue(once.toByteArray(Charsets.UTF_8).size <= FilenameSanitizer.MAX_UTF8_BYTES, "too long")
        assertFalse(once.any { it == '/' || it == '\\' || it == ':' || it < ' ' || it == '\u007F' }, "forbidden character")
        assertFalse(graphemes(once).first() == ".", "leading dot")
        assertTrue(Normalizer.isNormalized(once, Normalizer.Form.NFC), "not NFC")
        if (FilenameSanitizer.isSafe(input)) assertTrue(canonicallyEquals(input, FilenameSanitizer.sanitize(input)), "isSafe input changed")
    }

    @Test
    fun `random unicode names`() {
        Fuzz.run("sanitizer-random") { rng, _ -> check(randomName(rng), Fuzz.pick(rng, contentTypes)) }
    }

    @Test
    fun `mutated vector names`() {
        Fuzz.run("sanitizer-mutate") { rng, _ ->
            val base = StringBuilder(Fuzz.pick(rng, vectorInputs))
            repeat(1 + rng.nextInt(3)) {
                val at = if (base.isEmpty()) 0 else rng.nextInt(base.length + 1)
                when (rng.nextInt(3)) {
                    0 -> base.insert(at, String(Character.toChars(Fuzz.pick(rng, Fuzz.pick(rng, pools)))))
                    1 -> if (base.isNotEmpty() && at < base.length) base.deleteCharAt(at)
                    else -> base.setLength(minOf(base.length, at))
                }
            }
            // Deleting one UTF-16 unit can split a surrogate pair; such strings cannot come off the wire.
            val text = base.toString()
            if (text.indices.any { i -> Character.isSurrogate(text[i]) && !(Character.isHighSurrogate(text[i]) && i + 1 < text.length && Character.isLowSurrogate(text[i + 1])) && !(Character.isLowSurrogate(text[i]) && i > 0 && Character.isHighSurrogate(text[i - 1])) }) return@run
            check(text, Fuzz.pick(rng, contentTypes))
        }
    }

    @Test
    fun `long names finish in bounded time`() {
        // A 64 KiB control frame can carry a ~60k-character filename; truncation must stay linear.
        Fuzz.run("sanitizer-long", count = maxOf(10, Fuzz.iterations / 200)) { rng, _ ->
            val pool = Fuzz.pick(rng, pools)
            val sb = StringBuilder()
            while (sb.length < 60_000) sb.appendCodePoint(Fuzz.pick(rng, pool))
            check(sb.toString(), null)
        }
    }
}
