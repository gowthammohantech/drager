package com.spatialbridge.core.json

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal
import java.util.Base64

/**
 * Canonical JSON (CONFORMANCE.md §1), byte-identical to Swift's `ControlMessageCoder`:
 * sorted keys, compact, raw UTF-8, `/` unescaped, padded base64, integer-millisecond dates.
 *
 * Values: `Map<String, Any?>` (null entries are omitted), `List<*>`, `String`, `Boolean`,
 * `Int`/`Long`, `Double`, `ByteArray` (base64) and [JsonElement].
 */
object CanonicalJson {
    fun encode(value: Any?): ByteArray = encodeToString(value).toByteArray(Charsets.UTF_8)

    fun encodeToString(value: Any?): String = StringBuilder().also { write(it, value) }.toString()

    private val parser = Json { isLenient = false }

    /** Parses UTF-8 JSON. Throws [IllegalArgumentException] on malformed input. */
    fun parse(bytes: ByteArray): JsonElement {
        val text = Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        return try {
            parser.parseToJsonElement(text)
        } catch (e: Exception) {
            throw IllegalArgumentException("malformed JSON", e)
        }
    }

    private fun write(out: StringBuilder, value: Any?) {
        when (value) {
            null, JsonNull -> out.append("null")
            is String -> writeString(out, value)
            is Boolean -> out.append(value)
            is Int, is Long, is Short, is Byte -> out.append(value.toString())
            is UInt -> out.append(value.toString())
            is Double -> out.append(formatDouble(value))
            is Float -> out.append(formatDouble(value.toDouble()))
            is ByteArray -> writeString(out, Base64.getEncoder().encodeToString(value))
            is Map<*, *> -> {
                out.append('{')
                val entries = value.entries.filter { it.value != null }
                    .map { (it.key as String) to it.value }
                    .sortedWith { a, b -> compareCodePoints(a.first, b.first) }
                entries.forEachIndexed { index, (key, item) ->
                    if (index > 0) out.append(',')
                    writeString(out, key)
                    out.append(':')
                    write(out, item)
                }
                out.append('}')
            }
            is JsonObject -> write(out, value.toMap())
            is JsonArray -> write(out, value.toList())
            is JsonPrimitive -> if (value.isString) writeString(out, value.content) else out.append(value.content)
            is Iterable<*> -> {
                out.append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    write(out, item)
                }
                out.append(']')
            }
            else -> throw IllegalArgumentException("unsupported JSON value ${value.javaClass.simpleName}")
        }
    }

    fun compareCodePoints(a: String, b: String): Int {
        var i = 0
        var j = 0
        while (i < a.length && j < b.length) {
            val ca = a.codePointAt(i)
            val cb = b.codePointAt(j)
            if (ca != cb) return ca.compareTo(cb)
            i += Character.charCount(ca)
            j += Character.charCount(cb)
        }
        return (a.length - i).compareTo(b.length - j)
    }

    fun writeString(out: StringBuilder, value: String) {
        out.append('"')
        for (ch in value) {
            when (ch) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (ch < ' ') {
                    out.append("\\u00").append(HEX[ch.code shr 4]).append(HEX[ch.code and 0xF])
                } else {
                    out.append(ch)
                }
            }
        }
        out.append('"')
    }

    private val HEX = "0123456789abcdef".toCharArray()

    /**
     * Shortest round-trip form in Swift's style: integral values without a fraction,
     * exponent form outside `[1e-4, 1e16)` as `1e+16` / `1e-05`.
     */
    fun formatDouble(value: Double): String {
        require(value.isFinite()) { "non-finite double" }
        if (value == 0.0) return if (1.0 / value < 0) "-0" else "0"
        val decimal = BigDecimal(value.toString()).stripTrailingZeros()
        val magnitude = Math.abs(value)
        if (magnitude >= 1e-4 && magnitude < 1e16) return decimal.toPlainString()
        val digits = decimal.unscaledValue().abs().toString()
        val exponent = digits.length - 1 - decimal.scale()
        val mantissa = if (digits.length == 1) digits else digits[0] + "." + digits.substring(1)
        val sign = if (value < 0) "-" else ""
        val expSign = if (exponent < 0) "-" else "+"
        val expDigits = Math.abs(exponent).toString().padStart(2, '0')
        return "$sign${mantissa}e$expSign$expDigits"
    }
}
