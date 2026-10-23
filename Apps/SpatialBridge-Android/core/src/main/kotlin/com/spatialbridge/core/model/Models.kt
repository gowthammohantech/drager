package com.spatialbridge.core.model

import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.Edge
import com.spatialbridge.core.util.sha256
import com.spatialbridge.core.util.toHex

object BridgeProtocol {
    const val VERSION = 1
    const val SERVICE_TYPE = "_spatialbridge._tcp"
    const val SERVICE_DOMAIN = "local."

    object TxtKey {
        const val PEER_ID = "pid"
        const val DISPLAY_NAME = "name"
        const val PLATFORM = "plat"
        const val PROTOCOL_VERSION = "pv"
        const val ROLE = "role"
    }

    object SecretKey {
        const val IDENTITY_SEED = "identity.ed25519.seed"
        const val PAIR_PSK_PREFIX = "pair.psk."
        fun pairPsk(peerID: String) = PAIR_PSK_PREFIX + peerID
    }
}

/** Frame and transfer limits (FRD §4), mirroring `TransferLimits`. Durations are milliseconds. */
data class TransferLimits(
    val maxControlFrameBytes: Int = 64 * 1024,
    val chunkBytes: Int = 256 * 1024,
    val maxChunkBytes: Int = 512 * 1024,
    val maxFileBytes: Long = 100L * 1024 * 1024,
    val sendWindow: Int = 4,
    val handshakeTimeoutMillis: Long = 30_000,
    val transferIdleTimeoutMillis: Long = 30_000,
    val diskHeadroomBytes: Long = 64L * 1024 * 1024,
) {
    companion object {
        val DEFAULT = TransferLimits()
    }
}

object PeerIDs {
    /** `hex(SHA256(ed25519)[0..16])`. */
    fun fromSigningKey(publicKey: ByteArray): String = sha256(publicKey).copyOf(16).toHex()

    fun isValid(raw: String): Boolean = raw.length == 32 && raw.all { it in '0'..'9' || it in 'a'..'f' }

    /** `ab12 cd34 ef56 7890`. */
    fun fingerprint(peerID: String): String = peerID.take(16).chunked(4).joinToString(" ")
}

val Edge.wire: String get() = name.lowercase()

fun edgeOf(wire: String): Edge? = Edge.entries.firstOrNull { it.wire == wire }

val Edge.outwardNormal: Pair<Double, Double>
    get() = when (this) {
        Edge.TOP -> 0.0 to -1.0
        Edge.BOTTOM -> 0.0 to 1.0
        Edge.LEFT -> -1.0 to 0.0
        Edge.RIGHT -> 1.0 to 0.0
    }

val Edge.isHorizontal: Boolean get() = this == Edge.TOP || this == Edge.BOTTOM

private val GRAPHEME = Regex("\\X")

/** Extended grapheme clusters of [text] (Swift `Character`s). `\X` handles ZWJ sequences, unlike JDK 17's BreakIterator. */
fun graphemes(text: String): List<String> = GRAPHEME.findAll(text).map { it.value }.toList()

/** The first [limit] grapheme clusters of [text], like Swift's `String.prefix`. */
fun graphemePrefix(text: String, limit: Int): String {
    var end = 0
    var count = 0
    for (match in GRAPHEME.findAll(text)) {
        if (count == limit) break
        end = match.range.last + 1
        count++
    }
    return text.substring(0, end)
}

/** Swift `String ==`: canonical equivalence. */
fun canonicallyEquals(a: String, b: String): Boolean =
    a == b || java.text.Normalizer.normalize(a, java.text.Normalizer.Form.NFD) == java.text.Normalizer.normalize(b, java.text.Normalizer.Form.NFD)

data class DeviceInfo(
    val peerID: String,
    val displayName: String,
    val platform: DevicePlatform,
    val model: String,
) {
    companion object {
        /** Caps the display name and model at 64 characters, as Swift's initializer does. */
        fun make(peerID: String, displayName: String, platform: DevicePlatform, model: String) =
            DeviceInfo(peerID, graphemePrefix(displayName, 64), platform, graphemePrefix(model, 64))
    }
}

/** A peer the user approved. The PSK lives in the secret store; this record is public metadata. */
data class TrustedPeer(
    val peerID: String,
    val displayName: String,
    val platform: DevicePlatform,
    val model: String,
    val signingPublicKey: ByteArray,
    val pairedAtMillis: Long = System.currentTimeMillis(),
    val lastSeenAtMillis: Long? = null,
) {
    override fun equals(other: Any?): Boolean = other is TrustedPeer && peerID == other.peerID &&
        displayName == other.displayName && platform == other.platform && model == other.model &&
        signingPublicKey.contentEquals(other.signingPublicKey) && pairedAtMillis == other.pairedAtMillis &&
        lastSeenAtMillis == other.lastSeenAtMillis

    override fun hashCode(): Int = peerID.hashCode()
}

enum class PairingRole(val wire: String) { INITIATOR("initiator"), RESPONDER("responder") }
