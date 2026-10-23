package com.spatialbridge.core.util

import java.security.MessageDigest
import java.security.SecureRandom

private val HEX_DIGITS = "0123456789abcdef".toCharArray()

fun ByteArray.toHex(): String {
    val out = CharArray(size * 2)
    forEachIndexed { i, b ->
        out[i * 2] = HEX_DIGITS[(b.toInt() shr 4) and 0xF]
        out[i * 2 + 1] = HEX_DIGITS[b.toInt() and 0xF]
    }
    return String(out)
}

/** Parses hex (either case). Returns null for odd lengths or non-hex characters. */
fun String.hexToBytesOrNull(): ByteArray? {
    if (length % 2 != 0) return null
    val out = ByteArray(length / 2)
    for (i in out.indices) {
        val hi = Character.digit(this[i * 2], 16)
        val lo = Character.digit(this[i * 2 + 1], 16)
        if (hi < 0 || lo < 0) return null
        out[i] = ((hi shl 4) or lo).toByte()
    }
    return out
}

fun String.hexToBytes(): ByteArray = requireNotNull(hexToBytesOrNull()) { "invalid hex" }

fun sha256(vararg parts: ByteArray): ByteArray {
    val digest = MessageDigest.getInstance("SHA-256")
    parts.forEach { digest.update(it) }
    return digest.digest()
}

fun uint32BE(value: Long): ByteArray = byteArrayOf(
    (value shr 24).toByte(), (value shr 16).toByte(), (value shr 8).toByte(), value.toByte(),
)

object SecureRandomBytes {
    private val random = SecureRandom()
    fun bytes(count: Int): ByteArray = ByteArray(count).also { random.nextBytes(it) }
}

/** `hex(SHA256(psk))[0..16]`: the only form in which a PSK may appear in output (CONFORMANCE.md §5). */
fun pskFingerprint(psk: ByteArray): String = sha256(psk).toHex().take(16)

/** Constant-time comparison. */
fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)
