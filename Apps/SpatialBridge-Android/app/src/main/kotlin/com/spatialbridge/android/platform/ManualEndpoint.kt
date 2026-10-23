package com.spatialbridge.android.platform

/**
 * Debug-only `host:port` override that bypasses NSD (for example `10.0.2.2:52000`, the emulator's
 * alias for the host loopback). The setting is hidden and ignored in release builds.
 */
object ManualEndpoint {
    const val EMULATOR_HOST = "10.0.2.2"
    private val HOST = Regex("^[A-Za-z0-9.-]{1,253}$")

    fun parse(text: String?): PeerEndpoint? {
        val value = text?.trim().orEmpty()
        val colon = value.lastIndexOf(':')
        if (colon <= 0 || colon == value.length - 1) return null
        val host = value.substring(0, colon)
        val port = value.substring(colon + 1).toIntOrNull() ?: return null
        if (port !in 1..65535 || !HOST.matches(host)) return null
        return PeerEndpoint(host, port)
    }
}
