package com.spatialbridge.core.service

import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.net.Endpoint
import com.spatialbridge.core.transfer.UtiMap
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class LocatorTest {
    private val pid = "0123456789abcdef0123456789abcdef"

    @Test
    fun `session and pairing instances merge by pid, manual entries bypass NSD`() {
        val locator = ResolvedPeerLocator()
        locator.submit(
            listOf(
                ResolvedService("Mac", ServiceRole.SESSION, Endpoint("10.0.0.2", 5000), pid, "Studio Mac", DevicePlatform.MACOS, 1),
                ResolvedService("Mac (pairing)", ServiceRole.PAIRING, Endpoint("10.0.0.2", 5001), pid, "Studio Mac", DevicePlatform.MACOS, 1),
                ResolvedService("Legacy", ServiceRole.SESSION, Endpoint("10.0.0.3", 5000)),
            ),
        )
        locator.addManual("manual:emulator", "Host", Endpoint("10.0.2.2", 7000), Endpoint("10.0.2.2", 7001))
        val peers = locator.peers.value.associateBy { it.id }
        assertEquals(setOf(pid, "nsd:Legacy", "manual:emulator"), peers.keys)
        assertEquals(setOf(ServiceRole.SESSION, ServiceRole.PAIRING), peers.getValue(pid).roles)
        assertEquals(Endpoint("10.0.0.2", 5001), locator.endpoint(pid, ServiceRole.PAIRING))
        assertEquals(Endpoint("10.0.2.2", 7001), locator.endpoint("manual:emulator", ServiceRole.SESSION))

        locator.didPair("manual:emulator", "ffffffffffffffffffffffffffffffff")
        assertEquals(Endpoint("10.0.2.2", 7001), locator.endpoint("ffffffffffffffffffffffffffffffff", ServiceRole.SESSION))
        locator.lost("Mac (pairing)")
        assertEquals(setOf(ServiceRole.SESSION), locator.peers.value.first { it.id == pid }.roles)
    }

    @Test
    fun `retry backoff doubles and caps`() {
        val retry = RetryPolicy()
        assertEquals(0, retry.delayMillis(1, jitter = 1.0))
        assertEquals(500, retry.delayMillis(2, jitter = 1.0))
        assertEquals(1000, retry.delayMillis(3, jitter = 1.0))
        assertEquals(15_000, retry.delayMillis(20, jitter = 1.0))
    }

    @Test
    fun `UTI mapping prefers extension, then MIME, never dyn`() {
        assertEquals("public.jpeg", UtiMap.resolve("IMG_1.JPG", "image/png"))
        assertEquals("public.png", UtiMap.resolve("photo", "image/png"))
        assertEquals("public.data", UtiMap.resolve("x.unknownext", "application/x-unknown"))
        assertTrue(!UtiMap.resolve("a.xyz", null).startsWith("dyn."))
    }
}
