package com.spatialbridge.android.platform

import com.spatialbridge.core.net.Endpoint

/** A debug-only receiver address that bypasses NSD. [pairing] is null when only the session port is known. */
data class ManualTarget(val host: String, val pairing: Endpoint?, val session: Endpoint) {
    /** Locator key used until pairing reveals the authenticated peer ID. */
    val locatorID: String get() = "manual:$host:${pairing?.port ?: "-"}/${session.port}"
}

/**
 * Debug-only override that bypasses NSD, for example `10.0.2.2:52000/52001` (the emulator's alias
 * for the host loopback). A receiver listens on two ports, so the value is
 * `host:pairingPort/sessionPort`; `host:sessionPort` reconnects to a receiver that is already paired.
 * The setting is hidden and ignored in release builds.
 */
object ManualEndpoint {
    const val EMULATOR_HOST = "10.0.2.2"
    private val HOST = Regex("^[A-Za-z0-9.-]{1,253}$")

    fun parse(text: String?): ManualTarget? {
        val value = text?.trim().orEmpty()
        val colon = value.lastIndexOf(':')
        if (colon <= 0 || colon == value.length - 1) return null
        val host = value.substring(0, colon)
        if (!HOST.matches(host)) return null
        val ports = value.substring(colon + 1).split('/')
        if (ports.size > 2) return null
        val numbers = ports.map { p -> p.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null }
        return if (numbers.size == 2) {
            ManualTarget(host, Endpoint(host, numbers[0]), Endpoint(host, numbers[1]))
        } else {
            ManualTarget(host, null, Endpoint(host, numbers[0]))
        }
    }
}
