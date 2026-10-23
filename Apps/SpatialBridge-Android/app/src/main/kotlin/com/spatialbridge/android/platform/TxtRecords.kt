package com.spatialbridge.android.platform

import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.model.BridgeProtocol
import com.spatialbridge.core.model.PeerIDs
import com.spatialbridge.core.net.Endpoint
import com.spatialbridge.core.service.ResolvedService
import com.spatialbridge.core.service.ServiceRole

/** TXT of one instance. An untrusted hint: it decides what to show, never whom to trust. */
data class TxtRecord(
    val peerID: String?,
    val displayName: String?,
    val platform: DevicePlatform?,
    val protocolVersion: Int?,
    val role: ServiceRole,
)

object TxtRecordParser {
    const val SERVICE_TYPE = BridgeProtocol.SERVICE_TYPE

    fun isValidPeerID(value: String?): Boolean = value != null && PeerIDs.isValid(value)

    /** Parses NsdServiceInfo attributes. Unknown/malformed values become null; nothing throws. */
    fun parse(attributes: Map<String, ByteArray?>): TxtRecord {
        fun text(key: String): String? = attributes[key]?.let { runCatching { it.decodeToString(throwOnInvalidSequence = true) }.getOrNull() }
        val pid = text("pid")?.takeIf(::isValidPeerID)
        val name = text("name")?.let(::cleanDisplayName)?.takeIf { it.isNotEmpty() }
        val plat = text("plat")?.trim()?.take(32)?.takeIf { it.isNotEmpty() }?.let(::DevicePlatform)
        val pv = text("pv")?.trim()?.toIntOrNull()
        val role = when (text("role")?.trim()) {
            ServiceRole.PAIRING.wire -> ServiceRole.PAIRING
            else -> ServiceRole.SESSION // Absent or unknown: treated as session, like the Swift browser.
        }
        return TxtRecord(pid, name, plat, pv, role)
    }

    /** A resolved NSD instance in the form core's `ResolvedPeerLocator` merges; null without a usable address. */
    fun resolvedService(instanceName: String, host: String?, port: Int, txt: TxtRecord): ResolvedService? {
        if (host.isNullOrEmpty() || port !in 1..65535) return null
        return ResolvedService(
            instanceName = instanceName,
            role = txt.role,
            endpoint = Endpoint(host, port),
            peerID = txt.peerID,
            displayName = txt.displayName,
            platform = txt.platform,
            protocolVersion = txt.protocolVersion,
        )
    }

    private fun cleanDisplayName(raw: String): String =
        raw.filter { !it.isISOControl() }.trim().let { name ->
            if (name.codePointCount(0, name.length) <= 64) name else name.substring(0, name.offsetByCodePoints(0, 64))
        }
}
