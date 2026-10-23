package com.spatialbridge.android.platform

import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.DiscoveredPeer

/** `role` TXT value: each receiver advertises a session and a pairing instance. */
enum class ServiceRole(val raw: String) { SESSION("session"), PAIRING("pairing") }

/** One resolved NSD instance. TXT is an untrusted hint: it decides what to show, never whom to trust. */
data class ServiceInstance(
    val serviceName: String,
    val host: String?,
    val port: Int,
    val txt: TxtRecord,
)

data class TxtRecord(
    val peerID: String?,
    val displayName: String?,
    val platform: DevicePlatform?,
    val protocolVersion: Int?,
    val role: ServiceRole,
)

data class PeerEndpoint(val host: String, val port: Int)

/** A merged receiver plus where to reach each of its roles. */
data class ResolvedPeer(
    val peer: DiscoveredPeer,
    val protocolVersion: Int?,
    val endpoints: Map<ServiceRole, PeerEndpoint>,
)

object TxtRecordParser {
    const val SERVICE_TYPE = "_spatialbridge._tcp"
    const val PROTOCOL_VERSION = 1
    private val PEER_ID = Regex("^[0-9a-f]{32}$")

    fun isValidPeerID(value: String?): Boolean = value != null && PEER_ID.matches(value)

    /** Parses NsdServiceInfo attributes. Unknown/malformed values become null; nothing throws. */
    fun parse(attributes: Map<String, ByteArray?>): TxtRecord {
        fun text(key: String): String? = attributes[key]?.let { runCatching { it.decodeToString(throwOnInvalidSequence = true) }.getOrNull() }
        val pid = text("pid")?.takeIf(::isValidPeerID)
        val name = text("name")?.let(::cleanDisplayName)?.takeIf { it.isNotEmpty() }
        val plat = text("plat")?.trim()?.take(32)?.takeIf { it.isNotEmpty() }?.let(::DevicePlatform)
        val pv = text("pv")?.trim()?.toIntOrNull()
        val role = when (text("role")?.trim()) {
            ServiceRole.PAIRING.raw -> ServiceRole.PAIRING
            else -> ServiceRole.SESSION // Absent or unknown: treated as session, like the Swift browser.
        }
        return TxtRecord(pid, name, plat, pv, role)
    }

    private fun cleanDisplayName(raw: String): String =
        raw.filter { !it.isISOControl() }.trim().let { name ->
            if (name.codePointCount(0, name.length) <= 64) name else name.substring(0, name.offsetByCodePoints(0, 64))
        }
}

object PeerMerger {
    /**
     * Groups instances by validated `pid` (instances without one are dropped: the facade needs a peer
     * ID to pair or connect). Display data prefers the session instance. [trusted] comes from the
     * local trust store, never from TXT. [excludePeerID] hides this device's own advertisement.
     */
    fun merge(
        instances: Collection<ServiceInstance>,
        trusted: Set<String>,
        excludePeerID: String? = null,
    ): List<ResolvedPeer> {
        val groups = instances
            .filter { it.txt.peerID != null && it.txt.peerID != excludePeerID }
            .groupBy { it.txt.peerID!! }
        return groups.map { (pid, group) ->
            val ordered = group.sortedWith(compareBy({ it.txt.role != ServiceRole.SESSION }, { it.serviceName }))
            val primary = ordered.first()
            val endpoints = buildMap {
                ordered.forEach { i -> if (i.host != null && i.port in 1..65535) putIfAbsent(i.txt.role, PeerEndpoint(i.host, i.port)) }
            }
            val name = ordered.firstNotNullOfOrNull { it.txt.displayName } ?: primary.serviceName.take(64)
            ResolvedPeer(
                peer = DiscoveredPeer(
                    peerID = pid,
                    displayName = name,
                    platform = ordered.firstNotNullOfOrNull { it.txt.platform },
                    isTrusted = pid in trusted,
                    pairingAvailable = group.any { it.txt.role == ServiceRole.PAIRING },
                ),
                protocolVersion = ordered.firstNotNullOfOrNull { it.txt.protocolVersion },
                endpoints = endpoints,
            )
        }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.peer.displayName })
    }
}
