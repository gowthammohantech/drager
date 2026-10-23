package com.spatialbridge.android

import com.spatialbridge.android.platform.ManualEndpoint
import com.spatialbridge.android.platform.NsdSink
import com.spatialbridge.android.platform.PeerBrowser
import com.spatialbridge.android.platform.TxtRecordParser
import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.service.DiscoveryState
import com.spatialbridge.core.service.ServiceRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TxtRecordsTest {
    private val pid = "0123456789abcdef0123456789abcdef"

    private fun attrs(vararg pairs: Pair<String, String?>): Map<String, ByteArray?> =
        pairs.associate { (k, v) -> k to v?.encodeToByteArray() }

    @Test fun parsesAllKeys() {
        val txt = TxtRecordParser.parse(attrs("pid" to pid, "name" to "Studio Mac", "plat" to "macOS", "pv" to "1", "role" to "pairing"))
        assertEquals(pid, txt.peerID)
        assertEquals("Studio Mac", txt.displayName)
        assertEquals(DevicePlatform.MACOS, txt.platform)
        assertEquals(1, txt.protocolVersion)
        assertEquals(ServiceRole.PAIRING, txt.role)
    }

    @Test fun rejectsInvalidPeerIDs() {
        listOf(
            pid.uppercase(), pid.dropLast(1), pid + "0", "g" + pid.drop(1), " $pid", "", "../../etc",
        ).forEach { bad -> assertNull(bad, TxtRecordParser.parse(attrs("pid" to bad)).peerID) }
        assertNull(TxtRecordParser.parse(attrs("pid" to null)).peerID)
        assertNull(TxtRecordParser.parse(mapOf("pid" to byteArrayOf(0xC3.toByte(), 0x28))).peerID)
    }

    @Test fun roleDefaultsToSession() {
        assertEquals(ServiceRole.SESSION, TxtRecordParser.parse(attrs("pid" to pid)).role)
        assertEquals(ServiceRole.SESSION, TxtRecordParser.parse(attrs("pid" to pid, "role" to "admin")).role)
        assertEquals(ServiceRole.SESSION, TxtRecordParser.parse(attrs("pid" to pid, "role" to "session")).role)
    }

    @Test fun keepsUnknownPlatformsAndDropsEmpty() {
        assertEquals(DevicePlatform("linux"), TxtRecordParser.parse(attrs("plat" to "linux")).platform)
        assertEquals(DevicePlatform.WINDOWS, TxtRecordParser.parse(attrs("plat" to "windows")).platform)
        assertNull(TxtRecordParser.parse(attrs("plat" to "")).platform)
    }

    @Test fun cleansDisplayNamesAndVersions() {
        val long = "x".repeat(100)
        assertEquals(64, TxtRecordParser.parse(attrs("name" to long)).displayName!!.length)
        assertEquals("AB", TxtRecordParser.parse(attrs("name" to "A\u0000B\n")).displayName)
        assertNull(TxtRecordParser.parse(attrs("name" to "   ")).displayName)
        assertNull(TxtRecordParser.parse(attrs("pv" to "one")).protocolVersion)
    }

    private fun service(name: String, role: String, peer: String? = pid, display: String? = "Studio", port: Int = 5000) =
        TxtRecordParser.resolvedService(
            name, "192.168.1.5", port,
            TxtRecordParser.parse(attrs("pid" to peer, "name" to display, "plat" to "windows", "pv" to "1", "role" to role)),
        )

    private class FakeBrowser(val sink: NsdSink) : PeerBrowser {
        var running = false
        override fun start() { running = true }
        override fun stop() { running = false }
    }

    private fun locator(memory: ManualPeerMemory = InMemoryManualPeerMemory()): Pair<AppPeerLocator, () -> FakeBrowser> {
        var browser: FakeBrowser? = null
        val locator = AppPeerLocator(memory) { sink -> FakeBrowser(sink).also { browser = it } }
        return locator to { browser!! }
    }

    @Test fun mergesSessionAndPairingByPid() {
        val (locator, _) = locator()
        locator.start()
        locator.resolved(service("Studio-pair", "pairing", port = 5001)!!)
        locator.resolved(service("Studio", "session", port = 5000)!!)
        val peer = locator.peers.value.single()
        assertEquals(pid, peer.id)
        assertEquals("Studio", peer.displayName)
        assertEquals(DevicePlatform.WINDOWS, peer.platform)
        assertEquals(setOf(ServiceRole.SESSION, ServiceRole.PAIRING), peer.roles)
        assertEquals(5000, locator.endpoint(pid, ServiceRole.SESSION)!!.port)
        assertEquals(5001, locator.endpoint(pid, ServiceRole.PAIRING)!!.port)
        locator.lost("Studio-pair")
        assertNull(locator.endpoint(pid, ServiceRole.PAIRING))
    }

    @Test fun startAndStopDriveTheBrowser() {
        val (locator, browser) = locator()
        locator.start()
        assertTrue(browser().running)
        locator.stop()
        assertFalse(browser().running)
    }

    @Test fun ignoresInstancesWithoutAddress() {
        assertNull(service("Office PC", "session", display = null, port = 0))
        assertNull(TxtRecordParser.resolvedService("x", null, 5000, TxtRecordParser.parse(emptyMap())))
    }

    @Test fun nsdFailureReportsE001WithoutManualEndpoint() {
        val (locator, browser) = locator()
        locator.start()
        browser().sink.failed(BridgeErrorCode.LOCAL_NETWORK_DENIED)
        assertEquals(DiscoveryState.Waiting(BridgeErrorCode.LOCAL_NETWORK_DENIED), locator.state.value)
    }

    @Test fun manualEndpointIsNotBlockedByNsdFailureAndRekeysAfterPairing() {
        val memory = InMemoryManualPeerMemory()
        val (locator, browser) = locator(memory)
        locator.start()
        browser().sink.failed(BridgeErrorCode.LOCAL_NETWORK_DENIED)
        val target = ManualEndpoint.parse("10.0.2.2:52000/52001")!!
        locator.setManual(target)
        assertEquals(DiscoveryState.Browsing, locator.state.value)
        browser().sink.failed(BridgeErrorCode.LOCAL_NETWORK_DENIED)
        assertEquals(DiscoveryState.Browsing, locator.state.value)

        val provisional = locator.peers.value.single().id
        assertEquals(target.locatorID, provisional)
        assertEquals(52000, locator.endpoint(provisional, ServiceRole.PAIRING)!!.port)
        locator.didPair(provisional, pid)
        assertEquals(pid, locator.peers.value.single().id)
        assertEquals(52001, locator.endpoint(pid, ServiceRole.SESSION)!!.port)
        assertEquals(pid, memory.peerID(target))

        // A restarted app keys the same address by the remembered peer ID straight away.
        val (again, _) = locator(memory)
        again.setManual(target)
        assertEquals(pid, again.peers.value.single().id)
        again.setManual(null)
        assertTrue(again.peers.value.isEmpty())
    }
}
